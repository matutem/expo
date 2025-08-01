// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{bail, Result};

use mio::{Registry, Token};
use std::borrow::Borrow;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;

use super::errors::SerializedError;
use super::protocol::{
    BitbangEntryRequest, BitbangEntryResponse, DacBangEntryRequest, EmuRequest, EmuResponse,
    GpioBitRequest, GpioBitResponse, GpioDacRequest, GpioDacResponse, GpioMonRequest,
    GpioMonResponse, GpioRequest, GpioResponse, I2cRequest, I2cResponse, I2cTransferRequest,
    I2cTransferResponse, Message, ProxyRequest, ProxyResponse, Request, Response, SpiRequest,
    SpiResponse, SpiTransferRequest, SpiTransferResponse, UartRequest, UartResponse,
};
use super::CommandHandler;
use crate::app::TransportWrapper;
use crate::bootstrap::Bootstrap;
use crate::io::gpio::{
    BitbangEntry, DacBangEntry, GpioBitbangOperation, GpioDacBangOperation, GpioPin,
};
use crate::io::{i2c, nonblocking_help, spi};
use crate::proxy::nonblocking_uart::NonblockingUartRegistry;
use crate::transport::TransportError;

/// Implementation of the handling of each protocol request, by means of an underlying
/// `Transport` implementation.
pub struct TransportCommandHandler<'a> {
    transport: &'a TransportWrapper,
    nonblocking_help: Rc<dyn nonblocking_help::NonblockingHelp>,
    spi_chip_select: HashMap<String, Vec<spi::AssertChipSelect>>,
    ongoing_bitbanging: Option<Box<dyn GpioBitbangOperation<'static, 'static>>>,
    ongoing_dacbanging: Option<Box<dyn GpioDacBangOperation>>,
}

impl<'a> TransportCommandHandler<'a> {
    pub fn new(transport: &'a TransportWrapper) -> Result<Self> {
        let nonblocking_help = transport.nonblocking_help()?;
        Ok(Self {
            transport,
            nonblocking_help,
            spi_chip_select: HashMap::new(),
            ongoing_bitbanging: None,
            ongoing_dacbanging: None,
        })
    }

    fn optional_pin(&self, pin: &Option<String>) -> Result<Option<Rc<dyn GpioPin>>> {
        if let Some(pin) = pin {
            Ok(Some(self.transport.gpio_pin(pin)?))
        } else {
            Ok(None)
        }
    }

