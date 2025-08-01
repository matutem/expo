// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pinmux toplevel.
//

`include "prim_assert.sv"

module pinmux
  import pinmux_pkg::*;
  import pinmux_reg_pkg::*;
  import prim_pad_wrapper_pkg::*;
#(
  // Taget-specific pinmux configuration passed down from the
  // target-specific top-level.
  parameter target_cfg_t TargetCfg = DefaultTargetCfg,
% if enable_strap_sampling:
  parameter bit SecVolatileRawUnlockEn = 0,
% endif
  parameter logic [NumAlerts-1:0] AlertAsyncOn = {NumAlerts{1'b1}},
  // Number of cycles a differential skew is tolerated on the alert signal
  parameter int unsigned AlertSkewCycles = 1
) (
  input                            clk_i,
  input                            rst_ni,
  input                            rst_sys_ni,
  // Scan enable
  input  prim_mubi_pkg::mubi4_t    scanmode_i,
  // Slow always-on clock
  input                            clk_aon_i,
  input                            rst_aon_ni,
  // Wakeup request, running on clk_aon_i
  output logic                     pin_wkup_req_o,
% if enable_usb_wakeup:
  output logic                     usb_wkup_req_o,
% endif
  // Sleep enable and strap sample enable
  // from pwrmgr, running on clk_i
  input                            sleep_en_i,
% if enable_strap_sampling:
  input                            strap_en_i,
  // ---------- VOLATILE_TEST_UNLOCKED CODE SECTION START ----------
  // NOTE THAT THIS IS A FEATURE FOR TEST CHIPS ONLY TO MITIGATE
  // THE RISK OF A BROKEN OTP MACRO. THIS WILL BE DISABLED VIA
  // SecVolatileRawUnlockEn AT COMPILETIME FOR PRODUCTION DEVICES.
  // ---------------------------------------------------------------
  // Strap sampling override that is only used when SecVolatileRawUnlockEn = 1, Otherwise this input
  // is unused. This needs to be synchronized since it is coming from a different clock domain.
  // This signal goes from 0 -> 1 and then stays high, since we only ever re-sample once. The
  // synchronization logic can therefore just detect the edge to create the sampling pulse
  // internally.
  input                            strap_en_override_i,
  // ----------- VOLATILE_TEST_UNLOCKED CODE SECTION END -----------
  // LC signals for TAP qualification
  // SEC_CM: LC_DFT_EN.INTERSIG.MUBI
  input  lc_ctrl_pkg::lc_tx_t      lc_dft_en_i,
  // SEC_CM: LC_HW_DEBUG_CLR.INTERSIG.MUBI
  input  lc_ctrl_pkg::lc_tx_t      lc_hw_debug_clr_i,
  // SEC_CM: LC_HW_DEBUG_EN.INTERSIG.MUBI
  input  lc_ctrl_pkg::lc_tx_t      lc_hw_debug_en_i,
  // SEC_CM: LC_CHECK_BYP_EN.INTERSIG.MUBI
  input  lc_ctrl_pkg::lc_tx_t      lc_check_byp_en_i,
  // SEC_CM: LC_ESCALATE_EN.INTERSIG.MUBI
  input  lc_ctrl_pkg::lc_tx_t      lc_escalate_en_i,
  // SEC_CM: PINMUX_HW_DEBUG_EN.INTERSIG.MUBI
  output lc_ctrl_pkg::lc_tx_t      pinmux_hw_debug_en_o,
  // Sampled values for DFT straps
  output dft_strap_test_req_t      dft_strap_test_o,
  // DFT indication to stop tap strap sampling
  input                            dft_hold_tap_sel_i,
  // Qualified JTAG signals for TAPs
  output jtag_pkg::jtag_req_t      lc_jtag_o,
  input  jtag_pkg::jtag_rsp_t      lc_jtag_i,
  output jtag_pkg::jtag_req_t      rv_jtag_o,
  input  jtag_pkg::jtag_rsp_t      rv_jtag_i,
  output jtag_pkg::jtag_req_t      dft_jtag_o,
  input  jtag_pkg::jtag_rsp_t      dft_jtag_i,
% endif
% if enable_usb_wakeup:
  // Direct USB connection
  input                            usbdev_dppullup_en_i,
  input                            usbdev_dnpullup_en_i,
  output                           usb_dppullup_en_o,
  output                           usb_dnpullup_en_o,
  input                            usbdev_suspend_req_i,
  input                            usbdev_wake_ack_i,
  output                           usbdev_bus_not_idle_o,
  output                           usbdev_bus_reset_o,
  output                           usbdev_sense_lost_o,
  output                           usbdev_wake_detect_active_o,
% endif
  // Bus Interface (device)
  input  tlul_pkg::tl_h2d_t        tl_i,
  output tlul_pkg::tl_d2h_t        tl_o,
  // Alerts
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,
  // Muxed Peripheral side
  input        [NMioPeriphOut-1:0] periph_to_mio_i,
  input        [NMioPeriphOut-1:0] periph_to_mio_oe_i,
  output logic [NMioPeriphIn-1:0]  mio_to_periph_o,
  // Dedicated Peripheral side
  input        [NDioPads-1:0]      periph_to_dio_i,
  input        [NDioPads-1:0]      periph_to_dio_oe_i,
  output logic [NDioPads-1:0]      dio_to_periph_o,
  // Pad side
  // MIOs
  output prim_pad_wrapper_pkg::pad_attr_t [NMioPads-1:0] mio_attr_o,
  output logic                            [NMioPads-1:0] mio_out_o,
  output logic                            [NMioPads-1:0] mio_oe_o,
  input                                   [NMioPads-1:0] mio_in_i,
  // DIOs
  output prim_pad_wrapper_pkg::pad_attr_t [NDioPads-1:0] dio_attr_o,
  output logic                            [NDioPads-1:0] dio_out_o,
  output logic                            [NDioPads-1:0] dio_oe_o,
  input                                   [NDioPads-1:0] dio_in_i
);

  //////////////////////////////////
  // Regfile Breakout and Mapping //
  //////////////////////////////////

  logic [NumAlerts-1:0] alert_test, alerts;
  pinmux_reg2hw_t reg2hw;
  pinmux_hw2reg_t hw2reg;

  pinmux_reg_top u_reg (
    .clk_i,
    .rst_ni,
    .clk_aon_i,
    .rst_aon_ni,
    .tl_i,
    .tl_o,
    .reg2hw,
    .hw2reg,
    // SEC_CM: BUS.INTEGRITY
    .intg_err_o(alerts[0])
  );

  ////////////
  // Alerts //
  ////////////

  assign alert_test = {
    reg2hw.alert_test.q &
    reg2hw.alert_test.qe
  };

  for (genvar i = 0; i < NumAlerts; i++) begin : gen_alert_tx
    prim_alert_sender #(
      .AsyncOn(AlertAsyncOn[i]),
      .SkewCycles(AlertSkewCycles),
      .IsFatal(1'b1)
    ) u_prim_alert_sender (
      .clk_i,
      .rst_ni,
      .alert_test_i  ( alert_test[i] ),
      .alert_req_i   ( alerts[0]     ),
      .alert_ack_o   (               ),
      .alert_state_o (               ),
      .alert_rx_i    ( alert_rx_i[i] ),
      .alert_tx_o    ( alert_tx_o[i] )
    );
  end

  /////////////////////////////
  // Pad attribute registers //
  /////////////////////////////

  prim_pad_wrapper_pkg::pad_attr_t [NDioPads-1:0] dio_pad_attr_q;
  prim_pad_wrapper_pkg::pad_attr_t [NMioPads-1:0] mio_pad_attr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      dio_pad_attr_q <= '0;
      for (int kk = 0; kk < NMioPads; kk++) begin
        if (kk == TargetCfg.tap_strap0_idx) begin
          // TAP strap 0 is sampled after reset (and only once for life cycle states that are not
          // TEST_UNLOCKED* or RMA).  To ensure it gets sampled as 0 unless driven to 1 from an
          // external source (and specifically that it gets sampled as 0 when left floating / not
          // connected), this enables the pull-down of the pad at reset.
          mio_pad_attr_q[kk] <= '{pull_en: 1'b1, default: '0};
        end else begin
          mio_pad_attr_q[kk] <= '0;
        end
      end
    end else begin
      // dedicated pads
      for (int kk = 0; kk < NDioPads; kk++) begin
        if (reg2hw.dio_pad_attr[kk].drive_strength.qe) begin
          dio_pad_attr_q[kk].drive_strength <= reg2hw.dio_pad_attr[kk].drive_strength.q;
        end
        if (reg2hw.dio_pad_attr[kk].slew_rate.qe) begin
          dio_pad_attr_q[kk].slew_rate      <= reg2hw.dio_pad_attr[kk].slew_rate.q;
        end
        if (reg2hw.dio_pad_attr[kk].input_disable.qe) begin
          dio_pad_attr_q[kk].input_disable  <= reg2hw.dio_pad_attr[kk].input_disable.q;
        end
        if (reg2hw.dio_pad_attr[kk].od_en.qe) begin
          dio_pad_attr_q[kk].od_en          <= reg2hw.dio_pad_attr[kk].od_en.q;
        end
        if (reg2hw.dio_pad_attr[kk].schmitt_en.qe) begin
          dio_pad_attr_q[kk].schmitt_en     <= reg2hw.dio_pad_attr[kk].schmitt_en.q;
        end
        if (reg2hw.dio_pad_attr[kk].keeper_en.qe) begin
          dio_pad_attr_q[kk].keep_en        <= reg2hw.dio_pad_attr[kk].keeper_en.q;
        end
        if (reg2hw.dio_pad_attr[kk].pull_select.qe) begin
          dio_pad_attr_q[kk].pull_select    <= reg2hw.dio_pad_attr[kk].pull_select.q;
        end
        if (reg2hw.dio_pad_attr[kk].pull_en.qe) begin
          dio_pad_attr_q[kk].pull_en        <= reg2hw.dio_pad_attr[kk].pull_en.q;
        end
        if (reg2hw.dio_pad_attr[kk].virtual_od_en.qe) begin
          dio_pad_attr_q[kk].virt_od_en     <= reg2hw.dio_pad_attr[kk].virtual_od_en.q;
        end
        if (reg2hw.dio_pad_attr[kk].invert.qe) begin
          dio_pad_attr_q[kk].invert         <= reg2hw.dio_pad_attr[kk].invert.q;
        end
      end
      // muxed pads
      for (int kk = 0; kk < NMioPads; kk++) begin
        if (reg2hw.mio_pad_attr[kk].drive_strength.qe) begin
          mio_pad_attr_q[kk].drive_strength <= reg2hw.mio_pad_attr[kk].drive_strength.q;
        end
        if (reg2hw.mio_pad_attr[kk].slew_rate.qe) begin
          mio_pad_attr_q[kk].slew_rate      <= reg2hw.mio_pad_attr[kk].slew_rate.q;
        end
        if (reg2hw.mio_pad_attr[kk].input_disable.qe) begin
          mio_pad_attr_q[kk].input_disable  <= reg2hw.mio_pad_attr[kk].input_disable.q;
        end
        if (reg2hw.mio_pad_attr[kk].od_en.qe) begin
          mio_pad_attr_q[kk].od_en          <= reg2hw.mio_pad_attr[kk].od_en.q;
        end
        if (reg2hw.mio_pad_attr[kk].schmitt_en.qe) begin
          mio_pad_attr_q[kk].schmitt_en     <= reg2hw.mio_pad_attr[kk].schmitt_en.q;
        end
        if (reg2hw.mio_pad_attr[kk].keeper_en.qe) begin
          mio_pad_attr_q[kk].keep_en        <= reg2hw.mio_pad_attr[kk].keeper_en.q;
        end
        if (reg2hw.mio_pad_attr[kk].pull_select.qe) begin
          mio_pad_attr_q[kk].pull_select    <= reg2hw.mio_pad_attr[kk].pull_select.q;
        end
        if (reg2hw.mio_pad_attr[kk].pull_en.qe) begin
          mio_pad_attr_q[kk].pull_en        <= reg2hw.mio_pad_attr[kk].pull_en.q;
        end
        if (reg2hw.mio_pad_attr[kk].virtual_od_en.qe) begin
          mio_pad_attr_q[kk].virt_od_en     <= reg2hw.mio_pad_attr[kk].virtual_od_en.q;
        end
        if (reg2hw.mio_pad_attr[kk].invert.qe) begin
          mio_pad_attr_q[kk].invert         <= reg2hw.mio_pad_attr[kk].invert.q;
        end
      end
    end
  end

  ////////////////////////
  // Connect attributes //
  ////////////////////////

  pad_attr_t [NDioPads-1:0] dio_attr;
  for (genvar k = 0; k < NDioPads; k++) begin : gen_dio_attr
    pad_attr_t warl_mask;

    prim_pad_attr #(
      .PadType(TargetCfg.dio_pad_type[k])
    ) u_prim_pad_attr (
      .attr_warl_o(warl_mask)
    );

    assign dio_attr[k]                             = dio_pad_attr_q[k] & warl_mask;
    assign hw2reg.dio_pad_attr[k].drive_strength.d = dio_attr[k].drive_strength;
    assign hw2reg.dio_pad_attr[k].slew_rate.d      = dio_attr[k].slew_rate;
    assign hw2reg.dio_pad_attr[k].input_disable.d  = dio_attr[k].input_disable;
    assign hw2reg.dio_pad_attr[k].od_en.d          = dio_attr[k].od_en;
    assign hw2reg.dio_pad_attr[k].schmitt_en.d     = dio_attr[k].schmitt_en;
    assign hw2reg.dio_pad_attr[k].keeper_en.d      = dio_attr[k].keep_en;
    assign hw2reg.dio_pad_attr[k].pull_select.d    = dio_attr[k].pull_select;
    assign hw2reg.dio_pad_attr[k].pull_en.d        = dio_attr[k].pull_en;
    assign hw2reg.dio_pad_attr[k].virtual_od_en.d  = dio_attr[k].virt_od_en;
    assign hw2reg.dio_pad_attr[k].invert.d         = dio_attr[k].invert;
  end

  pad_attr_t [NMioPads-1:0] mio_attr;
  for (genvar k = 0; k < NMioPads; k++) begin : gen_mio_attr
    pad_attr_t warl_mask;

    prim_pad_attr #(
      .PadType(TargetCfg.mio_pad_type[k])
    ) u_prim_pad_attr (
      .attr_warl_o(warl_mask)
    );

    assign mio_attr[k]                             = mio_pad_attr_q[k] & warl_mask;
    assign hw2reg.mio_pad_attr[k].drive_strength.d = mio_attr[k].drive_strength;
    assign hw2reg.mio_pad_attr[k].slew_rate.d      = mio_attr[k].slew_rate;
    assign hw2reg.mio_pad_attr[k].input_disable.d  = mio_attr[k].input_disable;
    assign hw2reg.mio_pad_attr[k].od_en.d          = mio_attr[k].od_en;
    assign hw2reg.mio_pad_attr[k].schmitt_en.d     = mio_attr[k].schmitt_en;
    assign hw2reg.mio_pad_attr[k].keeper_en.d      = mio_attr[k].keep_en;
    assign hw2reg.mio_pad_attr[k].pull_select.d    = mio_attr[k].pull_select;
    assign hw2reg.mio_pad_attr[k].pull_en.d        = mio_attr[k].pull_en;
    assign hw2reg.mio_pad_attr[k].virtual_od_en.d  = mio_attr[k].virt_od_en;
    assign hw2reg.mio_pad_attr[k].invert.d         = mio_attr[k].invert;
  end

  // Local versions of the input signals
  logic [NMioPads-1:0] mio_out, mio_oe, mio_in;
  logic [NDioPads-1:0] dio_out, dio_oe, dio_in;

% if enable_strap_sampling:

  //////////////////////////
  // Strap Sampling Logic //
  //////////////////////////

  logic strap_en;
  if (SecVolatileRawUnlockEn) begin : gen_strap_override
    logic strap_en_override_d, strap_en_override_q;
    prim_flop_2sync #(
      .Width(1),
      .ResetValue(0)
    ) u_prim_flop_2sync (
      .clk_i,
      .rst_ni,
      .d_i(strap_en_override_i),
      .q_o(strap_en_override_d)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin : p_strap_override_reg
      if(!rst_ni) begin
        strap_en_override_q <= 1'b0;
      end else begin
        strap_en_override_q <= strap_en_override_d;
      end
    end

    // Detect a change from 0 -> 1 on the override signal (it will stay at 1 afterwards).
    assign strap_en = strap_en_i || (strap_en_override_d && !strap_en_override_q);

    // The strap sampling override shall be set to high exactly once.
    `ASSUME(LcCtrlStrapSampleOverrideOnce_A,
        $rose(strap_en_override_i) |-> always strap_en_override_i)

  end else begin : gen_no_strap_override
    logic unused_strap_en_override;
    assign unused_strap_en_override = strap_en_override_i;
    assign strap_en = strap_en_i;
  end

  // This module contains the strap sampling and JTAG mux.
  // Affected inputs are intercepted/tapped before they go to the pinmux
  // matrix. Likewise, affected outputs are intercepted/tapped after the
  // retention registers.
  pinmux_strap_sampling #(
    .TargetCfg (TargetCfg)
  ) u_pinmux_strap_sampling (
    .clk_i,
    // Inside the pinmux, the strap sampling module is the only module using SYS_RST. The reason for
    // that is that SYS_RST reset will not be asserted during a NDM reset from the RV_DM and hence
    // it retains some of the TAP selection state during an active debug session where NDM reset
    // is triggered. To that end, the strap sampling module latches the lc_hw_debug_en_i signal
    // whenever strap_en_i is asserted. Note that this does not affect the DFT TAP selection, since
    // we always consume the live lc_dft_en_i signal.
    .rst_ni (rst_sys_ni),
    .scanmode_i,
    // To padring side
    .out_padring_o  ( {dio_out_o,  mio_out_o}  ),
    .oe_padring_o   ( {dio_oe_o ,  mio_oe_o }  ),
    .in_padring_i   ( {dio_in_i ,  mio_in_i }  ),
    .attr_padring_o ( {dio_attr_o, mio_attr_o} ),
    // To core side
    .out_core_i     ( {dio_out,  mio_out}  ),
    .oe_core_i      ( {dio_oe,   mio_oe}   ),
    .in_core_o      ( {dio_in,   mio_in}   ),
    .attr_core_i    ( {dio_attr, mio_attr} ),
    // Strap and JTAG signals
    .strap_en_i     ( strap_en ),
    .lc_dft_en_i,
    .lc_hw_debug_clr_i,
    .lc_hw_debug_en_i,
    .lc_escalate_en_i,
    .lc_check_byp_en_i,
    // This is the latched version of lc_hw_debug_en_i. We use it exclusively to gate the JTAG
    // signals and TAP side of the RV_DM so that RV_DM can remain live during an NDM reset cycle.
    .pinmux_hw_debug_en_o,
    .dft_strap_test_o,
    .dft_hold_tap_sel_i,
    .lc_jtag_o,
    .lc_jtag_i,
    .rv_jtag_o,
    .rv_jtag_i,
    .dft_jtag_o,
    .dft_jtag_i
  );
