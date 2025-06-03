// tb_usb_serial_top.sv (Revised for FT601 Interface and Concurrent Tests)
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`timescale 1ns/1ps

module tb_usb_serial_top;

  // Parameters
  localparam SYS_CLK_PERIOD = 20; // 50MHz for ft601_clk_i
  localparam FT601_DATA_WIDTH = 32;
  localparam APP_DATA_WIDTH = 8;
  localparam MAX_DMA_TRANSFER_LEN = 64;

  localparam NUM_CONCURRENT_TX_BYTES = 1024;
  localparam NUM_CONCURRENT_RX_BYTES = 1024;
  localparam NUM_DTR_TOGGLES_CONCURRENT = 4; // Number of times DTR will be toggled in concurrent test

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

  // Protocol Channel IDs
  localparam CH_WIDTH = 4;
  localparam CH_POS   = FT601_DATA_WIDTH - CH_WIDTH;
  localparam CH_EP0_SETUP              = 4'h0;
  localparam CH_EP0_DATA_OUT_FROM_HOST = 4'h1;
  localparam CH_EP0_IN_STATUS_FROM_HOST= 4'h2;
  localparam CH_EP0_DATA_IN_TO_HOST    = 4'h8;
  localparam CH_EP0_STATUS_IN_TO_HOST  = 4'h9;
  localparam CH_INTR_IN_TO_HOST        = 4'h5;
  localparam CH_BULK_OUT_FROM_HOST     = 4'hC;
  localparam CH_BULK_IN_TO_HOST        = 4'hD;

  // Concurrent Test Data Arrays and Flags
  byte tx_concurrent_data[NUM_CONCURRENT_TX_BYTES];
  byte rx_concurrent_expected_data[NUM_CONCURRENT_RX_BYTES];

  logic tx_concurrent_test_passed;
  logic rx_concurrent_test_passed;
  logic intr_concurrent_test_passed;

  event tx_producer_done_event;
  event host_bulk_in_consumer_done_event;
  event host_bulk_out_producer_done_event; // If sending RX data in blocks from main thread
  event app_rx_verifier_done_event;
  event host_interrupt_consumer_done_event;


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

  initial clk_sys = 1'b0;
  always #(SYS_CLK_PERIOD/2) clk_sys = ~clk_sys;

  // --- Reusable Tasks (apply_reset, FT601 interaction, EP0 phases) ---
  // ... (These tasks: apply_reset, host_send_word_to_fpga, host_receive_word_from_fpga,
  //      ep0_setup_phase, ep0_out_data_phase, ep0_in_data_phase,
  //      ep0_status_phase_for_control_write, host_consumes_and_verifies_serial_state_notification
  //      are assumed to be defined as in the previous version of the testbench)
  // --- START COPIED TASKS (ensure these are present and correct) ---
  task apply_reset(input int duration_ns);
    $display("[%0t ns] Applying reset...", $time);
    rst_sys = 1'b1;
    tb_ft601_rxf_n = 1'b1; tb_ft601_txe_n = 1'b1; tb_ft601_data_driver = 'z;
    dut.serial_port_application_inst.app_tx_byte_valid <= 1'b0;
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
    end
  endtask

  task ep0_in_data_phase(input int num_bytes_expected, ref logic [7:0] buffer[]);
    logic [31:0] data_word; int bytes_received = 0;
    if (num_bytes_expected > 0) buffer = new[num_bytes_expected]; else buffer = new[0];
    if (num_bytes_expected == 0) {
        host_receive_word_from_fpga(data_word, 500);
        if (data_word[CH_POS +: CH_WIDTH] == CH_EP0_DATA_IN_TO_HOST) { }
        else if (data_word != 32'hDEADBEEF) {
            $warning("[%0t ns] Host RX <- FPGA: Expected EP0 IN ZLP, got Ch:0x%h Data:0x%h", $time, data_word[CH_POS +: CH_WIDTH], data_word);
        }
    } else {
        for (int i = 0; i < num_bytes_expected; i++) begin
            host_receive_word_from_fpga(data_word);
            if (data_word[CH_POS +: CH_WIDTH] == CH_EP0_DATA_IN_TO_HOST) {
                buffer[bytes_received] = data_word[7:0];
                bytes_received++;
            } else {
                $error("[%0t ns] Host RX <- FPGA: Expected CH_EP0_DATA_IN_TO_HOST, got Ch:0x%h Data:0x%h", $time, data_word[CH_POS +: CH_WIDTH], data_word);
                break;
            }
        end
    }
    if (bytes_received != num_bytes_expected) $warning("[%0t ns] Host RX <- FPGA: EP0 IN Data: Expected %0d, received %0d", $time, num_bytes_expected, bytes_received);
    host_send_word_to_fpga({CH_EP0_IN_STATUS_FROM_HOST, 28'd0});
  endtask

  task ep0_status_phase_for_control_write();
    logic [31:0] data_word;
    host_receive_word_from_fpga(data_word, 1000);
    if (data_word[CH_POS+:CH_WIDTH] == CH_EP0_STATUS_IN_TO_HOST) {
        $display("[%0t ns] Host RX <- FPGA: Received EP0 Status ZLP IN from device.", $time);
    } else if (data_word != 32'hDEADBEEF) {
        $error("[%0t ns] Host RX <- FPGA: Expected CH_EP0_STATUS_IN_TO_HOST, got Ch:0x%h Data:0x%h", $time, data_word[CH_POS+:CH_WIDTH], data_word);
    }
  endtask

  task host_consumes_and_verifies_serial_state_notification(input bit expected_dcd, input bit expected_dsr, input int comm_interface_idx = 0);
    logic [31:0] data_word; byte notification_buffer[10]; int byte_count = 0;
    localparam NOTIFICATION_TIMEOUT = 8000;
    $display("[%0t ns] Host: Expecting SERIAL_STATE (DCD=%b, DSR=%b)...", $time, expected_dcd, expected_dsr);
    for (int i = 0; i < 10; i++) begin
        host_receive_word_from_fpga(data_word, NOTIFICATION_TIMEOUT);
        if (data_word == 32'hDEADBEEF) { $error("Timeout waiting for SERIAL_STATE notification byte %0d.", i); return; end
        if (data_word[CH_POS+:CH_WIDTH] != CH_INTR_IN_TO_HOST) { $error("Expected CH_INTR_IN_TO_HOST (0x%h), got Ch:0x%h for notification byte %0d. Word: 0x%h", CH_INTR_IN_TO_HOST, data_word[CH_POS+:CH_WIDTH], i, data_word); return; }
        notification_buffer[byte_count] = data_word[7:0]; byte_count++;
    end
    if (byte_count == 10) {
        if (notification_buffer[0]!=8'hA1 || notification_buffer[1]!=8'h20 || {notification_buffer[3],notification_buffer[2]}!=comm_interface_idx || {notification_buffer[5],notification_buffer[4]}!=comm_interface_idx || {notification_buffer[7],notification_buffer[6]}!=16'd2)
            $error("SERIAL_STATE: Header mismatch. Got: %p", notification_buffer);
        logic dcd_rcv = notification_buffer[8][0]; logic dsr_rcv = notification_buffer[8][1];
        if (dcd_rcv!=expected_dcd || dsr_rcv!=expected_dsr) $error("SERIAL_STATE: Payload DCD/DSR mismatch. Exp DCD=%b, DSR=%b. Got DCD=%b, DSR=%b", expected_dcd, expected_dsr, dcd_rcv, dsr_rcv);
        else $display("[%0t ns] Host: SERIAL_STATE verified (DCD=%b, DSR=%b).", $time, dcd_rcv, dsr_rcv);
    end else $error("SERIAL_STATE: Did not receive complete 10-byte notification. Received %0d bytes.", byte_count);
  endtask
  // --- END COPIED TASKS ---

  // --- Tasks for Concurrent Stress Testing ---
  task app_tx_data_producer(input int num_bytes);
    $display("[%0t ns] App TX Producer: Starting to send %0d bytes.", $time, num_bytes);
    for (int i = 0; i < num_bytes; i++) begin
        wait (dut.serial_port_application_inst.app_tx_buffer_full == 1'b0);
        dut.serial_port_application_inst.app_tx_byte_in <= tx_concurrent_data[i];
        dut.serial_port_application_inst.app_tx_byte_valid <= 1'b1;
        @(posedge clk_sys);
        dut.serial_port_application_inst.app_tx_byte_valid <= 1'b0;
        // if ((i > 0) && (i % 256 == 0)) $display("App TX Producer: Sent %0d bytes", i);
    end
    $display("[%0t ns] App TX Producer: Finished sending %0d bytes.", $time, num_bytes);
    -> tx_producer_done_event;
  endtask

  task host_bulk_in_data_consumer(input int num_bytes_to_expect, output logic test_passed);
    logic [31:0] data_word; int received_byte_count = 0; logic mismatch = 1'b0;
    localparam CONSUMER_TIMEOUT = num_bytes_to_expect * 200 * SYS_CLK_PERIOD * 1ns; // Generous timeout
    time start_time = $time;
    test_passed = 1'b1; // Assume pass initially
    $display("[%0t ns] Host Bulk IN Consumer: Expecting %0d bytes.", $time, num_bytes_to_expect);

    while(received_byte_count < num_bytes_to_expect) begin
        if ($time - start_time > CONSUMER_TIMEOUT) { $error("Host Bulk IN Consumer: Overall Timeout."); test_passed = 1'b0; break; }
        host_receive_word_from_fpga(data_word, (SYS_CLK_PERIOD * MAX_DMA_TRANSFER_LEN * 10)); // Per-word timeout
        if (data_word == 32'hDEADBEEF) { $error("Host Bulk IN Consumer: Timeout receiving word."); test_passed = 1'b0; break; }

        if (data_word[CH_POS +: CH_WIDTH] == CH_BULK_IN_TO_HOST) begin
            logic [7:0] current_rx_byte = data_word[7:0];
            if (received_byte_count < num_bytes_to_expect) { // Should always be true due to while condition
                if (current_rx_byte != tx_concurrent_data[received_byte_count]) {
                    $error("Host Bulk IN Consumer: MISMATCH Idx %0d, Exp 0x%h, Got 0x%h", received_byte_count, tx_concurrent_data[received_byte_count], current_rx_byte);
                    mismatch = 1'b1; test_passed = 1'b0;
                }
                 // if ((received_byte_count > 0) && (received_byte_count % 256 == 0)) $display("Host Bulk IN Consumer: Verified %0d bytes", received_byte_count);
            }
            received_byte_count++;
        end else { $warning("Host Bulk IN Consumer: Received non-bulk word: 0x%h", data_word); }
    end
    if (received_byte_count == num_bytes_to_expect && !mismatch) $display("Host Bulk IN Consumer: PASSED. Received %0d bytes correctly.", received_byte_count);
    else if (!mismatch) { $error("Host Bulk IN Consumer: FAILED. Expected %0d, received %0d.", num_bytes_to_expect, received_byte_count); test_passed = 1'b0; }
    else { $error("Host Bulk IN Consumer: FAILED due to mismatch."); test_passed = 1'b0; }
    -> host_bulk_in_consumer_done_event;
  endtask

  task host_bulk_out_data_producer(input int num_bytes_to_send);
    $display("[%0t ns] Host Bulk OUT Producer: Sending %0d bytes.", $time, num_bytes_to_send);
    for (int i = 0; i < num_bytes_to_send; i++) begin
      host_send_word_to_fpga({CH_BULK_OUT_FROM_HOST, 24'h0, rx_concurrent_expected_data[i]});
      // if ((i > 0) && (i % 256 == 0)) $display("Host Bulk OUT Producer: Sent %0d bytes", i);
    end
    $display("[%0t ns] Host Bulk OUT Producer: Finished sending %0d bytes.", $time, num_bytes_to_send);
    // -> host_bulk_out_producer_done_event; // Event if this task runs fully independently
  endtask

  task app_rx_data_verifier(input int num_bytes_to_expect, output logic test_passed);
    logic [7:0] app_read_byte; int app_rx_count = 0; int wait_cycles_byte;
    localparam MAX_WAIT_APP_BYTE_TOTAL_CONCURRENT = (SYS_CLK_PERIOD * 2000 * num_bytes_to_expect) + 40000; // Generous overall timeout
    time start_time = $time;
    test_passed = 1'b1;
    $display("[%0t ns] App RX Verifier: Expecting %0d bytes.", $time, num_bytes_to_expect);
    if (num_bytes_to_expect == 0) { -> app_rx_verifier_done_event; return; }

    for (int i=0; i < num_bytes_to_expect; i++) begin
        wait_cycles_byte = 0;
        while (!dut.serial_port_application_inst.app_rx_byte_available && $time - start_time < MAX_WAIT_APP_BYTE_TOTAL_CONCURRENT) begin
            @(posedge clk_sys); wait_cycles_byte++;
            if(wait_cycles_byte > (MAX_DMA_TRANSFER_LEN * SYS_CLK_PERIOD * 10)) { // Per-byte timeout addition
                $error("App RX Verifier: Timeout waiting for app_rx_byte_available for byte %0d.", i);
                test_passed = 1'b0; break;
            }
        end
        if (!test_passed || ($time - start_time >= MAX_WAIT_APP_BYTE_TOTAL_CONCURRENT && !dut.serial_port_application_inst.app_rx_byte_available)) {
            $error("App RX Verifier: Overall timeout or error stopping verification early.");
            test_passed = 1'b0; break;
        }

        app_read_byte = dut.serial_port_application_inst.app_rx_byte_out;
        dut.serial_port_application_inst.app_rx_byte_read = 1'b1;
        @(posedge clk_sys);
        dut.serial_port_application_inst.app_rx_byte_read = 1'b0;
        if (app_read_byte != rx_concurrent_expected_data[app_rx_count]) {
            $error("App RX Verifier: MISMATCH! Index %0d: Expected 0x%h, Got 0x%h", app_rx_count, rx_concurrent_expected_data[app_rx_count], app_read_byte);
            test_passed = 1'b0;
        }
        app_rx_count++;
    end
    if (app_rx_count == num_bytes_to_expect && test_passed) $display("App RX Verifier: PASSED. Received %0d bytes correctly.", app_rx_count);
    else if (test_passed) { $error("App RX Verifier: FAILED. Expected %0d, Got %0d bytes.", num_bytes_to_expect, app_rx_count); test_passed = 1'b0; }
    else { $error("App RX Verifier: FAILED due to mismatch or timeout."); }
    -> app_rx_verifier_done_event;
  endtask

  task host_interrupt_consumer(input int num_interrupts_to_expect, output logic test_passed);
    bit current_dtr_state = 1'b1; // Starts with DTR=1 after initial DTR set
    bit current_dsr_state = 1'b1; // Starts with DSR=1 after configuration
    int intr_count = 0;
    test_passed = 1'b1;
    $display("[%0t ns] Host Interrupt Consumer: Expecting %0d DTR-driven interrupt notifications.", $time, num_interrupts_to_expect);

    for (int i=0; i < num_interrupts_to_expect; i++) begin
        // Determine expected DCD based on DTR toggle sequence, DSR should remain 1 (configured)
        // Initial state after first DTR set is DCD=1, DSR=1
        // First toggle makes DTR=0 -> DCD=0
        // Second toggle makes DTR=1 -> DCD=1
        bit expected_dcd_for_this_intr = ((i % 2) == 0) ? 1'b0 : 1'b1; // Assumes DTR starts high, then low, then high...
        if (i==0) expected_dcd_for_this_intr = 1'b0; // First toggle after DTR was high makes it low (DCD=0)

        host_consumes_and_verifies_serial_state_notification(expected_dcd_for_this_intr, current_dsr_state);
        // Check internal pass flag of that task if it had one, or rely on $errors
        intr_count++;
    end
    if (intr_count == num_interrupts_to_expect) $display("Host Interrupt Consumer: PASSED. Received %0d interrupts.", intr_count);
    else { $error("Host Interrupt Consumer: FAILED. Expected %0d, received %0d interrupts.", num_interrupts_to_expect, intr_count); test_passed = 1'b0; }
    -> host_interrupt_consumer_done_event;
  endtask


  // --- Main Test Sequence ---
  initial begin
    apply_reset(50);
    logic [7:0] desc_buffer_bytes[];
    // Initialize concurrent data arrays
    for (int i = 0; i < NUM_CONCURRENT_TX_BYTES; i++) tx_concurrent_data[i] = byte'(i % 250 + 1); // Avoid 0 for easier debug
    for (int i = 0; i < NUM_CONCURRENT_RX_BYTES; i++) rx_concurrent_expected_data[i] = byte'( (NUM_CONCURRENT_RX_BYTES-1-i) % 250 + 1);


    // --- Basic Enumeration & CDC Setup ---
    $display("TB: --- Performing USB Enumeration and Initial CDC Setup ---");
    ep0_setup_phase(8'h80, 6, 16'h0100, 16'h0000, 16'd18); ep0_in_data_phase(18, desc_buffer_bytes);
    ep0_setup_phase(8'h00, 5, 16'd5, 16'h0000, 16'd0); ep0_status_phase_for_control_write();
    #(SYS_CLK_PERIOD * 10); // Reduced delay, address change should be quick
    ep0_setup_phase(8'h80, 6, 16'h0200, 16'h0000, 16'd9); ep0_in_data_phase(9, desc_buffer_bytes);
    shortint wTotalLength = 75;
    if (desc_buffer_bytes.size() == 9) wTotalLength = {desc_buffer_bytes[3], desc_buffer_bytes[2]};
    if (wTotalLength > 9 && wTotalLength < 256) {
        ep0_setup_phase(8'h80, 6, 16'h0200, 16'h0000, wTotalLength); ep0_in_data_phase(wTotalLength, desc_buffer_bytes);
    }
    ep0_setup_phase(8'h00, 9, 16'd1, 16'h0000, 16'd0); ep0_status_phase_for_control_write();
    host_consumes_and_verifies_serial_state_notification(1'b0, 1'b1); // DCD=0, DSR=1 (initial)
    byte line_coding_payload[7];
    line_coding_payload = {8'h08, 8'h00, 8'h00, 8'h00, 8'h25, 8'h80};
    line_coding_payload[0]=8'h80; line_coding_payload[1]=8'h25; line_coding_payload[4]=0; line_coding_payload[5]=0; line_coding_payload[6]=8;
    ep0_setup_phase(8'h21, 8'h20, 16'h0000, 16'h0000, 7);
    ep0_out_data_phase(line_coding_payload, 7);
    ep0_status_phase_for_control_write();

    // Set DTR=1, RTS=0 for subsequent tests
    ep0_setup_phase(8'h21, 8'h22, 16'h0001, 16'h0000, 16'd0);
    ep0_status_phase_for_control_write();
    host_consumes_and_verifies_serial_state_notification(1'b1, 1'b1); // DCD=1, DSR=1

    // --- Concurrent TX, RX, and Interrupt Test ---
    $display("TB: --- Starting Concurrent TX, RX, and Interrupt Test ---");
    tx_concurrent_test_passed = 1'b0; // Default to fail
    rx_concurrent_test_passed = 1'b0;
    intr_concurrent_test_passed = 1'b0;
    bit current_dtr_for_intr_test = 1'b1; // DTR is currently high

    fork
        app_tx_data_producer(NUM_CONCURRENT_TX_BYTES);
        host_bulk_in_data_consumer(NUM_CONCURRENT_TX_BYTES, tx_concurrent_test_passed);
        app_rx_data_verifier(NUM_CONCURRENT_RX_BYTES, rx_concurrent_test_passed);
        host_interrupt_consumer(NUM_DTR_TOGGLES_CONCURRENT, intr_concurrent_test_passed);
    join_none

    // Main thread drives RX data and toggles DTR
    // Send RX data in blocks
    localparam RX_BLOCK_SIZE = NUM_CONCURRENT_RX_BYTES / NUM_DTR_TOGGLES > 0 ? NUM_CONCURRENT_RX_BYTES / NUM_DTR_TOGGLES : 1;
    for (int j = 0; j < NUM_DTR_TOGGLES_CONCURRENT; j++) begin
        // Send a block of RX data
        if (j * RX_BLOCK_SIZE < NUM_CONCURRENT_RX_BYTES) begin
            int start_idx = j * RX_BLOCK_SIZE;
            int end_idx = (j+1) * RX_BLOCK_SIZE - 1;
            if (end_idx >= NUM_CONCURRENT_RX_BYTES) end_idx = NUM_CONCURRENT_RX_BYTES - 1;
            if (start_idx <= end_idx) begin
                 $display("TB: Main thread sending RX data block %0d (%0d to %0d)", j, start_idx, end_idx);
                 for (int k = start_idx; k <= end_idx; k++) begin
                     host_send_word_to_fpga({CH_BULK_OUT_FROM_HOST, 24'h0, rx_concurrent_expected_data[k]});
                 end
            end
        end

        // Toggle DTR
        current_dtr_for_intr_test = ~current_dtr_for_intr_test;
        $display("TB: Main thread toggling DTR. New DTR state for interrupt consumer to expect (via DCD): %b", current_dtr_for_intr_test);
        ep0_setup_phase(8'h21, 8'h22, {15'b0, current_dtr_for_intr_test}, 16'h0000, 16'd0); // RTS is 0
        ep0_status_phase_for_control_write();
        #(SYS_CLK_PERIOD * 500); // Delay between DTR toggles / RX blocks
    end
    // Send any remaining RX data if NUM_CONCURRENT_RX_BYTES is not a multiple of RX_BLOCK_SIZE*NUM_DTR_TOGGLES
    if (NUM_DTR_TOGGLES_CONCURRENT * RX_BLOCK_SIZE < NUM_CONCURRENT_RX_BYTES) begin
        int sent_already = NUM_DTR_TOGGLES_CONCURRENT * RX_BLOCK_SIZE;
        $display("TB: Main thread sending remaining RX data (%0d to %0d)", sent_already, NUM_CONCURRENT_RX_BYTES-1);
        for (int k=sent_already; k < NUM_CONCURRENT_RX_BYTES; k++) begin
             host_send_word_to_fpga({CH_BULK_OUT_FROM_HOST, 24'h0, rx_concurrent_expected_data[k]});
        end
    end


    // Wait for all concurrent operations to complete
    $display("TB: Main thread waiting for concurrent tasks to complete...");
    wait(tx_producer_done_event.triggered);
    wait(host_bulk_in_consumer_done_event.triggered);
    wait(app_rx_verifier_done_event.triggered);
    wait(host_interrupt_consumer_done_event.triggered);

    $display("TB: All concurrent tasks reported completion.");
    if (tx_concurrent_test_passed && rx_concurrent_test_passed && intr_concurrent_test_passed) begin
        $display("TB: CONCURRENT STRESS TEST PASSED!");
    end else begin
        $error("TB: CONCURRENT STRESS TEST FAILED! TX: %s, RX: %s, INTR: %s",
            tx_concurrent_test_passed ? "PASS" : "FAIL",
            rx_concurrent_test_passed ? "PASS" : "FAIL",
            intr_concurrent_test_passed ? "PASS" : "FAIL");
    end

    #(SYS_CLK_PERIOD * 200);
    $display("[%0t ns] All tests finished.", $time);
    $finish;
  end

endmodule : tb_usb_serial_top
