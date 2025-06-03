// tb_usb_serial_top.sv (Revised for FT601 Interface and Enhanced EP0/RX/TX/Interrupt Tests)
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`timescale 1ns/1ps

module tb_usb_serial_top;

  // Parameters
  localparam SYS_CLK_PERIOD = 20; // 50MHz for ft601_clk_i
  localparam FT601_DATA_WIDTH = 32;
  localparam APP_DATA_WIDTH = 8;
  localparam MAX_DMA_TRANSFER_LEN = 64;

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
  localparam CH_EP0_IN_STATUS_FROM_HOST= 4'h2;
  localparam CH_EP0_DATA_IN_TO_HOST    = 4'h8;
  localparam CH_EP0_STATUS_IN_TO_HOST  = 4'h9;
  localparam CH_INTR_IN_TO_HOST        = 4'h5; // Interrupt IN Channel
  localparam CH_BULK_OUT_FROM_HOST     = 4'hC;
  localparam CH_BULK_IN_TO_HOST        = 4'hD;

  // Instantiate DUT
  usb_serial_top #(
      .APP_DATA_WIDTH(APP_DATA_WIDTH),
      .MAX_DMA_TRANSFER_LEN(MAX_DMA_TRANSFER_LEN)
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
    wait (dut.ft601_rd_n_o == 1'b0);
    wait (dut.ft601_rd_n_o == 1'b1);
    tb_ft601_rxf_n = 1'b1;
    tb_ft601_data_driver = 'z;
    @(posedge clk_sys);
  endtask

  task host_receive_word_from_fpga(output logic [31:0] data_word, input int timeout_cycles = 2000);
    int wait_cycles = 0;
    tb_ft601_txe_n = 1'b0;
    while (dut.ft601_wr_n_o == 1'b1 && wait_cycles < timeout_cycles) begin
        if (dut.ft601_oe_n_o == 1'b0 && dut.ft601_wr_n_o == 1'b0) break;
        @(posedge clk_sys);
        wait_cycles++;
    end
    if (dut.ft601_wr_n_o == 1'b0 && dut.ft601_oe_n_o == 1'b0) begin
        data_word = ft601_data_io_bus;
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
    word1 = {wValue, bRequest, bmRequestType};
    word2 = {wLength, wIndex};
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
    logic [31:0] data_word; int bytes_received = 0;
    if (num_bytes_expected > 0) buffer = new[num_bytes_expected]; else buffer = new[0];
    $display("[%0t ns] Host RX <- FPGA: EP0 IN Data Phase (expecting %0d bytes)...", $time, num_bytes_expected);
    if (num_bytes_expected == 0) {
        host_receive_word_from_fpga(data_word, 500);
        if (data_word[CH_POS +: CH_WIDTH] == CH_EP0_DATA_IN_TO_HOST) {
            $display("[%0t ns] Host RX <- FPGA: Received EP0 IN ZLP from device.", $time);
        } else if (data_word != 32'hDEADBEEF) {
            $warning("[%0t ns] Host RX <- FPGA: Expected EP0 IN ZLP, got Ch:0x%h Data:0x%h", $time, data_word[CH_POS +: CH_WIDTH], data_word);
        }
    } else {
        for (int i = 0; i < num_bytes_expected; i++) begin
            host_receive_word_from_fpga(data_word);
            if (data_word[CH_POS +: CH_WIDTH] == CH_EP0_DATA_IN_TO_HOST) {
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

  task ep0_status_phase_for_control_write();
    logic [31:0] data_word;
    $display("[%0t ns] Host RX <- FPGA: Expecting EP0 Status ZLP IN from device...", $time);
    host_receive_word_from_fpga(data_word, 1000);
    if (data_word[CH_POS+:CH_WIDTH] == CH_EP0_STATUS_IN_TO_HOST) {
        $display("[%0t ns] Host RX <- FPGA: Received EP0 Status ZLP IN from device.", $time);
    } else if (data_word != 32'hDEADBEEF) {
        $error("[%0t ns] Host RX <- FPGA: Expected CH_EP0_STATUS_IN_TO_HOST, got Ch:0x%h Data:0x%h", $time, data_word[CH_POS+:CH_WIDTH], data_word);
    }
  endtask

  task host_consumes_and_verifies_serial_state_notification(input bit expected_dcd, input bit expected_dsr, input int comm_interface_idx = 0);
    logic [31:0] data_word;
    byte notification_buffer[10];
    int byte_count = 0;
    localparam NOTIFICATION_TIMEOUT = 5000; // Cycles

    $display("[%0t ns] Host: Expecting SERIAL_STATE notification (DCD=%b, DSR=%b)...", $time, expected_dcd, expected_dsr);

    for (int i = 0; i < 10; i++) begin // Expect 10 bytes for the notification
        host_receive_word_from_fpga(data_word, NOTIFICATION_TIMEOUT);
        if (data_word == 32'hDEADBEEF) begin
            $error("Timeout waiting for SERIAL_STATE notification byte %0d.", i);
            return;
        end
        if (data_word[CH_POS +: CH_WIDTH] != CH_INTR_IN_TO_HOST) begin
            $error("Expected CH_INTR_IN_TO_HOST (0x%h), got channel 0x%h for notification byte %0d. Full word: 0x%h",
                   CH_INTR_IN_TO_HOST, data_word[CH_POS +: CH_WIDTH], i, data_word);
            return;
        end
        notification_buffer[byte_count] = data_word[7:0];
        byte_count++;
    end

    if (byte_count == 10) begin
        // Verify header
        if (notification_buffer[0] != 8'hA1) $error("SERIAL_STATE: bmRequestType mismatch. Expected 0xA1, Got 0x%h", notification_buffer[0]);
        if (notification_buffer[1] != 8'h20) $error("SERIAL_STATE: bNotificationCode mismatch. Expected 0x20, Got 0x%h", notification_buffer[1]);
        if ({notification_buffer[3], notification_buffer[2]} != comm_interface_idx) $error("SERIAL_STATE: wValue (ifc) mismatch. Expected %0d, Got %0d", comm_interface_idx, {notification_buffer[3], notification_buffer[2]});
        // Note: Spec says wIndex for SERIAL_STATE is the Data Class Interface. cdc_acm_handler currently sets it to Comm Class Ifc.
        if ({notification_buffer[5], notification_buffer[4]} != comm_interface_idx) $error("SERIAL_STATE: wIndex (ifc) mismatch. Expected %0d, Got %0d", comm_interface_idx, {notification_buffer[5], notification_buffer[4]});
        if ({notification_buffer[7], notification_buffer[6]} != 16'd2) $error("SERIAL_STATE: wLength mismatch. Expected 2, Got %0d", {notification_buffer[7], notification_buffer[6]});

        // Verify payload (UART State Bitmap)
        logic dcd_received = notification_buffer[8][0];
        logic dsr_received = notification_buffer[8][1];
        if (dcd_received != expected_dcd) $error("SERIAL_STATE: DCD mismatch. Expected %b, Got %b", expected_dcd, dcd_received);
        if (dsr_received != expected_dsr) $error("SERIAL_STATE: DSR mismatch. Expected %b, Got %b", expected_dsr, dsr_received);
        if (notification_buffer[8][7:2] != 6'b0) $warning("SERIAL_STATE: Reserved bits in UART State Bitmap byte 0 not zero (0x%h).", notification_buffer[8][7:2]);
        if (notification_buffer[9] != 8'b0) $warning("SERIAL_STATE: UART State Bitmap byte 1 not zero (0x%h).", notification_buffer[9]);

        $display("[%0t ns] Host: SERIAL_STATE notification verified (DCD=%b, DSR=%b).", $time, dcd_received, dsr_received);
    end else {
        $error("SERIAL_STATE: Did not receive complete 10-byte notification. Received %0d bytes.", byte_count);
    }
  endtask


  initial begin
    apply_reset(50);
    $display("[%0t ns] Starting FT601-based USB Enumeration...", $time);
    logic [7:0] desc_buffer_bytes[];

    ep0_setup_phase(8'h80, 6, 16'h0100, 16'h0000, 16'd18);
    ep0_in_data_phase(18, desc_buffer_bytes);
    // if (desc_buffer_bytes.size() == 18) $display("[%0t ns] Device Descriptor: %p", $time, desc_buffer_bytes);

    ep0_setup_phase(8'h00, 5, 16'd5, 16'h0000, 16'd0);
    ep0_status_phase_for_control_write();
    $display("[%0t ns] Address set to 5.", $time);
    #(SYS_CLK_PERIOD * 200);

    ep0_setup_phase(8'h80, 6, 16'h0200, 16'h0000, 16'd9);
    ep0_in_data_phase(9, desc_buffer_bytes);
    shortint wTotalLength = 75;
    if (desc_buffer_bytes.size() == 9) begin
        wTotalLength = {desc_buffer_bytes[3], desc_buffer_bytes[2]};
        $display("[%0t ns] Config Desc Header. wTotalLength = %0d", $time, wTotalLength);
        if (wTotalLength > 9 && wTotalLength < 256) begin
            ep0_setup_phase(8'h80, 6, 16'h0200, 16'h0000, wTotalLength);
            ep0_in_data_phase(wTotalLength, desc_buffer_bytes);
            // if(desc_buffer_bytes.size() == wTotalLength) $display("[%0t ns] Full Config Descriptor (%0d bytes) received.", $time, wTotalLength);
        end
    end else $error("Failed to read config descriptor header");

    ep0_setup_phase(8'h00, 9, 16'd1, 16'h0000, 16'd0);
    ep0_status_phase_for_control_write();
    $display("[%0t ns] Configuration set to #1.", $time);
    // Expect initial SERIAL_STATE notification (DCD=0, DSR=1 because configured)
    host_consumes_and_verifies_serial_state_notification(/*expected_dcd*/1'b0, /*expected_dsr*/1'b1);


    $display("TB: --- Test SET_LINE_CODING ---");
    byte line_coding_payload[7];
    line_coding_payload[0] = 8'h80; line_coding_payload[1] = 8'h25; line_coding_payload[2] = 8'h00; line_coding_payload[3] = 8'h00;
    line_coding_payload[4] = 8'h00; line_coding_payload[5] = 8'h00; line_coding_payload[6] = 8'h08;
    ep0_setup_phase(8'h21, 8'h20, 16'h0000, 16'h0000, 7);
    ep0_out_data_phase(line_coding_payload, 7);
    ep0_status_phase_for_control_write();
    $display("TB: SET_LINE_CODING test complete.");

    $display("TB: Setting Control Line State: DTR=1, RTS=0");
    ep0_setup_phase(8'h21, 8'h22, 16'h0001, 16'h0000, 16'd0); // DTR=1, RTS=0
    ep0_status_phase_for_control_write();
    // Expect SERIAL_STATE notification (DCD=1, DSR=1)
    host_consumes_and_verifies_serial_state_notification(/*expected_dcd*/1'b1, /*expected_dsr*/1'b1);

    $display("TB: Setting Control Line State: DTR=0, RTS=0");
    ep0_setup_phase(8'h21, 8'h22, 16'h0000, 16'h0000, 16'd0); // DTR=0, RTS=0
    ep0_status_phase_for_control_write();
    // Expect SERIAL_STATE notification (DCD=0, DSR=1)
    host_consumes_and_verifies_serial_state_notification(/*expected_dcd*/1'b0, /*expected_dsr*/1'b1);


    fork
      begin : host_bulk_in_consumer
        logic [31:0] bulk_word; int bytes_consumed_count = 0;
        forever begin
          host_receive_word_from_fpga(bulk_word, 10000);
          if (bulk_word[CH_POS +: CH_WIDTH] == CH_BULK_IN_TO_HOST) bytes_consumed_count++;
          else if (bulk_word != 32'hDEADBEEF) $display("[%0t ns] Host RX Consumed unexpected word: 0x%h", $time, bulk_word);
          if (bytes_consumed_count >= 5) break;
        end
      end
    join_none
    $display("[%0t ns] Starting TX Data Path Test...", $time);
    for (int j = 0; j < 5; j++) begin
      wait(!dut_app_tx_buffer_full);
      tb_app_tx_byte_in = 8'hB0 + j; tb_app_tx_byte_valid = 1'b1;
      @(posedge clk_sys); tb_app_tx_byte_valid = 1'b0;
      #(SYS_CLK_PERIOD * 30);
    end
    #(SYS_CLK_PERIOD * 20000);
    disable host_bulk_in_consumer;

    // RX Data Path Tests
    byte test_data[];
    $display("TB: --- RX Test Case 1: Single Byte Transfer ---");
    test_data = new[1]; test_data[0] = 8'hA5;
    for (int i = 0; i < test_data.size(); i++) host_send_word_to_fpga({CH_BULK_OUT_FROM_HOST, 24'h0, test_data[i]});
    verify_rx_data(test_data, test_data.size());
    #(SYS_CLK_PERIOD * 100);

    $display("TB: --- RX Test Case 2: Full DMA Packet (%0d bytes) ---", MAX_DMA_TRANSFER_LEN);
    test_data = new[MAX_DMA_TRANSFER_LEN];
    for (int i = 0; i < MAX_DMA_TRANSFER_LEN; i++) test_data[i] = byte'(i);
    for (int i = 0; i < test_data.size(); i++) host_send_word_to_fpga({CH_BULK_OUT_FROM_HOST, 24'h0, test_data[i]});
    verify_rx_data(test_data, test_data.size());
    #(SYS_CLK_PERIOD * 100);

    localparam LARGER_SIZE = MAX_DMA_TRANSFER_LEN + 5;
    $display("TB: --- RX Test Case 3: Larger Than DMA Packet (%0d bytes) ---", LARGER_SIZE);
    test_data = new[LARGER_SIZE];
    for (int i = 0; i < LARGER_SIZE; i++) test_data[i] = byte'(i + 8'hF0);
    for (int i = 0; i < test_data.size(); i++) host_send_word_to_fpga({CH_BULK_OUT_FROM_HOST, 24'h0, test_data[i]});
    verify_rx_data(test_data, test_data.size());
    #(SYS_CLK_PERIOD * 100);

    $display("TB: --- RX Test Case 4: Back-to-Back Small Transfers ---");
    byte data_set1[] = {8'hC1, 8'hC2, 8'hC3};
    byte data_set2[] = {8'hD4, 8'hD5, 8'hD6, 8'hD7};
    byte combined_data[data_set1.size() + data_set2.size()];
    foreach(data_set1[i]) combined_data[i] = data_set1[i];
    foreach(data_set2[i]) combined_data[data_set1.size()+i] = data_set2[i];
    for (int i = 0; i < data_set1.size(); i++) host_send_word_to_fpga({CH_BULK_OUT_FROM_HOST, 24'h0, data_set1[i]});
    for (int i = 0; i < data_set2.size(); i++) host_send_word_to_fpga({CH_BULK_OUT_FROM_HOST, 24'h0, data_set2[i]});
    verify_rx_data(combined_data, combined_data.size());
    #(SYS_CLK_PERIOD * 100);

    $display("[%0t ns] All tests finished.", $time);
    $finish;
  end

endmodule : tb_usb_serial_top
