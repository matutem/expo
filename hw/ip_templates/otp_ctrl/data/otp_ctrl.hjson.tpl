// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// HJSON with partition metadata.
//
<%
from topgen.lib import Name

num_part = len(otp_mmap["partitions"])
num_part_unbuf = 0
for part in otp_mmap["partitions"]:
  if part["variant"] == "Unbuffered":
    num_part_unbuf += 1
num_part_buf = num_part - num_part_unbuf
otp_size_as_bytes = 2 ** otp_mmap["otp"]["byte_addr_width"]
otp_size_as_uint32 = otp_size_as_bytes // 4
%>\
{
  name:               "otp_ctrl",
  human_name:         "One-Time Programmable Memory Controller",
  one_line_desc:      "Interfaces integrated one-time programmable memory, supports scrambling, integrity and secure wipe",
  one_paragraph_desc: '''
  One-Time Programmable (OTP) Memory Controller provides an open source abstraction interface for software and other hardware components such as Life Cycle Controller and Key Manager to interact with an integrated, closed source, proprietary OTP memory.
  On top of defensive features provided by the proprietary OTP memory to deter side-channel analysis (SCA), fault injection (FI) attacks, and visual and electrical probing, the open source OTP controller features high-level logical security protection such as integrity checks and scrambling, as well as software isolation for when OTP contents are readable and programmable.
  It features multiple individually-lockable logical partitions, periodic / persistent checking of OTP values, and a separate partition and interface for Life Cycle Controller.
  '''
  // Unique comportable IP identifier defined under KNOWN_CIP_IDS in the regtool.
  cip_id:             "16",
  design_spec:        "../doc",
  dv_doc:             "../doc/dv",
  hw_checklist:       "../doc/checklist",
  sw_checklist:       "/sw/device/lib/dif/dif_otp_ctrl",
  revisions: [
    {
      version:            "0.1.0",
      life_stage:         "L1",
      design_stage:       "D2",
      verification_stage: "V2",
      dif_stage:          "S1",
      commit_id:          "127b109e2fab9336e830158abe449a3922544ded",
      notes:              "",
    }
    {
      version:            "1.0.0",
      life_stage:         "L1",
      design_stage:       "D3",
      verification_stage: "V2S",
      dif_stage:          "S2",
      notes:              "",
    }
    {
      version:            "2.0.0",
      life_stage:         "L1",
      design_stage:       "D3",
      verification_stage: "V2S",
      dif_stage:          "S2",
      notes:              "",
    }
  ]
  clocking: [
    {clock: "clk_i", reset: "rst_ni", primary: true},
    {clock: "clk_edn_i", reset: "rst_edn_ni"}
  ]
  bus_interfaces: [
    { protocol: "tlul", direction: "device", name: "core" }
  ],

  ///////////////////////////
  // Interrupts and Alerts //
  ///////////////////////////

  interrupt_list: [
    { name: "otp_operation_done",
      desc: "A direct access command or digest calculation operation has completed."
    }
    { name: "otp_error",
      desc: "An error has occurred in the OTP controller. Check the !!ERR_CODE register to get more information."
    }
  ],

  alert_list: [
    { name: "fatal_macro_error",
      desc: "This alert triggers if hardware detects an uncorrectable error during an OTP transaction, for example an uncorrectable ECC error in the OTP array.",
    }
    { name: "fatal_check_error",
      desc: "This alert triggers if any of the background checks fails. This includes the digest checks and concurrent ECC checks in the buffer registers.",
    }
    { name: "fatal_bus_integ_error",
      desc: "This fatal alert is triggered when a fatal TL-UL bus integrity fault is detected."
    }
    { name: "fatal_prim_otp_alert",
      desc: "Fatal alert triggered inside the OTP primitive, including fatal TL-UL bus integrity faults of the test interface."
    }
    { name: "recov_prim_otp_alert",
      desc: "Recoverable alert triggered inside the OTP primitive."
    }
  ],

  ////////////////
  // Parameters //
  ////////////////
  param_list: [
    // Random netlist constants
    { name:      "RndCnstLfsrSeed",
      desc:      "Compile-time random bits for initial LFSR seed",
      type:      "otp_ctrl_top_specific_pkg::lfsr_seed_t"
      randcount: "40",
      randtype:  "data", // randomize randcount databits
    }
    { name:      "RndCnstLfsrPerm",
      desc:      "Compile-time random permutation for LFSR output",
      type:      "otp_ctrl_top_specific_pkg::lfsr_perm_t"
      randcount: "40",
      randtype:  "perm", // random permutation for randcount elements
    }
    { name:      "RndCnstScrmblKeyInit",
      desc:      "Compile-time random permutation for scrambling key/nonce register reset value",
      type:      "otp_ctrl_top_specific_pkg::scrmbl_key_init_t"
      randcount: "256",
      randtype:  "data", // random permutation for randcount elements
    }
    // Normal parameters
    { name: "NumSramKeyReqSlots",
      desc: "Number of key slots",
      type: "int",
      default: "4",
      local: "true"
    },
    // Macro parameters
    {
      name: "OtpDepth",
      desc: "Number of native words.",
      default: "${otp_mmap["otp"]["depth"]}",
      local: "true"
    },
    {
      name: "OtpWidth",
      desc: "Number of bytes in native words.",
      default: "${otp_mmap["otp"]["width"]}",
      local: "true"
    },
    {
      name: "OtpSizeWidth",
      desc: "Number of bits to represent the native words per transaction.",
      default: "2",
      local: "true"
    },
    { name: "OtpByteAddrWidth",
      desc: "Width of the OTP byte address.",
      type: "int",
      default: "${otp_mmap["otp"]["byte_addr_width"]}",
      local: "true"
    },
    { name: "NumErrorEntries",
      desc: "Number of error register entries.",
      type: "int",
      default: "${num_part + 2}", // partitions + DAI/LCI
      local: "true"
    },
    { name: "NumDaiWords",
      desc: "Number of 32bit words in the DAI.",
      type: "int",
      default: "2",
      local: "true"
    },
    { name: "NumDigestWords",
      desc: "Size of the digest fields in 32bit words.",
      type: "int",
      default: "2",
      local: "true"
    },
    { name: "NumSwCfgWindowWords",
      desc: "Size of the TL-UL window in 32bit words. Note that the effective partition size is smaller than that.",
      type: "int",
      default: "${otp_size_as_uint32}",
      local: "true"
    }

    // Memory map Info
    { name: "NumPart",
      desc: "Number of partitions",
      type: "int",
      default: "${num_part}",
      local: "true"
    },
    { name: "NumPartUnbuf",
      desc: "Number of unbuffered partitions",
      type: "int",
      default: "${num_part_unbuf}",
      local: "true"
    },
    { name: "NumPartBuf",
      desc: "Number of buffered partitions (including 1 lifecycle partition)",
      type: "int",
      default: "${num_part_buf}",
      local: "true"
    },
% for part in otp_mmap["partitions"]:
<%
  part_name_camel = Name.to_camel_case(part["name"])
%>\
    { name: "${part_name_camel}Offset",
      desc: "Offset of the ${part["name"]} partition",
      type: "int",
      default: "${part["offset"]}",
      local: "true"
    },
    { name: "${part_name_camel}Size",
      desc: "Size of the ${part["name"]} partition",
      type: "int",
      default: "${part["size"]}",
      local: "true"
    },
  % for item in part["items"]:
<%
  item_name_camel = Name.to_camel_case(item["name"])
%>\
    { name: "${item_name_camel}Offset",
      desc: "Offset of ${item["name"]}",
      type: "int",
      default: "${item["offset"]}",
      local: "true"
    },
    { name: "${item_name_camel}Size",
      desc: "Size of ${item["name"]}",
      type: "int",
      default: "${item["size"]}",
      local: "true"
    },
  % endfor
% endfor
  ]

  /////////////////////////////
  // Intermodule Connections //
  /////////////////////////////

  inter_signal_list: [
    // EDN interface
    { struct:  "edn"
      type:    "req_rsp"
      name:    "edn"
      act:     "req"
      package: "edn_pkg"
      desc:    "Entropy request to the entropy distribution network for LFSR reseeding and ephemeral key derivation."
    }
    // Power manager init command
    { struct:  "pwr_otp"
      type:    "req_rsp"
      name:    "pwr_otp"
      act:     "rsp"
      default: "'0"
      package: "pwrmgr_pkg"
      desc:    "Initialization request/acknowledge from/to power manager."
    }
    // LC transition command
    { struct:  "lc_otp_program"
      type:    "req_rsp"
      name:    "lc_otp_program"
      act:     "rsp"
      default: "'0"
      package: "otp_ctrl_pkg"
      desc:    "Life cycle state transition interface."
    }
    // Broadcast to LC
    { struct:  "otp_lc_data"
      type:    "uni"
      name:    "otp_lc_data"
      act:     "req"
      default: "'0"
      package: "otp_ctrl_pkg"
      desc:    '''
               Life cycle state output holding the current life cycle state,
               the value of the transition counter and the tokens needed for life cycle transitions.
               '''
    }
    // Broadcast from LC
    { struct:  "lc_tx"
      type:    "uni"
      name:    "lc_escalate_en"
      act:     "rcv"
      default: "lc_ctrl_pkg::Off"
      package: "lc_ctrl_pkg"
      desc:    '''
               Life cycle escalation enable coming from life cycle controller.
               This signal moves all FSMs within OTP into the error state.
               '''
    }
    { struct:  "lc_tx"
      type:    "uni"
      name:    "lc_creator_seed_sw_rw_en"
      act:     "rcv"
      default: "lc_ctrl_pkg::Off"
      package: "lc_ctrl_pkg"
      desc:    '''
               Provision enable qualifier coming from life cycle controller.
               This signal enables SW read / write access to the RMA_TOKEN and CREATOR_ROOT_KEY_SHARE0 and CREATOR_ROOT_KEY_SHARE1.
               '''
    }
    { struct:  "lc_tx"
      type:    "uni"
      name:    "lc_owner_seed_sw_rw_en"
      act:     "rcv"
      default: "lc_ctrl_pkg::Off"
      package: "lc_ctrl_pkg"
      desc:    '''
               Provision enable qualifier coming from life cycle controller.
               This signal enables SW read / write access to the OWNER_SEED.
               '''
    }
    { struct:  "lc_tx"
      type:    "uni"
      name:    "lc_seed_hw_rd_en"
      act:     "rcv"
      default: "lc_ctrl_pkg::Off"
      package: "lc_ctrl_pkg"
      desc:    '''
               Seed read enable coming from life cycle controller.
               This signal enables HW read access to the CREATOR_ROOT_KEY_SHARE0 and CREATOR_ROOT_KEY_SHARE1.
               '''
    }
    { struct:  "lc_tx"
      type:    "uni"
      name:    "lc_check_byp_en"
      act:     "rcv"
      default: "lc_ctrl_pkg::Off"
      package: "lc_ctrl_pkg"
      desc:    '''
               Life cycle partition check bypass signal.
               This signal causes the life cycle partition to bypass consistency checks during life cycle state transitions in order to prevent spurious consistency check failures.
               '''
    }
    // Broadcast to Key Manager
    { struct:  "otp_keymgr_key"
      type:    "uni"
      name:    "otp_keymgr_key"
      act:     "req"
      default: "'0"
      package: "otp_ctrl_pkg"
      desc:    "Key output to the key manager holding CREATOR_ROOT_KEY_SHARE0 and CREATOR_ROOT_KEY_SHARE1."
    }
  % if enable_flash_key:
    // Broadcast to Flash Controller
    { struct:  "flash_otp_key"
      type:    "req_rsp"
      name:    "flash_otp_key"
      act:     "rsp"
      default: "'0"
      package: "otp_ctrl_pkg"
      desc:    "Key derivation interface for FLASH scrambling."
    }
  % endif
    // Key request from SRAM scramblers
    { struct:  "sram_otp_key"
      // TODO: would be nice if this could accept parameters.
      // Split this out into an issue.
      width:   "4"
      type:    "req_rsp"
      name:    "sram_otp_key"
      act:     "rsp"
      default: "'0"
      package: "otp_ctrl_pkg"
      desc:    "Array with key derivation interfaces for SRAM scrambling devices."
    }
    // Key request from OTBN RAM Scrambler
    { struct:  "otbn_otp_key"
      type:    "req_rsp"
      name:    "otbn_otp_key"
      act:     "rsp"
      default: "'0"
      package: "otp_ctrl_pkg"
      desc:    "Key derivation interface for OTBN scrambling devices."
    }
    // Hardware config partition
    { struct:  "otp_broadcast"
      type:    "uni"
      name:    "otp_broadcast"
      act:     "req"
      default: "'0"
      package: "otp_ctrl_part_pkg"
      desc:    "Output of the HW partitions with breakout data types."
    }
    // OTP_MACRO Interface
    { struct:  "otp_ctrl_macro"
      type:    "req_rsp"
      name:    "otp_macro"
      act:     "req"
      default: "'0"
      package: "otp_ctrl_macro_pkg"
      desc:    "Data interface for the OTP macro."
    }
  ] // inter_signal_list

  /////////////////////
  // Countermeasures //
  /////////////////////

  countermeasures: [
    { name: "BUS.INTEGRITY",
      desc: "End-to-end bus integrity scheme."
    }
    { name: "SECRET.MEM.SCRAMBLE",
      desc: "Secret partitions are scrambled with a full-round PRESENT cipher."
    }
    { name: "PART.MEM.DIGEST",
      desc: "Integrity of buffered partitions is ensured via a 64bit digest."
    }
    { name: "DAI.FSM.SPARSE",
      desc: "The direct access interface FSM is sparsely encoded."
    }
    { name: "KDI.FSM.SPARSE",
      desc: "The key derivation interface FSM is sparsely encoded."
    }
    { name: "LCI.FSM.SPARSE",
      desc: "The life cycle interface FSM is sparsely encoded."
    }
    { name: "PART.FSM.SPARSE",
      desc: "The partition FSMs are sparsely encoded."
    }
    { name: "SCRMBL.FSM.SPARSE",
      desc: "The scramble datapath FSM is sparsely encoded."
    }
    { name: "TIMER.FSM.SPARSE",
      desc: "The background check timer FSM is sparsely encoded."
    }
    { name: "DAI.CTR.REDUN",
      desc: "The direct access interface address counter employs a cross-counter implementation."
    }
    { name: "KDI_SEED.CTR.REDUN",
      desc: "The key derivation interface counter employs a cross-counter implementation."
    }
    { name: "KDI_ENTROPY.CTR.REDUN",
      desc: "The key derivation entropy counter employs a cross-counter implementation."
    }
    { name: "LCI.CTR.REDUN",
      desc: "The life cycle interface address counter employs a cross-counter implementation."
    }
    { name: "PART.CTR.REDUN",
      desc: "The address counter of buffered partitions employs a cross-counter implementation."
    }
    { name: "SCRMBL.CTR.REDUN",
      desc: "The srambling datapath counter employs a cross-counter implementation."
    }
    { name: "TIMER_INTEG.CTR.REDUN",
      desc: "The background integrity check timer employs a duplicated counter implementation."
    }
    { name: "TIMER_CNSTY.CTR.REDUN",
      desc: "The background consistency check timer employs a duplicated counter implementation."
    }
    { name: "TIMER.LFSR.REDUN",
      desc: "The background check LFSR is duplicated."
    }
    { name: "DAI.FSM.LOCAL_ESC",
      desc: "The direct access interface FSM is moved into an invalid state upon local escalation."
    }
    { name: "LCI.FSM.LOCAL_ESC",
      desc: "The life cycle interface FSM is moved into an invalid state upon local escalation."
    }
    { name: "KDI.FSM.LOCAL_ESC",
      desc: "The key derivation interface FSM is moved into an invalid state upon local escalation."
    }
    { name: "PART.FSM.LOCAL_ESC",
      desc: "The partition FSMs are moved into an invalid state upon local escalation."
    }
    { name: "SCRMBL.FSM.LOCAL_ESC",
      desc: "The scramble datapath FSM is moved into an invalid state upon local escalation."
    }
    { name: "TIMER.FSM.LOCAL_ESC",
      desc: "The background check timer FSM is moved into an invalid state upon local escalation."
    }
    { name: "DAI.FSM.GLOBAL_ESC",
      desc: "The direct access interface FSM is moved into an invalid state upon global escalation via life cycle."
    }
    { name: "LCI.FSM.GLOBAL_ESC",
      desc: "The life cycle interface FSM is moved into an invalid state upon global escalation via life cycle."
    }
    { name: "KDI.FSM.GLOBAL_ESC",
      desc: "The key derivation interface FSM is moved into an invalid state upon global escalation via life cycle."
    }
    { name: "PART.FSM.GLOBAL_ESC",
      desc: "The partition FSMs are moved into an invalid state upon global escalation via life cycle."
    }
    { name: "SCRMBL.FSM.GLOBAL_ESC",
      desc: "The scramble datapath FSM is moved into an invalid state upon global escalation via life cycle."
    }
    { name: "TIMER.FSM.GLOBAL_ESC",
      desc: "The background check timer FSM is moved into an invalid state upon global escalation via life cycle."
    }
    { name: "PART.DATA_REG.INTEGRITY",
      desc: "All partition buffer registers are protected with ECC on 64bit blocks."
    }
    { name: "PART.DATA_REG.BKGN_CHK",
      desc: "The digest of buffered partitions is recomputed and checked at pseudorandom intervals in the background."
    }
    { name: "PART.MEM.REGREN"
      desc: "Unbuffered ('software') partitions can be read-locked via a CSR until the next system reset."
    }
    { name: "PART.MEM.SW_UNREADABLE"
      desc: "Secret buffered partitions become unreadable to software once they are locked via the digest."
    }
    { name: "PART.MEM.SW_UNWRITABLE"
      desc: "All partitions become unwritable by software once they are locked via the digest."
    }
    { name: "LC_PART.MEM.SW_NOACCESS"
      desc: "The life cycle partition is not directly readable nor writable via software."
    }
    { name: "ACCESS.CTRL.MUBI",
      desc: "The access control signals going from the partitions to the DAI are MUBI encoded."
    }
    { name: "TOKEN_VALID.CTRL.MUBI",
      desc: "The token valid signals going to the life cycle controller are MUBI encoded."
    }
    { name: "LC_CTRL.INTERSIG.MUBI",
      desc: "The life cycle control signals are multibit encoded."
    }
    { name: "DIRECT_ACCESS.CONFIG.REGWEN",
      desc: "The direct access CSRs are REGWEN protected."
    }
    { name: "CHECK_TRIGGER.CONFIG.REGWEN",
      desc: "The check trigger CSR is REGWEN protected."
    }
    { name: "CHECK.CONFIG.REGWEN",
      desc: "The check CSR is REGWEN protected."
    }
  ]

  features: [
    {
      name: "OTP_CTRL.PARTITION.VENDOR_TEST"
      desc: '''Vendor test partition is used for OTP programming smoke check during manufacturing flow.
      In this partition, ECC uncorrectable errors will not lead to fatal errors and alerts.
      Instead the error will be reported as correctable ECC error.
      '''
    }
    {
      name: "OTP_CTRL.PARTITION.CREATOR_SW_CFG"
      desc: '''During calibration stage, various parameters (clock, voltage, and timing sources) are calibrated and recorded to CREATOR_SW_CFG partition.
      '''
    }
    {
      name: "OTP_CTRL.PARTITION.OWNER_SW_CFG"
      desc: "Define attributes for rom code execution"
    }
    {
      name: "OTP_CTRL.INIT"
      desc: '''When power is up, OTP controller reads devices status.
      After all reads complete, the controller performs integrity check on the HW_CFG* and SECRET partitions.
      Once all integrity checks are complete, the controller marks outputs as valid.
      '''
    }
    {
      name: "OTP_CTRL.ENTROPY_READ"
      desc: '''Firmware can read entropy from ENTROPY_SRC block by configuring following field of HW_CFG* partition.
        - EN_CSRNG_SW_APP_READ
      '''
    }
    {
      name: "OTP_CTRL.KEY_DERIVATION"
      desc: "OTP controller participate key derivation process by providing scramble key seed to SRAM_CTRL${" and FLASH_CTRL" if enable_flash_key else ""}."
    }
    {
      name: "OTP_CTRL.PROGRAM"
      desc: '''All other partitions except life cycle partition are programmed through DAI interface.
      And once non-zero digest is programmed to these partition, no further write access is allowed.
      Life cycle partition is programmed by LC_CTRL.
      '''
    }
    {
      name: "OTP_CTRL.PARTITION.SECRET0"
      desc: "Test unlock tokens, Test exit token"
    }
    {
      name: "OTP_CTRL.PARTITION.SECRET1"
      desc: "SRAM${" and FLASH" if enable_flash_key else ""} scrambling key"
    }
    {
      name: "OTP_CTRL.PARTITION.SECRET2"
      desc: "RMA unlock token and creator root key"
    }
    {
      name: "OTP_CTRL.PARTITION.LIFE_CYCLE"
      desc: '''LC state, LC transition count.
      This feature is owned by the LC_CTRL and cannot be tested well through the OTP_CTRL CSR interface.
      '''
    }
    {
      name: "OTP_CTRL.PARTITIONS_FEATURE.READ_LOCK"
      desc: '''Following partitions can be read lockable by CSR.
                 - VENDOR_TEST
                 - CREATOR_SW_CFG
                 - OWNER_SW_CFG
               Following partitions can be read lockable by writing digest.
                 - SECRET0
                 - SECRET1
                 - RECRET2
      All read attempt to these partitions after read is locked will trigger AccessError (recoverable).
      '''
    }
    {
      name: "OTP_CTRL.PARTITIONS_FEATURE.WRITE_LOCK"
      desc: "All partitions except LIFE_CYCLE can be write lockable by writing digest."
    }
    {
      name: "OTP_CTRL.ERROR_HANDLING.RECOVERABLE"
      desc: "Recoverable error is created when unauthorized access attempt are detected via dai interface."
    }
    {
      name: "OTP_CTRL.ERROR_HANDLING.FATAL"
      desc: "Unrecoverable errors are created for uncorrectable ecc error, otp macro malfunction and unauthorized access via lc_ctrl."
    }
    {
      name: "OTP_CTRL.BACKGROUND_CHECK.CHECK_TIMEOUT"
      desc: "Timeout value for the integrity and consistency checks."
    }
    {
      name: "OTP_CTRL.BACKGROUND_CHECK.INTEGRITY_CHECK_PERIOD"
      desc: "The interval which the digest of the partition is recomputed to check integrity of locked partition."
    }
    {
      name: "OTP_CTRL.BACKGROUND_CHECK.CONSISTENCY_CHECK_PERIOD"
      desc: "Re-read period of the buffer registers to ensure data is matched with the associated OTP partition."
    }
  ]

  ///////////////
  // Registers //
  ///////////////

  regwidth: "32",
  registers: {
    core: [
      ////////////////////////
      // Ctrl / Status CSRs //
      ////////////////////////

      { name: "STATUS",
        desc: "OTP status register.",
        swaccess: "ro",
        hwaccess: "hwo",
        hwext:    "true",
        resval:   0,
        tags: [ // OTP internal HW can modify status register
                "excl:CsrAllTests:CsrExclCheck"],
        fields: [
  % for k, part in enumerate(otp_mmap["partitions"]):
          { bits: "${k}"
            name: "${part["name"]}_ERROR"
            desc: '''
                  Set to 1 if an error occurred in this partition.
                  If set to 1, SW should check the !!ERR_CODE register at the corresponding index.
                  '''
          }
  % endfor
          { bits: "${num_part}"
            name: "DAI_ERROR"
            desc: '''
                  Set to 1 if an error occurred in the DAI.
                  If set to 1, SW should check the !!ERR_CODE register at the corresponding index.
                  '''
          }
          { bits: "${num_part+1}"
            name: "LCI_ERROR"
            desc: '''
                  Set to 1 if an error occurred in the LCI.
                  If set to 1, SW should check the !!ERR_CODE register at the corresponding index.
                  '''
          }
          { bits: "${num_part+2}"
            name: "TIMEOUT_ERROR"
            desc: '''
                  Set to 1 if an integrity or consistency check times out.
                  This raises an fatal_check_error alert and is an unrecoverable error condition.
                  '''
          }
          { bits: "${num_part+3}"
            name: "LFSR_FSM_ERROR"
            desc: '''
                  Set to 1 if the LFSR timer FSM has reached an invalid state.
                  This raises an fatal_check_error alert and is an unrecoverable error condition.
                  '''
          }
          { bits: "${num_part+4}"
            name: "SCRAMBLING_FSM_ERROR"
            desc: '''
                  Set to 1 if the scrambling datapath FSM has reached an invalid state.
                  This raises an fatal_check_error alert and is an unrecoverable error condition.
                  '''
          }
          { bits: "${num_part+5}"
            name: "KEY_DERIV_FSM_ERROR"
            desc: '''
                  Set to 1 if the key derivation FSM has reached an invalid state.
                  This raises an fatal_check_error alert and is an unrecoverable error condition.
                  '''
          }
          { bits: "${num_part+6}"
            name: "BUS_INTEG_ERROR"
            desc: '''
                  This bit is set to 1 if a fatal bus integrity fault is detected.
                  This error triggers a fatal_bus_integ_error alert.
                  '''
          }
          { bits: "${num_part+7}"
            name: "DAI_IDLE"
            desc: "Set to 1 if the DAI is idle and ready to accept commands."
          }
          { bits: "${num_part+8}"
            name: "CHECK_PENDING"
            desc: "Set to 1 if an integrity or consistency check triggered by the LFSR timer or via !!CHECK_TRIGGER is pending."
          }
        ]
      }
      { multireg: {
          name:     "ERR_CODE",
          desc:     '''
                    This register holds information about error conditions that occurred in the agents
                    interacting with the OTP macro via the internal bus. The error codes should be checked
                    if the partitions, DAI or LCI flag an error in the !!STATUS register, or when an
                    !!INTR_STATE.otp_error has been triggered. Note that all errors trigger an otp_error
                    interrupt, and in addition some errors may trigger either an fatal_macro_error or an
                    fatal_check_error alert.
                    ''',
          count:     "NumErrorEntries",
          swaccess:  "ro",
          hwaccess:  "hwo",
          hwext:     "true",
          cname:     "AGENT",
          compact:   "false",
          resval:    0,
          tags: [ // OTP internal HW can modify the error code registers
                  "excl:CsrAllTests:CsrExclCheck"],
          fields: [
            {
              bits: "2:0"
              enum: [
                { value: "0",
                  name: "NO_ERROR",
                  desc: '''
                  No error condition has occurred.
                  '''
                },
                { value: "1",
                  name: "MACRO_ERROR",
                  desc: '''
                  Returned if the OTP macro command was invalid or did not complete successfully
                  due to a macro malfunction.
                  This error should never occur during normal operation and is not recoverable.
                  This error triggers an fatal_macro_error alert.
                  '''
                },
                { value: "2",
                  name: "MACRO_ECC_CORR_ERROR",
                  desc: '''
                  A correctable ECC error has occurred during an OTP read operation.
                  The corresponding controller automatically recovers from this error when
                  issuing a new command.
                  '''
                },
                { value: "3",
                  name: "MACRO_ECC_UNCORR_ERROR",
                  desc: '''
                  An uncorrectable ECC error has occurred during an OTP read operation.
                  This error should never occur during normal operation and is not recoverable.
                  If this error is present this may be a sign that the device is malfunctioning.
                  This error triggers an fatal_macro_error alert.
                  '''
                },
                { value: "4",
                  name: "MACRO_WRITE_BLANK_ERROR",
                  desc: '''
                  This error is returned if a programming operation attempted to clear a bit that has previously been programmed to 1.
                  The corresponding controller automatically recovers from this error when issuing a new command.

                  Note however that the affected OTP word may be left in an inconsistent state if this error occurs.
                  This can cause several issues when the word is accessed again (either as part of a regular read operation, as part of the readout at boot, or as part of a background check).

                  It is important that SW ensures that each word is only written once, since this can render the device useless.
                  '''
                },
                { value: "5",
                  name: "ACCESS_ERROR",
                  desc: '''
                  This error indicates that a locked memory region has been accessed.
                  The corresponding controller automatically recovers from this error when issuing a new command.
                  '''
                },
                { value: "6",
                  name: "CHECK_FAIL_ERROR",
                  desc: '''
                  An ECC, integrity or consistency mismatch has been detected in the buffer registers.
                  This error should never occur during normal operation and is not recoverable.
                  This error triggers an fatal_check_error alert.
                  '''
                },
                { value: "7",
                  name: "FSM_STATE_ERROR",
                  desc: '''
                  The FSM of the corresponding controller has reached an invalid state, or the FSM has
                  been moved into a terminal error state due to an escalation action via lc_escalate_en_i.
                  This error should never occur during normal operation and is not recoverable.
                  If this error is present, this is a sign that the device has fallen victim to
                  an invasive attack. This error triggers an fatal_check_error alert.
                  '''
                },
              ]
            }
          ]
        }
      }
      { name: "DIRECT_ACCESS_REGWEN",
        desc: '''
              Register write enable for all direct access interface registers.
              ''',
        swaccess: "rw0c",
        hwaccess: "hrw",
        hwext:    "true",
        hwqe:     "true",
        tags: [ // OTP internal HW will set this enable register to 0 when OTP is not under IDLE
                // state, so could not auto-predict its value
                "excl:CsrNonInitTests:CsrExclCheck"],
        fields: [
          {
              bits:   "0",
              desc: '''
              This bit controls whether the DAI registers can be written.
              Write 0 to it in order to clear the bit.

              Note that the hardware also modulates this bit and sets it to 0 temporarily
              during an OTP operation such that the corresponding address and data registers
              cannot be modified while an operation is pending. The !!DAI_IDLE status bit
              will also be set to 0 in such a case.
              '''
              resval: 1,
          },
        ]
      },
      { name: "DIRECT_ACCESS_CMD",
        desc: "Command register for direct accesses.",
        swaccess: "r0w1c",
        hwaccess: "hro",
        hwqe:     "true",
        hwext:    "true",
        resval:   0,
        regwen:   "DIRECT_ACCESS_REGWEN",
        tags: [ // Write to DIRECT_ACCESS_CMD randomly might cause OTP_ERRORs and illegal sequences
                "excl:CsrNonInitTests:CsrExclWrite"],
        fields: [
          { bits: "0",
            name: "RD",
            desc: '''
            Initiates a readout sequence that reads the location specified
            by !!DIRECT_ACCESS_ADDRESS. The command places the data read into
            !!DIRECT_ACCESS_RDATA_0 and !!DIRECT_ACCESS_RDATA_1 (for 64bit partitions).
            '''
          }
          { bits: "1",
            name: "WR",
            desc: '''
                  Initiates a programming sequence that writes the data in !!DIRECT_ACCESS_WDATA_0
                  and !!DIRECT_ACCESS_WDATA_1 (for 64bit partitions) to the location specified by
                  !!DIRECT_ACCESS_ADDRESS.
                  '''
          }
          { bits: "2",
            name: "DIGEST",
            desc: '''
                  Initiates the digest calculation and locking sequence for the partition specified by
                  !!DIRECT_ACCESS_ADDRESS.
                  '''
          }
        ]
      }
      { name: "DIRECT_ACCESS_ADDRESS",
        desc: "Address register for direct accesses.",
        swaccess: "rw",
        hwaccess: "hro",
        hwqe:     "false",
        resval:   0,
        regwen:   "DIRECT_ACCESS_REGWEN",
        tags: [ // The enable register "DIRECT_ACCESS_REGWEN" is HW controlled,
                // so not able to predict this register value automatically
                "excl:CsrNonInitTests:CsrExclCheck"],
        fields: [
          { bits: "OtpByteAddrWidth-1:0",
            desc: '''
                  This is the address for the OTP word to be read or written through
                  the direct access interface. Note that the address is aligned to the access size
                  internally, hence bits 1:0 are ignored for 32bit accesses, and bits 2:0 are ignored
                  for 64bit accesses.

                  For the digest calculation command, set this register to the partition base offset.
                  '''
          }
        ]
      }
      { multireg: {
          name:     "DIRECT_ACCESS_WDATA",
          desc:     '''Write data for direct accesses.
                    Hardware automatically determines the access granule (32bit or 64bit) based on which
                    partition is being written to.
                    ''',
          count:    "NumDaiWords", // 2 x 32bit = 64bit
          swaccess: "rw",
          hwaccess: "hro",
          hwqe:     "false",
          regwen:   "DIRECT_ACCESS_REGWEN",
          cname:    "WORD",
          resval:   0,
          tags: [ // The value of this register is written from "DIRECT_ACCESS_RDATA",
                  // so could not predict this register value automatically
                  "excl:CsrAllTests:CsrExclCheck"],
          fields: [
            { bits: "31:0"
            }
          ]
        }
      },
      { multireg: {
          name:     "DIRECT_ACCESS_RDATA",
          desc:     '''Read data for direct accesses.
                    Hardware automatically determines the access granule (32bit or 64bit) based on which
                    partition is read from.
                    ''',
          count:    "NumDaiWords", // 2 x 32bit = 64bit
          swaccess: "ro",
          hwaccess: "hwo",
          hwext:    "true",
          cname:    "WORD",
          resval:   0,
          fields: [
            { bits: "31:0"
            }
          ]
        }
      },

      //////////////////////////////////////
      // Integrity and Consistency Checks //
      //////////////////////////////////////
      { name: "CHECK_TRIGGER_REGWEN",
        desc: '''
              Register write enable for !!CHECK_TRIGGER.
              ''',
        swaccess: "rw0c",
        hwaccess: "none",
        fields: [
          { bits:   "0",
            desc: '''
            When cleared to 0, the !!CHECK_TRIGGER register cannot be written anymore.
            Write 0 to clear this bit.
            '''
            resval: 1,
          },
        ]
      },
      { name: "CHECK_TRIGGER",
        desc: "Command register for direct accesses.",
        swaccess: "r0w1c",
        hwaccess: "hro",
        hwqe:     "true",
        hwext:    "true",
        resval:   0,
        regwen:   "CHECK_TRIGGER_REGWEN",
        fields: [
          { bits: "0",
            name: "INTEGRITY",
            desc: '''
            Writing 1 to this bit triggers an integrity check. SW should monitor !!STATUS.CHECK_PENDING
            and wait until the check has been completed. If there are any errors, those will be flagged
            in the !!STATUS and !!ERR_CODE registers, and via the interrupts and alerts.
            '''
          }
          { bits: "1",
            name: "CONSISTENCY",
            desc: '''
            Writing 1 to this bit triggers a consistency check. SW should monitor !!STATUS.CHECK_PENDING
            and wait until the check has been completed. If there are any errors, those will be flagged
            in the !!STATUS and !!ERR_CODE registers, and via interrupts and alerts.
            '''
          }
        ]
      },
      { name: "CHECK_REGWEN",
        desc: '''
              Register write enable for !!INTEGRITY_CHECK_PERIOD and !!CONSISTENCY_CHECK_PERIOD.
              ''',
        swaccess: "rw0c",
        hwaccess: "none",
        fields: [
          { bits:   "0",
            desc: '''
            When cleared to 0, !!INTEGRITY_CHECK_PERIOD and !!CONSISTENCY_CHECK_PERIOD registers cannot be written anymore.
            Write 0 to clear this bit.
            '''
            resval: 1,
          },
        ]
      },
      { name: "CHECK_TIMEOUT",
        desc: '''
              Timeout value for the integrity and consistency checks.
              ''',
        swaccess: "rw",
        hwaccess: "hro",
        regwen:   "CHECK_REGWEN",
        tags: [ // Do not write to this automatically, as it may trigger fatal alert, and cause
                // escalation.
                "excl:CsrAllTests:CsrExclWrite"],
        fields: [
          { bits: "31:0",
            desc: '''
            Timeout value in cycles for the for the integrity and consistency checks. If an integrity or consistency
            check does not complete within the timeout window, an error will be flagged in the !!STATUS register,
            an otp_error interrupt will be raised, and an fatal_check_error alert will be sent out. The timeout should
            be set to a large value to stay on the safe side. The maximum check time can be upper bounded by the
            number of cycles it takes to readout, scramble and digest the entire OTP array. Since this amounts to
            roughly 25k cycles, it is recommended to set this value to at least 100'000 cycles in order to stay on the
            safe side. A value of zero disables the timeout mechanism (default).
            '''
            resval: 0,
          },
        ]
      },
      { name: "INTEGRITY_CHECK_PERIOD",
        desc: '''
              This value specifies the maximum period that can be generated pseudo-randomly.
              Only applies to the HW_CFG* and SECRET* partitions once they are locked.
              '''
        swaccess: "rw",
        hwaccess: "hro",
        regwen:   "CHECK_REGWEN",
        fields: [
          { bits: "31:0",
            desc: '''
            The pseudo-random period is generated using a 40bit LFSR internally, and this register defines
            the bit mask to be applied to the LFSR output in order to limit its range. The value of this
            register is left shifted by 8bits and the lower bits are set to 8'hFF in order to form the 40bit mask.
            A recommended value is 0x3_FFFF, corresponding to a maximum period of ~2.8s at 24MHz.
            A value of zero disables the timer (default). Note that a one-off check can always be triggered via
            !!CHECK_TRIGGER.INTEGRITY.
            '''
            resval: "0"
          }
        ]
      }
      { name: "CONSISTENCY_CHECK_PERIOD",
        desc: '''
              This value specifies the maximum period that can be generated pseudo-randomly.
              This applies to the LIFE_CYCLE partition and the HW_CFG* and SECRET* partitions once they are locked.
              '''
        swaccess: "rw",
        hwaccess: "hro",
        regwen:   "CHECK_REGWEN",
        fields: [
          { bits: "31:0",
            desc: '''
            The pseudo-random period is generated using a 40bit LFSR internally, and this register defines
            the bit mask to be applied to the LFSR output in order to limit its range. The value of this
            register is left shifted by 8bits and the lower bits are set to 8'hFF in order to form the 40bit mask.
            A recommended value is 0x3FF_FFFF, corresponding to a maximum period of ~716s at 24MHz.
            A value of zero disables the timer (default). Note that a one-off check can always be triggered via
            !!CHECK_TRIGGER.CONSISTENCY.
            '''
            resval: "0"
          }
        ]
      }

      ////////////////////////////////////
      // Dynamic Locks of SW Parititons //
      ////////////////////////////////////
  % for part in otp_mmap["partitions"]:
    % if part["read_lock"].lower() == "csr":
      { name: "${part["name"]}_READ_LOCK",
        desc: '''
              Runtime read lock for the ${part["name"]} partition.
              ''',
        swaccess: "rw0c",
        hwaccess: "hro",
        regwen:   "DIRECT_ACCESS_REGWEN",
        tags:     [ // The value of this register can affect the read access of the this
                    // partition's memory window. Excluding this register from writing can ensure
                    // memories have read and write access.
                    "excl:CsrNonInitTests:CsrExclWrite"],
        fields: [
          { bits:   "0",
            desc: '''
            When cleared to 0, read access to the ${part["name"]} partition is locked.
            Write 0 to clear this bit.
            '''
            resval: 1,
          },
        ]
      },
    % endif
  % endfor

      ///////////////////////
      // Integrity Digests //
      ///////////////////////
  % for part in otp_mmap["partitions"]:
    % if part["sw_digest"]:
      { multireg: {
          name:     "${part["name"]}_DIGEST",
          desc:     '''
                    Integrity digest for the ${part["name"]} partition.
                    The integrity digest is 0 by default. Software must write this
                    digest value via the direct access interface in order to lock the partition.
                    After a reset, write access to the ${part["name"]} partition is locked and
                    the digest becomes visible in this CSR.
                    ''',
          count:     "NumDigestWords",
          swaccess:  "ro",
          hwaccess:  "hwo",
          hwext:     "true",
          cname:     "WORD",
          resval:    0,
          tags: [ // OTP internal HW will update status so can not auto-predict its value.
                  "excl:CsrAllTests:CsrExclCheck"],
          fields: [
            { bits: "31:0"
            }
          ]
        }
      },
    % elif part["hw_digest"]:
      { multireg: {
          name:     "${part["name"]}_DIGEST",
          desc:     '''
                    Integrity digest for the ${part["name"]} partition.
                    The integrity digest is 0 by default. The digest calculation can be triggered via the !!DIRECT_ACCESS_CMD.
                    After a reset, the digest then becomes visible in this CSR, and the corresponding partition becomes write-locked.
                    ''',
          count:     "NumDigestWords",
          swaccess:  "ro",
          hwaccess:  "hwo",
          hwext:     "true",
          cname:     "WORD",
          resval:    0,
          tags: [ // OTP internal HW will update status so can not auto-predict its value.
                  "excl:CsrAllTests:CsrExclCheck"],
          fields: [
            { bits: "31:0"
            }
          ]
        }
      },
    % endif
  % endfor

      ////////////////////////////////
      // Software Config Partitions //
      ////////////////////////////////
      { skipto: "${hex(otp_size_as_bytes)}" }

      { window: {
          name: "SW_CFG_WINDOW"
          items: "NumSwCfgWindowWords"
          swaccess: "ro",
          desc: '''
          Any read to this window directly maps to the corresponding offset in the creator and owner software
          config partitions, and triggers an OTP readout of the bytes requested. Note that the transaction
          will block until OTP readout has completed.
          '''
        }
      }
    ],
  }
}