    /// This method will perform whatever action on the underlying `Transport` that is requested
    /// by the given `Request`, and return a response to be sent to the client.  Any `Err`
    /// return from this method will be propagated to the remote client, without any server-side
    /// logging.
    fn do_execute_cmd(
        &mut self,
        conn_token: Token,
        registry: &Registry,
        others: &mut NonblockingUartRegistry,
        req: &Request,
    ) -> Result<Response> {
        match req {
            Request::GetCapabilities => {
                Ok(Response::GetCapabilities(self.transport.capabilities()?))
            }
            Request::ApplyDefaultConfiguration => {
                self.transport.apply_default_configuration(None)?;
                Ok(Response::ApplyDefaultConfiguration)
            }
            Request::Gpio { id, command } => {
                let instance = self.transport.gpio_pin(id)?;
                match command {
                    GpioRequest::Read => {
                        let value = instance.read()?;
                        Ok(Response::Gpio(GpioResponse::Read { value }))
                    }
                    GpioRequest::Write { logic } => {
                        instance.write(*logic)?;
                        Ok(Response::Gpio(GpioResponse::Write))
                    }
                    GpioRequest::SetMode { mode } => {
                        instance.set_mode(*mode)?;
                        Ok(Response::Gpio(GpioResponse::SetMode))
                    }
                    GpioRequest::SetPullMode { pull } => {
                        instance.set_pull_mode(*pull)?;
                        Ok(Response::Gpio(GpioResponse::SetPullMode))
                    }
                    GpioRequest::AnalogRead => {
                        let value = instance.analog_read()?;
                        Ok(Response::Gpio(GpioResponse::AnalogRead { value }))
                    }
                    GpioRequest::AnalogWrite { value } => {
                        instance.analog_write(*value)?;
                        Ok(Response::Gpio(GpioResponse::AnalogWrite))
                    }
                    GpioRequest::MultiSet {
                        mode,
                        value,
                        pull,
                        analog_value,
                    } => {
                        instance.set(*mode, *value, *pull, *analog_value)?;
                        Ok(Response::Gpio(GpioResponse::MultiSet))
                    }
                }
            }
            Request::GpioMonitoring { command } => {
                let instance = self.transport.gpio_monitoring()?;
                match command {
                    GpioMonRequest::GetClockNature => {
                        let resp = instance.get_clock_nature()?;
                        Ok(Response::GpioMonitoring(GpioMonResponse::GetClockNature {
                            resp,
                        }))
                    }
                    GpioMonRequest::Start { pins } => {
                        let pins = self.transport.gpio_pins(pins)?;
                        let pins = pins.iter().map(Rc::borrow).collect::<Vec<&dyn GpioPin>>();
                        let resp = instance.monitoring_start(&pins)?;
                        Ok(Response::GpioMonitoring(GpioMonResponse::Start { resp }))
                    }
                    GpioMonRequest::Read {
                        pins,
                        continue_monitoring,
                    } => {
                        let pins = self.transport.gpio_pins(pins)?;
                        let pins = pins.iter().map(Rc::borrow).collect::<Vec<&dyn GpioPin>>();
                        let resp = instance.monitoring_read(&pins, *continue_monitoring)?;
                        Ok(Response::GpioMonitoring(GpioMonResponse::Read { resp }))
                    }
                }
            }
            Request::GpioBitbanging { command } => {
                let instance = self.transport.gpio_bitbanging()?;
                match command {
                    GpioBitRequest::Start {
                        pins,
                        clock_ns,
                        entries: reqs,
                    } => {
                        let pins = self.transport.gpio_pins(pins)?;
                        let pins = pins.iter().map(Rc::borrow).collect::<Vec<&dyn GpioPin>>();
                        let clock = Duration::from_nanos(*clock_ns);

                        let entries: Vec<BitbangEntry<'static, 'static>> = reqs
                            .iter()
                            .map(|pair| match pair {
                                BitbangEntryRequest::Write { data } => {
                                    BitbangEntry::WriteOwned(data.clone().into())
                                }
                                BitbangEntryRequest::Both { data } => {
                                    BitbangEntry::BothOwned(data.clone().into())
                                }
                                BitbangEntryRequest::Delay { clock_ticks } => {
                                    BitbangEntry::Delay(*clock_ticks)
                                }
                                BitbangEntryRequest::Await { mask, pattern } => {
                                    BitbangEntry::Await {
                                        mask: *mask,
                                        pattern: *pattern,
                                    }
                                }
                            })
                            .collect();
                        self.ongoing_bitbanging =
                            Some(instance.start(&pins, clock, entries.into())?);
                        Ok(Response::GpioBitbanging(GpioBitResponse::Start))
                    }
                    GpioBitRequest::Query => {
                        if let Some(ref mut bitbanging) = self.ongoing_bitbanging {
                            if !bitbanging.query()? {
                                return Ok(Response::GpioBitbanging(GpioBitResponse::QueryNotDone));
                            }
                        } else {
                            return Err(TransportError::InvalidOperation.into());
                        }
                        let waveform = self.ongoing_bitbanging.take().unwrap().get_result()?;

                        // Construct proper response to each entry in request.
                        let resps: Vec<BitbangEntryResponse> = waveform
                            .iter()
                            .map(|entry| match entry {
                                BitbangEntry::WriteOwned(..) => BitbangEntryResponse::Write,
                                BitbangEntry::BothOwned(data) => BitbangEntryResponse::Both {
                                    data: data.to_vec(),
                                },
                                BitbangEntry::Delay(..) => BitbangEntryResponse::Delay,
                                BitbangEntry::Await { .. } => BitbangEntryResponse::Await,
                                // No other kinds of `BitbangEntry` created above.
                                _ => panic!(),
                            })
                            .collect();
                        // Now carefully craft a proper parameter to the
                        // `GpioBitbanging::run()` method.  It will have reference
                        // into elements of both the request vector and mutable reference into
                        // the response vector.
                        Ok(Response::GpioBitbanging(GpioBitResponse::QueryDone {
                            entries: resps,
                        }))
                    }
                }
            }
            Request::GpioDacBanging { command } => {
                let instance = self.transport.gpio_bitbanging()?;
                match command {
                    GpioDacRequest::Start {
                        pins,
                        clock_ns,
                        entries: reqs,
                    } => {
                        let pins = self.transport.gpio_pins(pins)?;
                        let pins = pins.iter().map(Rc::borrow).collect::<Vec<&dyn GpioPin>>();
                        let clock = Duration::from_nanos(*clock_ns);

                        let entries: Vec<DacBangEntry> = reqs
                            .iter()
                            .map(|pair| match pair {
                                DacBangEntryRequest::Write { data } => {
                                    DacBangEntry::WriteOwned(data.clone().into())
                                }
                                DacBangEntryRequest::Delay { clock_ticks } => {
                                    DacBangEntry::Delay(*clock_ticks)
                                }
                                DacBangEntryRequest::Linear { clock_ticks } => {
                                    DacBangEntry::Linear(*clock_ticks)
                                }
                            })
                            .collect();
                        self.ongoing_dacbanging =
                            Some(instance.dac_start(&pins, clock, entries.into())?);
                        Ok(Response::GpioDacBanging(GpioDacResponse::Start))
                    }
                    GpioDacRequest::Query => {
                        if let Some(ref mut dacbanging) = self.ongoing_dacbanging {
                            if dacbanging.query()? {
                                Ok(Response::GpioDacBanging(GpioDacResponse::QueryDone))
                            } else {
                                Ok(Response::GpioDacBanging(GpioDacResponse::QueryNotDone))
                            }
                        } else {
                            Err(TransportError::InvalidOperation.into())
                        }
                    }
                }
            }
            Request::Uart { id, command } => {
                let instance = self.transport.uart(id)?;
                match command {
                    UartRequest::GetBaudrate => {
                        let rate = instance.get_baudrate()?;
                        Ok(Response::Uart(UartResponse::GetBaudrate { rate }))
                    }
                    UartRequest::SetBaudrate { rate } => {
                        instance.set_baudrate(*rate)?;
                        Ok(Response::Uart(UartResponse::SetBaudrate))
                    }
                    UartRequest::SetBreak(enable) => {
                        instance.set_break(*enable)?;
                        Ok(Response::Uart(UartResponse::SetBreak))
                    }
                    UartRequest::GetParity => {
                        let parity = instance.get_parity()?;
                        Ok(Response::Uart(UartResponse::GetParity { parity }))
                    }
                    UartRequest::SetParity(parity) => {
                        instance.set_parity(*parity)?;
                        Ok(Response::Uart(UartResponse::SetParity))
                    }
                    UartRequest::GetFlowControl => {
                        let flow_control = instance.get_flow_control()?;
                        Ok(Response::Uart(UartResponse::GetFlowControl {
                            flow_control,
                        }))
                    }
                    UartRequest::SetFlowControl(flow_control) => {
                        instance.set_flow_control(*flow_control)?;
                        Ok(Response::Uart(UartResponse::SetFlowControl))
                    }
                    UartRequest::GetDevicePath => {
                        let path = instance.get_device_path()?;
                        Ok(Response::Uart(UartResponse::GetDevicePath { path }))
                    }
                    UartRequest::Read {
                        timeout_millis,
                        len,
                    } => {
                        let mut data = vec![0u8; *len as usize];
                        let count = match timeout_millis {
                            None => instance.read(&mut data)?,
                            Some(ms) => instance
                                .read_timeout(&mut data, Duration::from_millis(*ms as u64))?,
                        };
                        data.resize(count, 0);
                        Ok(Response::Uart(UartResponse::Read { data }))
                    }
                    UartRequest::Write { data } => {
                        instance.write(data)?;
                        Ok(Response::Uart(UartResponse::Write))
                    }
                    UartRequest::SupportsNonblockingRead => {
                        let has_support = instance.supports_nonblocking_read()?;
                        Ok(Response::Uart(UartResponse::SupportsNonblockingRead {
                            has_support,
                        }))
                    }
                    UartRequest::RegisterNonblockingRead => {
                        let channel =
                            others.nonblocking_uart_init(&instance, conn_token, registry)?;
                        Ok(Response::Uart(UartResponse::RegisterNonblockingRead {
                            channel,
                        }))
                    }
                }
            }
            Request::Spi { id, command } => {
                let instance = self.transport.spi(id)?;
                match command {
                    SpiRequest::GetTransferMode => {
                        let mode = instance.get_transfer_mode()?;
                        Ok(Response::Spi(SpiResponse::GetTransferMode { mode }))
                    }
                    SpiRequest::SetTransferMode { mode } => {
                        instance.set_transfer_mode(*mode)?;
                        Ok(Response::Spi(SpiResponse::SetTransferMode))
                    }
                    SpiRequest::GetBitsPerWord => {
                        let bits_per_word = instance.get_bits_per_word()?;
                        Ok(Response::Spi(SpiResponse::GetBitsPerWord { bits_per_word }))
                    }
                    SpiRequest::SetBitsPerWord { bits_per_word } => {
                        instance.set_bits_per_word(*bits_per_word)?;
                        Ok(Response::Spi(SpiResponse::SetBitsPerWord))
                    }
                    SpiRequest::GetMaxSpeed => {
                        let speed = instance.get_max_speed()?;
                        Ok(Response::Spi(SpiResponse::GetMaxSpeed { speed }))
                    }
                    SpiRequest::SetMaxSpeed { value } => {
                        instance.set_max_speed(*value)?;
                        Ok(Response::Spi(SpiResponse::SetMaxSpeed))
                    }
                    SpiRequest::SupportsBidirectionalTransfer => {
                        let has_support = instance.supports_bidirectional_transfer()?;
                        Ok(Response::Spi(SpiResponse::SupportsBidirectionalTransfer {
                            has_support,
                        }))
                    }
                    SpiRequest::SupportsTpmPoll => {
                        let has_support = instance.supports_tpm_poll()?;
                        Ok(Response::Spi(SpiResponse::SupportsTpmPoll { has_support }))
                    }
                    SpiRequest::SetPins {
                        serial_clock,
                        host_out_device_in,
                        host_in_device_out,
                        chip_select,
                        gsc_ready,
                    } => {
                        instance.set_pins(
                            self.optional_pin(serial_clock)?.as_ref(),
                            self.optional_pin(host_out_device_in)?.as_ref(),
                            self.optional_pin(host_in_device_out)?.as_ref(),
                            self.optional_pin(chip_select)?.as_ref(),
                            self.optional_pin(gsc_ready)?.as_ref(),
                        )?;
                        Ok(Response::Spi(SpiResponse::SetPins))
                    }
                    SpiRequest::GetMaxTransferCount => {
                        let number = instance.get_max_transfer_count()?;
                        Ok(Response::Spi(SpiResponse::GetMaxTransferCount { number }))
                    }
                    SpiRequest::GetMaxTransferSizes => {
                        let sizes = instance.get_max_transfer_sizes()?;
                        Ok(Response::Spi(SpiResponse::GetMaxTransferSizes { sizes }))
                    }
                    SpiRequest::GetEepromMaxTransferSizes => {
                        let sizes = instance.get_eeprom_max_transfer_sizes()?;
                        Ok(Response::Spi(SpiResponse::GetEepromMaxTransferSizes {
                            sizes,
                        }))
                    }
                    SpiRequest::SetVoltage { voltage } => {
                        instance.set_voltage(*voltage)?;
                        Ok(Response::Spi(SpiResponse::SetVoltage))
                    }
                    SpiRequest::GetFlashromArgs => {
                        let programmer = instance.get_flashrom_programmer()?;
                        Ok(Response::Spi(SpiResponse::GetFlashromArgs { programmer }))
                    }
                    SpiRequest::RunTransaction { transaction: reqs } => {
                        // Construct proper response to each transfer in request.
                        let mut resps: Vec<SpiTransferResponse> = reqs
                            .iter()
                            .map(|transfer| match transfer {
                                SpiTransferRequest::Read { len } => SpiTransferResponse::Read {
                                    data: vec![0; *len as usize],
                                },
                                SpiTransferRequest::Write { .. } => SpiTransferResponse::Write,
                                SpiTransferRequest::Both { data } => SpiTransferResponse::Both {
                                    data: vec![0; data.len()],
                                },
                                SpiTransferRequest::TpmPoll => SpiTransferResponse::TpmPoll,
                                SpiTransferRequest::GscReady => SpiTransferResponse::GscReady,
                            })
                            .collect();
                        // Now carefully craft a proper parameter to the
                        // `spi::Target::run_transactions()` method.  It will have reference
                        // into elements of both the request vector and mutable reference into
                        // the response vector.
                        let mut transaction: Vec<spi::Transfer> = reqs
                            .iter()
                            .zip(resps.iter_mut())
                            .map(|pair| match pair {
                                (
                                    SpiTransferRequest::Read { .. },
                                    SpiTransferResponse::Read { data },
                                ) => spi::Transfer::Read(data),
                                (
                                    SpiTransferRequest::Write { data },
                                    SpiTransferResponse::Write,
                                ) => spi::Transfer::Write(data),
                                (
                                    SpiTransferRequest::Both { data: wdata },
                                    SpiTransferResponse::Both { data },
                                ) => spi::Transfer::Both(wdata, data),
                                (SpiTransferRequest::TpmPoll, SpiTransferResponse::TpmPoll) => {
                                    spi::Transfer::TpmPoll
                                }
                                (SpiTransferRequest::GscReady, SpiTransferResponse::GscReady) => {
                                    spi::Transfer::GscReady
                                }
                                _ => {
                                    // This can only happen if the logic in this method is
                                    // flawed.  (Never due to network input.)
                                    panic!("Mismatch");
                                }
                            })
                            .collect();
                        instance.run_transaction(&mut transaction)?;
                        Ok(Response::Spi(SpiResponse::RunTransaction {
                            transaction: resps,
                        }))
                    }
                    SpiRequest::AssertChipSelect => {
                        // Add a `spi::AssertChipSelect` object to the stack for this particular
                        // SPI instance.
                        self.spi_chip_select
                            .entry(id.to_string())
                            .or_default()
                            .push(instance.assert_cs()?);
                        Ok(Response::Spi(SpiResponse::AssertChipSelect))
                    }
                    SpiRequest::DeassertChipSelect => {
                        // Remove a `spi::AssertChipSelect` object from the stack for this
                        // particular SPI instance.
                        self.spi_chip_select
                            .get_mut(id)
                            .ok_or(TransportError::InvalidOperation)?
                            .pop()
                            .ok_or(TransportError::InvalidOperation)?;
                        Ok(Response::Spi(SpiResponse::DeassertChipSelect))
                    }
                }
            }
            Request::I2c { id, command } => {
                let instance = self.transport.i2c(id)?;
                match command {
                    I2cRequest::SetModeHost => {
                        instance.set_mode(i2c::Mode::Host)?;
                        Ok(Response::I2c(I2cResponse::SetModeHost))
                    }
                    I2cRequest::SetModeDevice { addr } => {
                        instance.set_mode(i2c::Mode::Device(*addr))?;
                        Ok(Response::I2c(I2cResponse::SetModeDevice))
                    }
                    I2cRequest::GetMaxSpeed => {
                        let speed = instance.get_max_speed()?;
                        Ok(Response::I2c(I2cResponse::GetMaxSpeed { speed }))
                    }
                    I2cRequest::SetMaxSpeed { value } => {
                        instance.set_max_speed(*value)?;
                        Ok(Response::I2c(I2cResponse::SetMaxSpeed))
                    }
                    I2cRequest::SetPins {
                        serial_clock,
                        serial_data,
                        gsc_ready,
                    } => {
                        instance.set_pins(
                            self.optional_pin(serial_clock)?.as_ref(),
                            self.optional_pin(serial_data)?.as_ref(),
                            self.optional_pin(gsc_ready)?.as_ref(),
                        )?;
                        Ok(Response::I2c(I2cResponse::SetPins))
                    }
                    I2cRequest::RunTransaction {
                        address,
                        transaction: reqs,
                    } => {
                        // Construct proper response to each transfer in request.
                        let mut resps: Vec<I2cTransferResponse> = reqs
                            .iter()
                            .map(|transfer| match transfer {
                                I2cTransferRequest::Read { len } => I2cTransferResponse::Read {
                                    data: vec![0; *len as usize],
                                },
                                I2cTransferRequest::Write { .. } => I2cTransferResponse::Write,
                                I2cTransferRequest::GscReady => I2cTransferResponse::GscReady,
                            })
                            .collect();
                        // Now carefully craft a proper parameter to the
                        // `i2c::Bus::run_transactions()` method.  It will have reference
                        // into elements of both the request vector and mutable reference into
                        // the response vector.
                        let mut transaction: Vec<i2c::Transfer> = reqs
                            .iter()
                            .zip(resps.iter_mut())
                            .map(|pair| match pair {
                                (
                                    I2cTransferRequest::Read { .. },
                                    I2cTransferResponse::Read { data },
                                ) => i2c::Transfer::Read(data),
                                (
                                    I2cTransferRequest::Write { data },
                                    I2cTransferResponse::Write,
                                ) => i2c::Transfer::Write(data),
                                (I2cTransferRequest::GscReady, I2cTransferResponse::GscReady) => {
                                    i2c::Transfer::GscReady
                                }
                                _ => {
                                    // This can only happen if the logic in this method is
                                    // flawed.  (Never due to network input.)
                                    panic!("Mismatch");
                                }
                            })
                            .collect();
                        instance.run_transaction(*address, &mut transaction)?;
                        Ok(Response::I2c(I2cResponse::RunTransaction {
                            transaction: resps,
                        }))
                    }
                    I2cRequest::GetDeviceStatus { timeout_millis } => {
                        let status = instance
                            .get_device_status(Duration::from_millis(*timeout_millis as u64))?;
                        Ok(Response::I2c(I2cResponse::GetDeviceStatus { status }))
                    }
                    I2cRequest::PrepareReadData { data, sticky } => {
                        instance.prepare_read_data(data, *sticky)?;
                        Ok(Response::I2c(I2cResponse::PrepareReadData))
                    }
                }
            }
            Request::Emu { command } => {
                let instance = self.transport.emulator()?;
                match command {
                    EmuRequest::GetState => Ok(Response::Emu(EmuResponse::GetState {
                        state: instance.get_state()?,
                    })),
                    EmuRequest::Start {
                        factory_reset,
                        args,
                    } => {
                        instance.start(*factory_reset, args)?;
                        Ok(Response::Emu(EmuResponse::Start))
                    }
                    EmuRequest::Stop => {
                        instance.stop()?;
                        Ok(Response::Emu(EmuResponse::Stop))
                    }
                }
            }
            Request::Proxy(command) => match command {
                ProxyRequest::Provides {} => {
                    let provides_map = self.transport.provides_map()?.clone();
                    Ok(Response::Proxy(ProxyResponse::Provides { provides_map }))
                }
                ProxyRequest::Bootstrap { options, payload } => {
                    Bootstrap::update(self.transport, options, payload)?;
                    Ok(Response::Proxy(ProxyResponse::Bootstrap))
                }
                ProxyRequest::ApplyPinStrapping { strapping_name } => {
                    self.transport.pin_strapping(strapping_name)?.apply()?;
                    Ok(Response::Proxy(ProxyResponse::ApplyPinStrapping))
                }
                ProxyRequest::RemovePinStrapping { strapping_name } => {
                    self.transport.pin_strapping(strapping_name)?.remove()?;
                    Ok(Response::Proxy(ProxyResponse::RemovePinStrapping))
                }
                ProxyRequest::ApplyDefaultConfigurationWithStrapping { strapping_name } => {
                    self.transport
                        .apply_default_configuration(Some(strapping_name))?;
                    Ok(Response::Proxy(
                        ProxyResponse::ApplyDefaultConfigurationWithStrapping,
                    ))
                }
            },
        }
    }
}

impl<'a> CommandHandler<Message, NonblockingUartRegistry> for TransportCommandHandler<'a> {
    /// This method will perform whatever action on the underlying `Transport` that is requested
    /// by the given `Message`, and return a response to be sent to the client.  Any `Err`
    /// return from this method will be treated as an irrecoverable protocol error, causing an
    /// error message in the server log, and the connection to be terminated.
    fn execute_cmd(
        &mut self,
        conn_token: Token,
        registry: &Registry,
        others: &mut NonblockingUartRegistry,
        msg: &Message,
    ) -> Result<Message> {
        if let Message::Req(req) = msg {
            // Package either `Ok()` or `Err()` into a `Message`, to be sent via network.
            return Ok(Message::Res(
                self.do_execute_cmd(conn_token, registry, others, req)
                    .map_err(SerializedError::from),
            ));
        }
        bail!("Client sent non-Request to server!!!");
    }

    fn register_nonblocking_help(&self, registry: &mio::Registry, token: mio::Token) -> Result<()> {
        self.nonblocking_help
            .register_nonblocking_help(registry, token)
    }

    fn nonblocking_help(&self) -> Result<()> {
        self.nonblocking_help.nonblocking_help()
    }
}