% else:
  // Just pass through these signals.
  assign { dio_out_o,  mio_out_o  }  = { dio_out,  mio_out  };
  assign { dio_oe_o ,  mio_oe_o   }  = { dio_oe,   mio_oe   };
  assign { dio_in,     mio_in     }  = { dio_in_i, mio_in_i };
  assign { dio_attr_o, mio_attr_o }  = { dio_attr, mio_attr };
% endif
% if enable_usb_wakeup:

  ///////////////////////////////////////
  // USB wake detect module connection //
  ///////////////////////////////////////

  // Dedicated Peripheral side
  usbdev_aon_wake u_usbdev_aon_wake (
    .clk_aon_i,
    .rst_aon_ni,

    // input signals for resume detection
    .usb_dp_i(dio_to_periph_o[TargetCfg.usb_dp_idx]),
    .usb_dn_i(dio_to_periph_o[TargetCfg.usb_dn_idx]),
    .usb_sense_i(mio_to_periph_o[TargetCfg.usb_sense_idx]),
    .usbdev_dppullup_en_i(usbdev_dppullup_en_i),
    .usbdev_dnpullup_en_i(usbdev_dnpullup_en_i),

    // output signals for pullup connectivity
    .usb_dppullup_en_o(usb_dppullup_en_o),
    .usb_dnpullup_en_o(usb_dnpullup_en_o),

    // tie this to something from usbdev to indicate its out of reset
    .suspend_req_aon_i(usbdev_suspend_req_i),
    .wake_ack_aon_i(usbdev_wake_ack_i),

    // wake/powerup request
    .wake_req_aon_o(usb_wkup_req_o),
    .bus_not_idle_aon_o(usbdev_bus_not_idle_o),
    .bus_reset_aon_o(usbdev_bus_reset_o),
    .sense_lost_aon_o(usbdev_sense_lost_o),
    .wake_detect_active_aon_o(usbdev_wake_detect_active_o)
  );
