// tb_usb_serial_top.sv (Revised for FT601 Interface and Enhanced EP0/RX Tests)
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`timescale 1ns/1ps

module tb_usb_serial_top;

  // Parameters
  localparam SYS_CLK_PERIOD = 20; // 50MHz for ft601_clk_i
  localparam FT601_DATA_WIDTH = 32;
  localparam APP_DATA_WIDTH = 8;

  // DUT Interface Signals
  logic clk_sys;
  logic rst_sys;

  logic        tb_ft601_rxf_n;
  logic        tb_ft601_txe_n;
  logic [3:0]  dut_ft601_be_o;
  logic        dut_ft601_oe_n_o;
  logic        dut_ft601_rd_n_o;
  logic        dut_ft601_wr_n_o;
  logic        dut_ft601_siwu_n_o;
  logic [FT601_DATA_WIDTH-1:0] ft601_data_io_bus;
  logic [FT601_DATA_WIDTH-1:0] tb_ft601_data_driver;
  wire  [FT601_DATA_WIDTH-1:0] dut_ft601_data_reader;

  logic [APP_DATA_WIDTH-1:0] tb_app_tx_byte_in;
  logic                      tb_app_tx_byte_valid;
  logic                      dut_app_tx_buffer_full;

  // Protocol Channel IDs
  localparam CH_WIDTH = 4;
  localparam CH_POS   = FT601_DATA_WIDTH - CH_WIDTH;
  localparam CH_EP0_SETUP              = 4'h0;
  localparam CH_EP0_DATA_OUT_FROM_HOST = 4'h1;
  localparam CH_EP0_IN_STATUS_FROM_HOST= 4'h2; // Host ACKs IN data by sending this (ZLP or specific packet)
  localparam CH_EP0_DATA_IN_TO_HOST    = 4'h8;
  localparam CH_EP0_STATUS_IN_TO_HOST  = 4'h9; // Device sends IN ZLP for Control-Write status
  localparam CH_BULK_OUT_FROM_HOST     = 4'hC;
  localparam CH_BULK_IN_TO_HOST        = 4'hD;

  // Instantiate DUT
  usb_serial_top #(
      .APP_DATA_WIDTH(APP_DATA_WIDTH)
  ) dut (
      .ft601_clk_i(clk_sys),
      .rst_sys(rst_sys),
      .ft601_rxf_n_i(tb_ft601_rxf_n),
      .ft601_txe_n_i(tb_ft601_txe_n),
      .ft601_be_o(dut_ft601_be_o),
      .ft601_oe_n_o(dut_ft601_oe_n_o),
      .ft601_rd_n_o(dut_ft601_rd_n_o),
      .ft601_wr_n_o(dut_ft601_wr_n_o),
      .ft601_siwu_n_o(dut_ft601_siwu_n_o),
      .ft601_data_io(ft601_data_io_bus)
  );

  assign ft601_data_io_bus = (dut.ft601_oe_n_o == 1'b0) ? dut.ft601_inst.ft601_data_io_fpga_out : tb_ft601_data_driver;
  assign dut_ft601_data_reader = dut.ft601_oe_n_o == 1'b0 ? dut.ft601_inst.ft601_data_io_fpga_out : 32'hxxxxxxxx;

  assign dut.serial_port_application_inst.app_tx_byte_in    = tb_app_tx_byte_in;
  assign dut.serial_port_application_inst.app_tx_byte_valid = tb_app_tx_byte_valid;
  assign dut_app_tx_buffer_full                              = dut.serial_port_application_inst.app_tx_buffer_full;

  initial clk_sys = 1'b0;
  always #(SYS_CLK_PERIOD/2) clk_sys = ~clk_sys;

  task apply_reset(input int duration_ns);
    $display("[%0t ns] Applying reset...", $time);
    rst_sys = 1'b1;
    tb_ft601_rxf_n = 1'b1; tb_ft601_txe_n = 1'b1; tb_ft601_data_driver = 'z;
    tb_app_tx_byte_valid = 1'b0;
    #(duration_ns);
    rst_sys = 1'b0;
    $display("[%0t ns] Reset released.", $time);
    #(SYS_CLK_PERIOD * 10);
  endtask

  task host_send_word_to_fpga(input logic [31:0] data_word);
    @(posedge clk_sys);
    tb_ft601_data_driver = data_word;
    tb_ft601_rxf_n = 1'b0;
    $display("[%0t ns] Host TX -> FPGA: 0x%h (rxf_n=0)", $time, data_word);
    wait (dut.ft601_rd_n_o == 1'b0);
    wait (dut.ft601_rd_n_o == 1'b1);
    tb_ft601_rxf_n = 1'b1;
    tb_ft601_data_driver = 'z;
    @(posedge clk_sys);
  endtask

  task host_receive_word_from_fpga(output logic [31:0] data_word, input int timeout_cycles = 2000);
    int wait_cycles = 0;
    tb_ft601_txe_n = 1'b0;
    // $display("[%0t ns] Host RX <- FPGA: Ready (txe_n=0).", $time);
    while (dut.ft601_wr_n_o == 1'b1 && wait_cycles < timeout_cycles) begin // Wait for WR_N or OE_N to assert
        if (dut.ft601_oe_n_o == 1'b0 && dut.ft601_wr_n_o == 1'b0) break; // FPGA driving and writing
        @(posedge clk_sys);
        wait_cycles++;
    end

    if (dut.ft601_wr_n_o == 1'b0 && dut.ft601_oe_n_o == 1'b0) begin
        data_word = ft601_data_io_bus;
        $display("[%0t ns] Host RX <- FPGA: Capturing 0x%h (wr_n=0, oe_n=0)", $time, data_word);
        wait (dut.ft601_wr_n_o == 1'b1);
    } else {
        $error("[%0t ns] Host RX <- FPGA: Timeout/Error. WR_N=%b, OE_N=%b", $time, dut.ft601_wr_n_o, dut.ft601_oe_n_o);
        data_word = 32'hDEADBEEF;
    }
    tb_ft601_txe_n = 1'b1;
    @(posedge clk_sys);
  endtask

  task ep0_setup_phase(input byte bmRequestType, input byte bRequest,
                       input shortint wValue, input shortint wIndex, input shortint wLength);
    logic [31:0] word1, word2;
    word1 = {wValue, bRequest, bmRequestType}; // {16'b wValue, 8'b bRequest, 8'b bmRequestType}
    word2 = {wLength, wIndex};                 // {16'b wLength, 16'b wIndex}
    $display("[%0t ns] EP0 SETUP: bmReq=0x%h,bReq=0x%h,wVal=0x%h,wIdx=0x%h,wLen=0x%h",
             $time, bmRequestType, bRequest, wValue, wIndex, wLength);
    host_send_word_to_fpga({CH_EP0_SETUP, word1[23:0]});
    host_send_word_to_fpga({CH_EP0_SETUP, word2[23:0]});
  endtask

  task ep0_out_data_phase(input byte data_payload[], input int num_bytes);
    $display("[%0t ns] Host TX -> FPGA: EP0 OUT Data Phase (%0d bytes)...", $time, num_bytes);
    for (int i = 0; i < num_bytes; i++) begin
      host_send_word_to_fpga({CH_EP0_DATA_OUT_FROM_HOST, 24'h0, data_payload[i]});
      $display("[%0t ns] Host TX -> FPGA: EP0 OUT data byte %0d: 0x%h", $time, i, data_payload[i]);
    end
  endtask

  task ep0_in_data_phase(input int num_bytes_expected, ref logic [7:0] buffer[]);
    logic [31:0] data_word;
    int bytes_received = 0;
    if (num_bytes_expected > 0) buffer = new[num_bytes_expected]; else buffer = new[0];

    $display("[%0t ns] Host RX <- FPGA: EP0 IN Data Phase (expecting %0d bytes)...", $time, num_bytes_expected);
    if (num_bytes_expected == 0) { // Handle ZLP case for IN (if device needs to send one)
        // Wait for potential ZLP from device
        host_receive_word_from_fpga(data_word, 500); // Shorter timeout for ZLP
        if (data_word[CH_POS +: CH_WIDTH] == CH_EP0_DATA_IN_TO_HOST) { // Could also be CH_EP0_STATUS_IN_TO_HOST if defined for ZLP
             // Check if it's a ZLP (payload indicates zero length, or specific ZLP marker)
             // For now, assume any CH_EP0_DATA_IN here is the ZLP if num_bytes_expected is 0.
            $display("[%0t ns] Host RX <- FPGA: Received EP0 IN ZLP from device.", $time);
        } else if (data_word != 32'hDEADBEEF) {
            $warning("[%0t ns] Host RX <- FPGA: Expected EP0 IN ZLP, got Ch:0x%h Data:0x%h", $time, data_word[CH_POS +: CH_WIDTH], data_word);
        }
    } else {
        for (int i = 0; i < num_bytes_expected; i++) begin
            host_receive_word_from_fpga(data_word);
            if (data_word[CH_POS +: CH_WIDTH] == CH_EP0_DATA_IN_TO_HOST) begin
                buffer[bytes_received] = data_word[7:0];
                $display("[%0t ns] Host RX <- FPGA: EP0 IN data byte %0d: 0x%h", $time, bytes_received, buffer[bytes_received]);
                bytes_received++;
            } else {
                $error("[%0t ns] Host RX <- FPGA: Expected CH_EP0_DATA_IN_TO_HOST, got Ch:0x%h Data:0x%h", $time, data_word[CH_POS +: CH_WIDTH], data_word);
                break;
            }
        end
    }
    if (bytes_received != num_bytes_expected) $warning("[%0t ns] Host RX <- FPGA: EP0 IN Data: Expected %0d, received %0d", $time, num_bytes_expected, bytes_received);

    $display("[%0t ns] Host TX -> FPGA: Sending EP0 IN Data Phase Status ACK (CH_EP0_IN_STATUS_FROM_HOST)", $time);
    host_send_word_to_fpga({CH_EP0_IN_STATUS_FROM_HOST, 28'd0});
  endtask

  task ep0_status_phase_for_control_write(); // Host expects IN ZLP from device
    logic [31:0] data_word;
    $display("[%0t ns] Host RX <- FPGA: Expecting EP0 Status ZLP IN from device...", $time);
    host_receive_word_from_fpga(data_word, 1000); // Allow reasonable timeout
    if (data_word[CH_POS+:CH_WIDTH] == CH_EP0_STATUS_IN_TO_HOST) {
        $display("[%0t ns] Host RX <- FPGA: Received EP0 Status ZLP IN from device.", $time);
    } else if (data_word != 32'hDEADBEEF) {
        $error("[%0t ns] Host RX <- FPGA: Expected CH_EP0_STATUS_IN_TO_HOST, got Ch:0x%h Data:0x%h", $time, data_word[CH_POS+:CH_WIDTH], data_word);
    }
  endtask

  initial begin
    apply_reset(50);
    $display("[%0t ns] Starting FT601-based USB Enumeration...", $time);
    logic [7:0] desc_buffer_bytes[];

    // 1. Get Device Descriptor
    ep0_setup_phase(8'h80, 6, 16'h0100, 16'h0000, 16'd18);
    ep0_in_data_phase(18, desc_buffer_bytes);
    if (desc_buffer_bytes.size() == 18) $display("[%0t ns] Device Descriptor: %p", $time, desc_buffer_bytes);

    // 2. Set Address
    ep0_setup_phase(8'h00, 5, 16'd5, 16'h0000, 16'd0);
    ep0_status_phase_for_control_write();
    $display("[%0t ns] Address set to 5.", $time);
    #(SYS_CLK_PERIOD * 200);

    // 3. Get Configuration Descriptor
    ep0_setup_phase(8'h80, 6, 16'h0200, 16'h0000, 16'd9);
    ep0_in_data_phase(9, desc_buffer_bytes);
    shortint wTotalLength = 75;
    if (desc_buffer_bytes.size() == 9) begin
        wTotalLength = {desc_buffer_bytes[3], desc_buffer_bytes[2]};
        $display("[%0t ns] Config Desc Header. wTotalLength = %0d", $time, wTotalLength);
        if (wTotalLength > 9 && wTotalLength < 256) begin
            ep0_setup_phase(8'h80, 6, 16'h0200, 16'h0000, wTotalLength);
            ep0_in_data_phase(wTotalLength, desc_buffer_bytes);
            if(desc_buffer_bytes.size() == wTotalLength) $display("[%0t ns] Full Config Descriptor (%0d bytes) received.", $time, wTotalLength);
        end
    end else $error("Failed to read config descriptor header");

    // 4. Set Configuration
    ep0_setup_phase(8'h00, 9, 16'd1, 16'h0000, 16'd0);
    ep0_status_phase_for_control_write();
    $display("[%0t ns] Configuration set to #1.", $time);

    // 5. Test SET_LINE_CODING
    $display("TB: --- Test SET_LINE_CODING ---");
    byte line_coding_payload[7];
    line_coding_payload[0] = 8'h80; line_coding_payload[1] = 8'h25; line_coding_payload[2] = 8'h00; line_coding_payload[3] = 8'h00; // 9600
    line_coding_payload[4] = 8'h00; line_coding_payload[5] = 8'h00; line_coding_payload[6] = 8'h08; // 1 stop, no parity, 8 bits
    ep0_setup_phase(8'h21, 8'h20, 16'h0000, 16'h0000, 7); // SET_LINE_CODING
    ep0_out_data_phase(line_coding_payload, 7);
    ep0_status_phase_for_control_write();
    $display("TB: SET_LINE_CODING test complete.");

    // 6. Activate DTR (SET_CONTROL_LINE_STATE)
    $display("TB: Setting Control Line State: DTR=1, RTS=0");
    ep0_setup_phase(8'h21, 8'h22, 16'h0001, 16'h0000, 16'd0); // DTR=1, RTS=0
    ep0_status_phase_for_control_write();

    // Start host consumer for Bulk IN data
    fork
      begin : host_bulk_in_consumer
        logic [31:0] bulk_word;
        int bytes_consumed_count = 0;
        forever begin
          host_receive_word_from_fpga(bulk_word, 10000); // Long timeout for bulk data
          if (bulk_word[CH_POS +: CH_WIDTH] == CH_BULK_IN_TO_HOST) begin
            $display("[%0t ns] Host RX <- FPGA: Consumed Bulk IN data word: 0x%h (Byte: 0x%h)", $time, bulk_word, bulk_word[7:0]);
            bytes_consumed_count++;
          end else if (bulk_word != 32'hDEADBEEF) {
            $display("[%0t ns] Host RX <- FPGA: Expected CH_BULK_IN_TO_HOST, got Ch:0x%h Data:0x%h", $time, bulk_word[CH_POS +: CH_WIDTH], bulk_word);
          end
          if (bytes_consumed_count >= 5) break; // Stop after consuming a few bytes for this test
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
      #(SYS_CLK_PERIOD * 30);
    end

    $display("[%0t ns] Waiting for TX data to be processed...", $time);
    #(SYS_CLK_PERIOD * 20000);
    disable host_bulk_in_consumer; // Stop the consumer

    // Simulate RX Data Path Test
    $display("[%0t ns] Starting RX Data Path Test...", $time);
    byte rx_test_data[] = {8'hDE, 8'hAD, 8'hBE, 8'hEF, 8'hF0};
    for (int i = 0; i < rx_test_data.size(); i++) begin
        host_send_word_to_fpga({CH_BULK_OUT_FROM_HOST, 24'h0, rx_test_data[i]});
        $display("[%0t ns] Host TX -> FPGA: Sent RX test byte 0x%h", $time, rx_test_data[i]);
        #(SYS_CLK_PERIOD * 10);
    end

    $display("[%0t ns] Waiting for RX data to appear in app layer...", $time);
    #(SYS_CLK_PERIOD * 5000);

    logic [7:0] app_received_bytes[];
    app_received_bytes = new[rx_test_data.size()];
    int app_rx_count = 0;

    for (int i=0; i < rx_test_data.size() + 5 ; i++) begin // Try to read up to 5 bytes + margin
        if (dut.serial_port_application_inst.app_rx_byte_available) begin
            if (app_rx_count < rx_test_data.size()) begin
                app_received_bytes[app_rx_count] = dut.serial_port_application_inst.app_rx_byte_out;
                $display("[%0t ns] App Layer peeked RX byte: 0x%h", $time, app_received_bytes[app_rx_count]);
                dut.serial_port_application_inst.app_rx_byte_read = 1'b1; // Hierarchical drive
                @(posedge clk_sys);
                dut.serial_port_application_inst.app_rx_byte_read = 1'b0;
                app_rx_count++;
            end else break;
        end else if (app_rx_count >= rx_test_data.size()) begin
            break; // All expected bytes read
        end
        @(posedge clk_sys);
    end

    if (app_rx_count == rx_test_data.size()) begin
        for (int i=0; i<rx_test_data.size(); i++) begin
            if (app_received_bytes[i] != rx_test_data[i]) begin
                $error("RX Data Mismatch! Expected 0x%h, Got 0x%h at index %0d", rx_test_data[i], app_received_bytes[i], i);
            end
        end
        if (app_rx_count == rx_test_data.size()) $display("RX Data Test PASSED!");
    end else begin
        $error("RX Data Test FAILED: Did not receive all bytes. Expected %0d, Got %0d", rx_test_data.size(), app_rx_count);
    end

    #(SYS_CLK_PERIOD * 100);
    $display("[%0t ns] Testbench finished.", $time);
    $finish;
  end

endmodule : tb_usb_serial_top
