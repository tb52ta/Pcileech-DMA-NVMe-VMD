// tb_usb_serial_top.sv (Revised for FT601 Interface)
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`timescale 1ns/1ps

module tb_usb_serial_top;

  // Parameters
  localparam SYS_CLK_PERIOD = 20; // 50MHz for ft601_clk_i
  localparam FT601_DATA_WIDTH = 32;
  localparam APP_DATA_WIDTH = 8;

  // DUT Interface Signals
  logic clk_sys; // Will be connected to DUT's ft601_clk_i
  logic rst_sys;

  // FT601 Interface Signals controlled by Testbench
  logic        tb_ft601_rxf_n; // To DUT ft601_rxf_n_i (0 = data available from host)
  logic        tb_ft601_txe_n; // To DUT ft601_txe_n_i (0 = host ready for data from FPGA)
  logic [3:0]  dut_ft601_be_o;
  logic        dut_ft601_oe_n_o;
  logic        dut_ft601_rd_n_o;
  logic        dut_ft601_wr_n_o;
  logic        dut_ft601_siwu_n_o;
  logic [FT601_DATA_WIDTH-1:0] ft601_data_io_bus; // For inout connection
  logic [FT601_DATA_WIDTH-1:0] tb_ft601_data_driver; // TB drives this when sending to FPGA
  wire  [FT601_DATA_WIDTH-1:0] dut_ft601_data_reader; // TB reads this when FPGA sends to host

  // Application side signals (to drive DUT's serial_port_application)
  logic [APP_DATA_WIDTH-1:0] tb_app_tx_byte_in;
  logic                      tb_app_tx_byte_valid;
  logic                      dut_app_tx_buffer_full; // Monitor

  // Protocol Channel IDs (consistent with ft601_protocol_adapter.sv)
  localparam CH_WIDTH = 4;
  localparam CH_POS   = FT601_DATA_WIDTH - CH_WIDTH;

  localparam CH_EP0_SETUP              = 4'h0;
  localparam CH_EP0_DATA_OUT_FROM_HOST = 4'h1;
  localparam CH_EP0_IN_STATUS_FROM_HOST= 4'h2;
  localparam CH_EP0_DATA_IN_TO_HOST    = 4'h8;
  localparam CH_EP0_STATUS_IN_TO_HOST  = 4'h9;
  localparam CH_BULK_OUT_FROM_HOST     = 4'hC;
  localparam CH_BULK_IN_TO_HOST        = 4'hD;

  // Instantiate DUT
  usb_serial_top #(
      .APP_DATA_WIDTH(APP_DATA_WIDTH) // Ensure parameters are passed if needed by top
  ) dut (
      .ft601_clk_i(clk_sys), // FT601 clock is the system clock
      .rst_sys(rst_sys),
      // FT601 Interface
      .ft601_rxf_n_i(tb_ft601_rxf_n),
      .ft601_txe_n_i(tb_ft601_txe_n),
      .ft601_be_o(dut_ft601_be_o),
      .ft601_oe_n_o(dut_ft601_oe_n_o),
      .ft601_rd_n_o(dut_ft601_rd_n_o),
      .ft601_wr_n_o(dut_ft601_wr_n_o),
      .ft601_siwu_n_o(dut_ft601_siwu_n_o),
      .ft601_data_io(ft601_data_io_bus)
  );

  // Handle ft601_data_io tristate
  assign ft601_data_io_bus    = dut.ft601_oe_n_o == 1'b0 ? dut.ft601_inst.ft601_data_io_fpga_out : 32'hZZZZZZZZ; // dut drives when oe_n is low
  assign dut_ft601_data_reader = dut.ft601_oe_n_o == 1'b0 ? dut.ft601_inst.ft601_data_io_fpga_out : 32'hxxxxxxxx; // Capture DUT output
  // When TB wants to drive, it will control tb_ft601_data_driver, and oe_n should be high.
  // The pcileech_ft601 module internally manages its output enable for ft601_data_io based on oe_n.
  // For TB sending data TO FPGA (simulating host write):
  // dut.ft601_oe_n_o should be HIGH (FPGA input mode for FT601_DATA)
  // TB will place data on tb_ft601_data_driver, and this gets assigned to ft601_data_io_bus via a separate assign if needed,
  // or more simply, when ft601_oe_n_o is high, ft601_data_io_bus is Z, so tb_ft601_data_driver can be directly assigned.
  // Let's use a simpler approach for TB driving:
  // The pcileech_ft601 module's ft601_data_io port is an inout.
  // When FPGA reads (ft601_rd_n_o low, ft601_oe_n_o low by pcileech_ft601), data flows from FT601 to FPGA.
  // TB simulates FT601: when rd_n is low and oe_n is low, TB should drive tb_ft601_data_driver.
  assign ft601_data_io_bus = (dut.ft601_oe_n_o == 1'b0) ? dut.ft601_inst.ft601_data_io_fpga_out : tb_ft601_data_driver;


  // Connect Application side signals for TX test
  assign dut.serial_port_application_inst.app_tx_byte_in    = tb_app_tx_byte_in;
  assign dut.serial_port_application_inst.app_tx_byte_valid = tb_app_tx_byte_valid;
  assign dut_app_tx_buffer_full                              = dut.serial_port_application_inst.app_tx_buffer_full;
  // RX app side not actively used in this TB revision, but keep connections if they exist on DUT
  // assign dut_app_rx_byte_out = dut.serial_port_application_inst.app_rx_byte_out;
  // assign dut_app_rx_byte_available = dut.serial_port_application_inst.app_rx_byte_available;
  // assign dut.serial_port_application_inst.app_rx_byte_read = tb_app_rx_byte_read;


  // Clock Generation
  initial clk_sys = 1'b0;
  always #(SYS_CLK_PERIOD/2) clk_sys = ~clk_sys;

  // Reset Task
  task apply_reset(input int duration_ns);
    $display("[%0t ns] Applying reset...", $time);
    rst_sys = 1'b1;
    tb_ft601_rxf_n = 1'b1; // No data from host
    tb_ft601_txe_n = 1'b1; // Host not ready for data
    tb_ft601_data_driver = 'z;
    tb_app_tx_byte_valid = 1'b0;
    #(duration_ns);
    rst_sys = 1'b0;
    $display("[%0t ns] Reset released.", $time);
    #(SYS_CLK_PERIOD * 10);
  endtask

  // Task: Host sends a 32-bit word to FPGA via FT601
  task host_send_word_to_fpga(input logic [31:0] data_word);
    @(posedge clk_sys);
    tb_ft601_data_driver = data_word;
    tb_ft601_rxf_n = 1'b0; // Indicate data is available for FPGA to read
    $display("[%0t ns] Host presenting word: 0x%h (rxf_n=0)", $time, data_word);

    // Wait for FPGA to assert RD_N (active low)
    wait (dut.ft601_rd_n_o == 1'b0);
    $display("[%0t ns] FPGA asserted RD_N.", $time);

    // Wait for RD_N to de-assert (FPGA finished read cycle)
    wait (dut.ft601_rd_n_o == 1'b1);
    $display("[%0t ns] FPGA de-asserted RD_N.", $time);

    tb_ft601_rxf_n = 1'b1; // Data consumed by FPGA
    tb_ft601_data_driver = 'z; // Stop driving
    @(posedge clk_sys); // Ensure rxf_n=1 is seen
  endtask

  // Task: Host receives a 32-bit word from FPGA via FT601
  task host_receive_word_from_fpga(output logic [31:0] data_word, input int timeout_cycles = 2000);
    int wait_cycles = 0;
    tb_ft601_txe_n = 1'b0; // Indicate host is ready to receive data
    $display("[%0t ns] Host ready to receive word (txe_n=0).", $time);

    // Wait for FPGA to assert WR_N (active low)
    // dut.ft601_oe_n_o should also be low when FPGA drives data
    while (dut.ft601_wr_n_o == 1'b1 && dut.ft601_oe_n_o == 1'b1 && wait_cycles < timeout_cycles) begin
        @(posedge clk_sys);
        wait_cycles++;
    end

    if (dut.ft601_wr_n_o == 1'b0 && dut.ft601_oe_n_o == 1'b0) begin
        data_word = ft601_data_io_bus; // Capture data driven by FPGA
        $display("[%0t ns] FPGA asserted WR_N. Host captured word: 0x%h", $time, data_word);
        // Wait for WR_N to de-assert
        wait (dut.ft601_wr_n_o == 1'b1);
        $display("[%0t ns] FPGA de-asserted WR_N.", $time);
    end else begin
        $error("[%0t ns] Timeout or OE_N not asserted while waiting for WR_N from FPGA. WR_N=%b, OE_N=%b", $time, dut.ft601_wr_n_o, dut.ft601_oe_n_o);
        data_word = 32'hDEADBEEF; // Indicate error
    end
    tb_ft601_txe_n = 1'b1; // Host no longer ready (or data received)
    @(posedge clk_sys);
  endtask

  // Task for EP0 SETUP phase (2 words for 8-byte setup packet)
  task ep0_setup_phase(input byte bmRequestType, input byte bRequest,
                       input shortint wValue, input shortint wIndex, input shortint wLength);
    logic [31:0] word1, word2;
    // Word 1: {bRequest, bmRequestType, wValue[15:8], wValue[7:0]} - order in FT601 word matters
    // Assuming protocol adapter expects bmRequestType, bRequest, wValue_low, wValue_high in first word
    // and wIndex_low, wIndex_high, wLength_low, wLength_high in second.
    // For simplicity, pack as per USB spec order: bmReq, bReq, wVal, wIdx, wLen
    // Adapter needs to unpack this from sequential FT601 words.
    // Word 1: {CH_EP0_SETUP, 16'd0, bRequest, bmRequestType} - if packing 2 setup bytes per word
    // Word 2: {CH_EP0_SETUP, wValue[15:0], wIndex[15:0]}
    // Word 3: {CH_EP0_SETUP, wLength[15:0]}
    // Simplified: Send 8 bytes of setup over two 32-bit FT601 words.
    // ft601_protocol_adapter will reassemble the 64-bit setup packet.
    // Word 0: {wValue[15:0], bRequest, bmRequestType}
    // Word 1: {wLength[15:0], wIndex[15:0]}
    word1 = {wValue, bRequest, bmRequestType};
    word2 = {wLength, wIndex};
    $display("[%0t ns] Sending EP0 SETUP: bmReq=0x%h,bReq=0x%h,wVal=0x%h,wIdx=0x%h,wLen=0x%h",
             $time, bmRequestType, bRequest, wValue, wIndex, wLength);
    host_send_word_to_fpga({CH_EP0_SETUP, word1[23:0]}); // Send first 4 bytes
    host_send_word_to_fpga({CH_EP0_SETUP, word2[23:0]}); // Send next 4 bytes
  endtask

  // Task for EP0 IN Data Phase (Host reads from FPGA)
  task ep0_in_data_phase(input int num_bytes_expected, ref logic [7:0] buffer[]);
    logic [31:0] data_word;
    int bytes_received = 0;
    if (num_bytes_expected > 0) buffer = new[num_bytes_expected]; else buffer = new[0];

    $display("[%0t ns] Host expecting %0d EP0 IN data bytes...", $time, num_bytes_expected);
    for (int i = 0; i < num_bytes_expected; i++) begin // Assuming one byte per FT601 word for EP0 IN data
        host_receive_word_from_fpga(data_word);
        if (data_word[CH_POS +: CH_WIDTH] == CH_EP0_DATA_IN_TO_HOST) begin
            buffer[bytes_received] = data_word[7:0];
            $display("[%0t ns] Host received EP0 IN byte %0d: 0x%h", $time, bytes_received, buffer[bytes_received]);
            bytes_received++;
            if (bytes_received == num_bytes_expected) break;
        end else {
            $error("[%0t ns] Expected CH_EP0_DATA_IN_TO_HOST, got channel 0x%h, data 0x%h", $time, data_word[CH_POS +: CH_WIDTH], data_word);
            break;
        }
    end
    if (bytes_received != num_bytes_expected) $warning("[%0t ns] EP0 IN: Expected %0d, received %0d", $time, num_bytes_expected, bytes_received);

    // After Device sends IN data, Host sends ZLP status (CH_EP0_DATA_OUT_FROM_HOST with zero payload implied by protocol)
    $display("[%0t ns] Host sending EP0 IN Data Phase Status ACK (ZLP OUT)", $time);
    host_send_word_to_fpga({CH_EP0_IN_STATUS_FROM_HOST, 28'd0}); // Signal ACK of IN data. Adapter should tell CDC.
  endtask

  // Task for EP0 Status Phase (Host expects ZLP IN from device, for Control Write)
  task ep0_status_phase_for_control_write();
    logic [31:0] data_word;
    $display("[%0t ns] Host expecting EP0 Status ZLP IN from device...", $time);
    host_receive_word_from_fpga(data_word);
    if (data_word[CH_POS+:CH_WIDTH] == CH_EP0_STATUS_IN_TO_HOST) begin // Or CH_EP0_DATA_IN with zero length marker
        $display("[%0t ns] Host received EP0 Status ZLP IN from device.", $time);
    end else {
        $error("[%0t ns] Expected CH_EP0_STATUS_IN_TO_HOST, got channel 0x%h, data 0x%h", $time, data_word[CH_POS+:CH_WIDTH], data_word);
    end
  endtask


  // Main Test Sequence
  initial begin
    apply_reset(50);
    $display("[%0t ns] Starting FT601-based USB Enumeration...", $time);
    logic [7:0] desc_buffer_bytes[];

    // 1. Get Device Descriptor
    ep0_setup_phase(8'h80, 6, 16'h0100, 16'h0000, 16'd18); // Get Device Descriptor (type 1, index 0), expect 18 bytes
    ep0_in_data_phase(18, desc_buffer_bytes);
    if (desc_buffer_bytes.size() == 18) $display("[%0t ns] Device Descriptor: %p", $time, desc_buffer_bytes);

    // 2. Set Address
    ep0_setup_phase(8'h00, 5, 16'd5, 16'h0000, 16'd0);    // SET_ADDRESS to 5
    ep0_status_phase_for_control_write(); // Host expects IN ZLP status from device
    $display("[%0t ns] Address set to 5.", $time);
    #(SYS_CLK_PERIOD * 200); // Allow time for address change processing by DUT

    // 3. Get Configuration Descriptor (full length)
    ep0_setup_phase(8'h80, 6, 16'h0200, 16'h0000, 16'd9); // Get Config Desc header (9 bytes)
    ep0_in_data_phase(9, desc_buffer_bytes);
    shortint wTotalLength = 75; // Default based on our descriptor
    if (desc_buffer_bytes.size() == 9) begin
        wTotalLength = {desc_buffer_bytes[3], desc_buffer_bytes[2]};
        $display("[%0t ns] Config Desc Header. wTotalLength = %0d", $time, wTotalLength);
        if (wTotalLength > 9 && wTotalLength < 256) begin // Sanity check
            ep0_setup_phase(8'h80, 6, 16'h0200, 16'h0000, wTotalLength); // Get Full Config
            ep0_in_data_phase(wTotalLength, desc_buffer_bytes);
            if(desc_buffer_bytes.size() == wTotalLength) $display("[%0t ns] Full Config Descriptor (%0d bytes) received.", $time, wTotalLength);
        end
    end else $error("Failed to read config descriptor header");

    // 4. Set Configuration
    ep0_setup_phase(8'h00, 9, 16'd1, 16'h0000, 16'd0);    // SET_CONFIGURATION to #1
    ep0_status_phase_for_control_write();
    $display("[%0t ns] Configuration set to #1.", $time);

    // Activate DTR for serial communication (SET_CONTROL_LINE_STATE)
    $display("[%0t ns] Setting Control Line State: DTR=1, RTS=0", $time);
    ep0_setup_phase(8'h21, 8'h22, 16'h0001, 16'h0000, 16'd0); // DTR=1, RTS=0
    ep0_status_phase_for_control_write();

    // Start host consumer for Bulk IN data
    fork
      begin
        logic [31:0] bulk_word;
        forever begin
          host_receive_word_from_fpga(bulk_word, 5000); // Increased timeout
          if (bulk_word[CH_POS +: CH_WIDTH] == CH_BULK_IN_TO_HOST) begin
            $display("[%0t ns] Host consumed Bulk IN data word: 0x%h (Byte: 0x%h)", $time, bulk_word, bulk_word[7:0]);
          end else if (bulk_word != 32'hDEADBEEF) { // Not a timeout
            $display("[%0t ns] Host received unexpected word on bulk path: 0x%h", $time, bulk_word);
          end
        end
      end
    join_none

    // Simulate Application Sending Data (TX Path Test)
    $display("[%0t ns] Starting TX Data Path Test...", $time);
    for (int j = 0; j < 5; j++) begin
      wait(!dut_app_tx_buffer_full);
      tb_app_tx_byte_in = 8'hB0 + j;
      tb_app_tx_byte_valid = 1'b1;
      @(posedge clk_sys);
      tb_app_tx_byte_valid = 1'b0;
      $display("[%0t ns] App sent byte: 0x%h to DUT.", $time, tb_app_tx_byte_in);
      #(SYS_CLK_PERIOD * 20);
    end

    $display("[%0t ns] Waiting for TX data to be processed...", $time);
    #(SYS_CLK_PERIOD * 10000);

    $display("[%0t ns] Testbench finished.", $time);
    $finish;
  end

endmodule : tb_usb_serial_top