% endif

  /////////////////////////
  // Retention Registers //
  /////////////////////////

  logic sleep_en_q, sleep_trig;

  logic [NMioPads-1:0] mio_sleep_trig;
  logic [NMioPads-1:0] mio_out_retreg_d, mio_oe_retreg_d;
  logic [NMioPads-1:0] mio_out_retreg_q, mio_oe_retreg_q;

  logic [NDioPads-1:0] dio_sleep_trig;
  logic [NDioPads-1:0] dio_out_retreg_d, dio_oe_retreg_d;
  logic [NDioPads-1:0] dio_out_retreg_q, dio_oe_retreg_q;

  // Sleep entry trigger
  assign sleep_trig = sleep_en_i & ~sleep_en_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_sleep
    if (!rst_ni) begin
      sleep_en_q       <= 1'b0;
      mio_out_retreg_q <= '0;
      mio_oe_retreg_q  <= '0;
      dio_out_retreg_q <= '0;
      dio_oe_retreg_q  <= '0;
    end else begin
      sleep_en_q <= sleep_en_i;

      // MIOs
      for (int k = 0; k < NMioPads; k++) begin
        if (mio_sleep_trig[k]) begin
          mio_out_retreg_q[k] <= mio_out_retreg_d[k];
          mio_oe_retreg_q[k]  <= mio_oe_retreg_d[k];
        end
      end

      // DIOs
      for (int k = 0; k < NDioPads; k++) begin
        if (dio_sleep_trig[k]) begin
          dio_out_retreg_q[k] <= dio_out_retreg_d[k];
          dio_oe_retreg_q[k]  <= dio_oe_retreg_d[k];
        end
      end
    end
  end

  /////////////////////
  // MIO Input Muxes //
  /////////////////////

  localparam int AlignedMuxSize = (NMioPads + 2 > NDioPads) ? 2**$clog2(NMioPads + 2) :
                                                              2**$clog2(NDioPads);

  // stack input and default signals for convenient indexing below possible defaults:
  // constant 0 or 1. make sure mux is aligned to a power of 2 to avoid Xes.
  logic [AlignedMuxSize-1:0] mio_mux;
  assign mio_mux = AlignedMuxSize'({mio_in, 1'b1, 1'b0});

  for (genvar k = 0; k < NMioPeriphIn; k++) begin : gen_mio_periph_in
    // index using configured insel
    assign mio_to_periph_o[k] = mio_mux[reg2hw.mio_periph_insel[k].q];
  end

% if n_dio_pads > n_mio_pads + 2:
  // For configurations with NMioPads + 2 < NDioPads, mio_in is zero-extended to NDioPads bits for
  // convenience. However, mio_periph_insel is sized to select the lowest NMioPads + 2 bits. Most
  // of the zero bits cannot actually be selected. Tie them off to avoid lint warnings.
  logic unused_mio_mux;
  assign unused_mio_mux = ^{mio_mux[(AlignedMuxSize - 1):(NMioPads + 2)]};

% endif
  //////////////////////
  // MIO Output Muxes //
  //////////////////////

  // stack output data/enable and default signals for convenient indexing below
  // possible defaults: 0, 1 or 2 (high-Z). make sure mux is aligned to a power of 2 to avoid Xes.
  logic [2**$clog2(NMioPeriphOut+3)-1:0] periph_data_mux, periph_oe_mux;
  assign periph_data_mux  = $bits(periph_data_mux)'({periph_to_mio_i, 1'b0, 1'b1, 1'b0});
  assign periph_oe_mux    = $bits(periph_oe_mux)'({periph_to_mio_oe_i,  1'b0, 1'b1, 1'b1});

  for (genvar k = 0; k < NMioPads; k++) begin : gen_mio_out
    // Check individual sleep enable status bits
    assign mio_out[k] = reg2hw.mio_pad_sleep_status[k].q ?
                        mio_out_retreg_q[k]              :
                        periph_data_mux[reg2hw.mio_outsel[k].q];

    assign mio_oe[k]  = reg2hw.mio_pad_sleep_status[k].q ?
                        mio_oe_retreg_q[k]               :
                        periph_oe_mux[reg2hw.mio_outsel[k].q];

    // latch state when going to sleep
    // 0: drive low
    // 1: drive high
    // 2: high-z
    // 3: previous value
    assign mio_out_retreg_d[k] = (reg2hw.mio_pad_sleep_mode[k].q == 0) ? 1'b0 :
                                 (reg2hw.mio_pad_sleep_mode[k].q == 1) ? 1'b1 :
                                 (reg2hw.mio_pad_sleep_mode[k].q == 2) ? 1'b0 : mio_out[k];

    assign mio_oe_retreg_d[k] = (reg2hw.mio_pad_sleep_mode[k].q == 0) ? 1'b1 :
                                (reg2hw.mio_pad_sleep_mode[k].q == 1) ? 1'b1 :
                                (reg2hw.mio_pad_sleep_mode[k].q == 2) ? 1'b0 : mio_oe[k];

    // Activate sleep behavior only if it has been enabled
    assign mio_sleep_trig[k] = reg2hw.mio_pad_sleep_en[k].q & sleep_trig;
    assign hw2reg.mio_pad_sleep_status[k].d = 1'b1;
    assign hw2reg.mio_pad_sleep_status[k].de = mio_sleep_trig[k];
  end

  /////////////////////
  // DIO connections //
  /////////////////////

  // Inputs are just fed through
  assign dio_to_periph_o = dio_in;

  for (genvar k = 0; k < NDioPads; k++) begin : gen_dio_out
    // Check individual sleep enable status bits
    assign dio_out[k] = reg2hw.dio_pad_sleep_status[k].q ?
                        dio_out_retreg_q[k]              :
                        periph_to_dio_i[k];

    assign dio_oe[k]  = reg2hw.dio_pad_sleep_status[k].q ?
                        dio_oe_retreg_q[k]               :
                        periph_to_dio_oe_i[k];

    // latch state when going to sleep
    // 0: drive low
    // 1: drive high
    // 2: high-z
    // 3: previous value
    assign dio_out_retreg_d[k] = (reg2hw.dio_pad_sleep_mode[k].q == 0) ? 1'b0 :
                                 (reg2hw.dio_pad_sleep_mode[k].q == 1) ? 1'b1 :
                                 (reg2hw.dio_pad_sleep_mode[k].q == 2) ? 1'b0 : dio_out[k];

    assign dio_oe_retreg_d[k] = (reg2hw.dio_pad_sleep_mode[k].q == 0) ? 1'b1 :
                                (reg2hw.dio_pad_sleep_mode[k].q == 1) ? 1'b1 :
                                (reg2hw.dio_pad_sleep_mode[k].q == 2) ? 1'b0 : dio_oe[k];

    // Activate sleep behavior only if it has been enabled
    assign dio_sleep_trig[k] = reg2hw.dio_pad_sleep_en[k].q & sleep_trig;
    assign hw2reg.dio_pad_sleep_status[k].d = 1'b1;
    assign hw2reg.dio_pad_sleep_status[k].de = dio_sleep_trig[k];
  end

  //////////////////////
  // Wakeup detectors //
  //////////////////////

  // Wakeup detectors should not be connected to the scan clock, so filter
  // those inputs.
  logic [NDioPads-1:0] dio_wkup_no_scan;
  for (genvar k = 0; k < NDioPads; k++) begin : gen_dio_wkup_filter
    if (TargetCfg.dio_scan_role[k] == ScanClock) begin : gen_dio_scan
      always_comb begin
        dio_wkup_no_scan[k] = dio_in_i[k];
        if (prim_mubi_pkg::mubi4_test_true_strict(scanmode_i)) begin
          dio_wkup_no_scan[k] = 1'b0;
        end
      end
    end else begin : gen_no_dio_scan
      assign dio_wkup_no_scan[k] = dio_in_i[k];
    end
  end

  logic [NMioPads-1:0] mio_wkup_no_scan;
  for (genvar k = 0; k < NMioPads; k++) begin : gen_mio_wkup_filter
    if (TargetCfg.mio_scan_role[k] == ScanClock) begin : gen_mio_scan
      always_comb begin
        mio_wkup_no_scan[k] = mio_in_i[k];
        if (prim_mubi_pkg::mubi4_test_true_strict(scanmode_i)) begin
          mio_wkup_no_scan[k] = 1'b0;
        end
      end
    end else begin : gen_no_mio_scan
      assign mio_wkup_no_scan[k] = mio_in_i[k];
    end
  end

  // Wakeup detector taps are not affected by JTAG/strap
  // selection mux. I.e., we always sample the unmuxed inputs
  // that come directly from the pads.
  logic [AlignedMuxSize-1:0] dio_wkup_mux;
  logic [AlignedMuxSize-1:0] mio_wkup_mux;
  assign dio_wkup_mux = AlignedMuxSize'(dio_wkup_no_scan);
  // The two constants that are concatenated here make sure tha the selection
  // indices used to index this array are the same as the ones used to index
  // the mio_mux array above, where positions 0 and 1 select constant 0 and
  // 1, respectively.
  assign mio_wkup_mux = AlignedMuxSize'({mio_wkup_no_scan, 1'b1, 1'b0});

  logic [NWkupDetect-1:0] aon_wkup_req;
  for (genvar k = 0; k < NWkupDetect; k++) begin : gen_wkup_detect
    logic pin_value;
    assign pin_value = (reg2hw.wkup_detector[k].miodio.q)           ?
                       dio_wkup_mux[reg2hw.wkup_detector_padsel[k]] :
                       mio_wkup_mux[reg2hw.wkup_detector_padsel[k]];

    // This module runs on the AON clock entirely
    pinmux_wkup u_pinmux_wkup (
      .clk_i              (clk_aon_i                                     ),
      .rst_ni             (rst_aon_ni                                    ),
      // config signals have already been synced to the AON domain inside the CSR node.
      .wkup_en_i          ( reg2hw.wkup_detector_en[k].q                 ),
      .filter_en_i        ( reg2hw.wkup_detector[k].filter.q             ),
      .wkup_mode_i        ( wkup_mode_e'(reg2hw.wkup_detector[k].mode.q) ),
      .wkup_cnt_th_i      ( reg2hw.wkup_detector_cnt_th[k].q             ),
      .pin_value_i        ( pin_value                                    ),
      // wakeup request pulse on clk_aon, will be synced back to the bus domain insie the CSR node.
      .aon_wkup_pulse_o   ( hw2reg.wkup_cause[k].de                      )
    );

    assign hw2reg.wkup_cause[k].d = 1'b1;

    // This is the latched wakeup request, hence this request signal is level encoded.
    assign aon_wkup_req[k] = reg2hw.wkup_cause[k].q;
  end

  // OR' together all wakeup requests
  assign pin_wkup_req_o = |aon_wkup_req;

  ////////////////
  // Assertions //
  ////////////////

  `ASSERT_KNOWN(TlDValidKnownO_A, tl_o.d_valid)
  `ASSERT_KNOWN(TlAReadyKnownO_A, tl_o.a_ready)
  `ASSERT_KNOWN(AlertsKnown_A, alert_tx_o)
  `ASSERT_KNOWN(MioOeKnownO_A, mio_oe_o)
  `ASSERT_KNOWN(DioOeKnownO_A, dio_oe_o)

  `ASSERT_KNOWN(MioKnownO_A, mio_attr_o)
  `ASSERT_KNOWN(DioKnownO_A, dio_attr_o)
% if enable_strap_sampling:

  `ASSERT_KNOWN(LcJtagTckKnown_A, lc_jtag_o.tck)
  `ASSERT_KNOWN(LcJtagTrstKnown_A, lc_jtag_o.trst_n)
  `ASSERT_KNOWN(LcJtagTmsKnown_A, lc_jtag_o.tms)

  `ASSERT_KNOWN(RvJtagTckKnown_A, rv_jtag_o.tck)
  `ASSERT_KNOWN(RvJtagTrstKnown_A, rv_jtag_o.trst_n)
  `ASSERT_KNOWN(RvJtagTmsKnown_A, rv_jtag_o.tms)

  `ASSERT_KNOWN(DftJtagTckKnown_A, dft_jtag_o.tck)
  `ASSERT_KNOWN(DftJtagTrstKnown_A, dft_jtag_o.trst_n)
  `ASSERT_KNOWN(DftJtagTmsKnown_A, dft_jtag_o.tms)

  `ASSERT_KNOWN(DftStrapsKnown_A, dft_strap_test_o)
% endif

  // running on slow AON clock
  `ASSERT_KNOWN(AonWkupReqKnownO_A, pin_wkup_req_o, clk_aon_i, !rst_aon_ni)
% if enable_usb_wakeup:
  `ASSERT_KNOWN(UsbWkupReqKnownO_A, usb_wkup_req_o, clk_aon_i, !rst_aon_ni)
  `ASSERT_KNOWN(UsbWakeDetectActiveKnownO_A, usbdev_wake_detect_active_o, clk_aon_i, !rst_aon_ni)
% endif

  // The wakeup signal is not latched in the pwrmgr so must be held until acked by software
  `ASSUME(PinmuxWkupStable_A, pin_wkup_req_o |=> pin_wkup_req_o ||
      $fell(|reg2hw.wkup_cause) && !sleep_en_i, clk_aon_i, !rst_aon_ni)

  // Some inputs at the chip-level may be forced to X in chip-level simulations.
  // Therefore, we do not instantiate these assertions.
  // `ASSERT_KNOWN(MioToPeriphKnownO_A, mio_to_periph_o)
  // `ASSERT_KNOWN(DioToPeriphKnownO_A, dio_to_periph_o)

  // The assertions below are not instantiated for a similar reason as the assertions above.
  // I.e., some IPs have pass-through paths, which may lead to X'es propagating
  // from input to output.
  // for (genvar k = 0; k < NMioPads; k++) begin : gen_mio_known_if
  //   `ASSERT_KNOWN_IF(MioOutKnownO_A, mio_out_o[k], mio_oe_o[k])
  // end
  // for (genvar k = 0; k < NDioPads; k++) begin : gen_dio_known_if
  //   `ASSERT_KNOWN_IF(DioOutKnownO_A, dio_out_o[k], dio_oe_o[k])
  // end

  // Pinmux does not have a block-level DV environment, hence we add an FPV assertion to test this.
  `ASSERT(FpvSecCmBusIntegrity_A,
          $rose(u_reg.intg_err)
          |->
          ${"##"}[0:`_SEC_CM_ALERT_MAX_CYC] (alert_tx_o[0].alert_p))

  // Alert assertions for reg_we onehot check
  `ASSERT_PRIM_REG_WE_ONEHOT_ERROR_TRIGGER_ALERT(RegWeOnehotCheck_A, u_reg, alert_tx_o[0])
% if enable_strap_sampling:

  // The strap sampling enable input shall be pulsed high for exactly one cycle after cold boot.
  `ASSUME(PwrMgrStrapSampleOnce0_A, strap_en_i |=> !strap_en_i)
  `ASSUME(PwrMgrStrapSampleOnce1_A, $fell(strap_en_i) |-> always !strap_en_i)
% endif

endmodule : pinmux
