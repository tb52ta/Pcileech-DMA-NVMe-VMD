// cdc_acm_handler.sv
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`ifndef CDC_ACM_HANDLER_SV
`define CDC_ACM_HANDLER_SV

import usb_descriptors::*; // Import the package

module cdc_acm_handler (
    // Clock and Reset
    input logic clk,
    input logic rst,

    // EP0 Control Interface (Conceptual)
    input logic setup_packet_valid,         // Indicates a new setup packet is available
    input logic [63:0] setup_packet_data,   // bmRequestType, bRequest, wValue, wIndex, wLength
    output logic ep0_data_tx_valid,         // Asserted when data is driven on ep0_data_tx
    output logic [7:0] ep0_data_tx,         // Data byte to be transmitted on EP0
    output logic ep0_data_tx_last,          // Asserted with the last byte of EP0 data transfer
    input logic ep0_data_tx_ready,          // Host is ready to receive next EP0 data byte
    output logic ep0_stall,                 // Assert to stall EP0
    output logic ep0_ack                    // Assert to acknowledge setup packet or status stage
);

  // Setup Packet Fields (parsed from setup_packet_data)
  logic [7:0] bmRequestType;
  logic [7:0] bRequest;
  logic [15:0] wValue;
  logic [15:0] wIndex;
  logic [15:0] wLength;

  // Internal state for EP0 transfers
  typedef enum logic [2:0] { // Increased state bits
    IDLE,
    // SETUP_PHASE, // Implicitly handled when setup_packet_valid is high
    DATA_TX_PHASE,
    DATA_RX_PHASE, // For Host-to-Device data stages (e.g., SET_LINE_CODING)
    STATUS_PHASE
  } ep0_state_e;

  ep0_state_e current_ep0_state, next_ep0_state;

  // Descriptor handling
  byte selected_descriptor_data[];     // Holds the currently selected descriptor data
  logic [15:0] current_descriptor_len; // Total length of the selected descriptor
  logic [15:0] requested_len;          // wLength from setup packet (max bytes host wants)
  logic [15:0] bytes_to_send;          // Actual bytes to send: min(current_descriptor_len, requested_len)
  logic [15:0] bytes_sent_count;       // Counter for bytes sent in DATA_TX_PHASE
  logic [15:0] bytes_received_count;   // Counter for bytes received in DATA_RX_PHASE
  logic [15:0] current_data_ptr;       // Points to the current byte within selected_descriptor_data or rx_buffer

  // USB Device State
  logic [6:0] device_address;         // Current USB device address
  logic configured_state;             // True if device is in configured state

  // CDC-ACM Line Coding and Control Line State
  logic [31:0] line_coding_baudrate;
  logic [7:0]  line_coding_charformat; // 0: 1 Stop bit, 1: 1.5 Stop bits, 2: 2 Stop bits
  logic [7:0]  line_coding_paritytype; // 0: None, 1: Odd, 2: Even, 3: Mark, 4: Space
  logic [7:0]  line_coding_databits;   // 5, 6, 7, 8, or 16
  logic [7:0]  line_coding_buffer [0:6]; // 7-byte buffer for GET/SET_LINE_CODING. Use logic [7:0] to match byte type.

  logic        control_line_dtr;       // DTR signal state
  logic        control_line_rts;       // RTS signal state

  // Conceptual EP0 RX Data Interface (complementary to TX)
  // These would be actual inputs to the module if it were handling low-level SIE data.
  // input logic ep0_rx_data_available; // From SIE: a byte is ready on ep0_rx_data_byte
  // input logic [7:0] ep0_rx_data_byte;  // From SIE: the received data byte
  // output logic ep0_rx_ready_for_data; // To SIE: module is ready for next byte / has consumed current byte

  // Constants for Setup Packet parsing
  localparam REQUESTTYPE_DIR_DEVICE_TO_HOST = 8'h80; // Device-to-Host
  localparam REQUESTTYPE_DIR_HOST_TO_DEVICE = 8'h00; // Host-to-Device

  // Request Types (bmRequestType D6-5)
  localparam REQUESTTYPE_TYPE_STANDARD    = 2'b00; // 0
  localparam REQUESTTYPE_TYPE_CLASS       = 2'b01; // 1
  // localparam REQUESTTYPE_TYPE_VENDOR      = 2'b10; // 2

  // Request Recipients (bmRequestType D4-0)
  localparam REQUESTTYPE_RECIP_DEVICE     = 5'b00000; // 0
  localparam REQUESTTYPE_RECIP_INTERFACE  = 5'b00001; // 1
  // localparam REQUESTTYPE_RECIP_ENDPOINT   = 5'b00010; // 2

  // Standard Request Codes (bRequest)
  localparam REQ_GET_DESCRIPTOR    = 6;
  localparam REQ_SET_ADDRESS       = 5;
  localparam REQ_SET_CONFIGURATION = 9;

  // CDC-ACM Class-Specific Request Codes (bRequest)
  localparam REQ_SET_LINE_CODING        = 8'h20;
  localparam REQ_GET_LINE_CODING        = 8'h21;
  localparam REQ_SET_CONTROL_LINE_STATE = 8'h22;

  // bmRequestType values for CDC-ACM Class-Specific Requests
  // Host-to-Device, Class, Interface:
  // D7=0 (H2D), D6-5=01 (Class), D4-0=00001 (Interface) -> 00100001 = 8'h21
  localparam REQUESTTYPE_CLASS_INTERFACE_H2D = 8'h21;
  // Device-to-Host, Class, Interface:
  // D7=1 (D2H), D6-5=01 (Class), D4-0=00001 (Interface) -> 10100001 = 8'hA1
  localparam REQUESTTYPE_CLASS_INTERFACE_D2H = 8'hA1;

  localparam CDC_COMM_INTERFACE_IDX = 0; // Index of the Communication Class Interface

  localparam DESC_TYPE_DEVICE        = 1;
  localparam DESC_TYPE_CONFIGURATION = 2;
  localparam DESC_TYPE_STRING        = 3;

  // Parse Setup Packet
  always_comb begin
    bmRequestType = setup_packet_data[7:0];
    bRequest      = setup_packet_data[15:8];
    wValue        = setup_packet_data[31:16];
    wIndex        = setup_packet_data[47:32];
    wLength       = setup_packet_data[63:48];
  end

  // EP0 State Machine & Logic
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      current_ep0_state <= IDLE;
      ep0_stall <= 1'b0;
      ep0_ack <= 1'b0;
      ep0_data_tx_valid <= 1'b0;
      ep0_data_tx_last <= 1'b0;
      bytes_sent_count <= 16'd0;
      current_data_ptr <= 16'd0;
      requested_len <= 16'd0;
      bytes_to_send <= 16'd0;
      selected_descriptor_data = null; // Initialize dynamic array
      current_descriptor_len = 0;
      device_address = 7'd0;
      configured_state = 1'b0;
      // Initialize CDC-ACM state
      line_coding_baudrate <= 32'd9600;   // Default 9600 baud
      line_coding_charformat <= 8'd0;     // 0: 1 Stop bit (as per CDC spec Table 17)
      line_coding_paritytype <= 8'd0;     // 0: No Parity (as per CDC spec Table 18)
      line_coding_databits <= 8'd8;       // 8 Data bits (as per CDC spec Table 19)
      control_line_dtr <= 1'b0;           // DTR inactive
      control_line_rts <= 1'b0;           // RTS inactive
      bytes_received_count <= 16'd0;
      // Initialize line_coding_buffer to known values (optional, but good practice)
      for (int i = 0; i < 7; i++) begin
        line_coding_buffer[i] = 8'd0;
      end
    end else begin
      // Default outputs
      ep0_stall <= 1'b0;
      ep0_ack <= 1'b0;
      ep0_data_tx_valid <= 1'b0;
      ep0_data_tx_last <= 1'b0;

      current_ep0_state <= next_ep0_state; // Update state at the end of clock cycle based on next_ep0_state logic below

      case (current_ep0_state)
        IDLE: begin
          bytes_sent_count <= 16'd0;
          current_data_ptr <= 16'd0;
          selected_descriptor_data = null;
          current_descriptor_len = 0;
          bytes_received_count <= 16'd0; // Reset for any new transaction

          if (setup_packet_valid) begin
            // Parse bmRequestType fields for easier decision making
            logic req_is_device_to_host = bmRequestType[7];
            logic [1:0] req_type        = bmRequestType[6:5]; // Standard, Class, Vendor
            logic [4:0] req_recipient   = bmRequestType[4:0]; // Device, Interface, Endpoint, Other

            // Standard Device Requests
            if (req_type == REQUESTTYPE_TYPE_STANDARD && req_recipient == REQUESTTYPE_RECIP_DEVICE) begin
              if (req_is_device_to_host && bRequest == REQ_GET_DESCRIPTOR) begin
                logic [7:0] desc_type = wValue[15:8]; // High byte of wValue is Descriptor Type
              logic [7:0] desc_idx  = wValue[7:0];  // Low byte of wValue is Descriptor Index
              requested_len = wLength;
              logic found_descriptor = 1'b0;

              case (desc_type)
                DESC_TYPE_DEVICE: begin
                  selected_descriptor_data = device_descriptor;
                  current_descriptor_len = device_descriptor.size();
                  found_descriptor = 1'b1;
                end
                DESC_TYPE_CONFIGURATION: begin
                  if (desc_idx == 0) begin // Assuming only one configuration
                    selected_descriptor_data = configuration_descriptor;
                    // The wTotalLength is already correctly set in the descriptor definition itself.
                    current_descriptor_len = configuration_descriptor.size();
                    found_descriptor = 1'b1;
                  end
                end
                DESC_TYPE_STRING: begin
                  case (desc_idx)
                    LANG_ID_IDX: begin
                      selected_descriptor_data = string_descriptor_lang_id;
                      current_descriptor_len = string_descriptor_lang_id.size();
                      found_descriptor = 1'b1;
                    end
                    MANUFACTURER_IDX: begin
                      selected_descriptor_data = string_descriptor_manufacturer;
                      current_descriptor_len = string_descriptor_manufacturer.size();
                      found_descriptor = 1'b1;
                    end
                    PRODUCT_IDX: begin
                      selected_descriptor_data = string_descriptor_product;
                      current_descriptor_len = string_descriptor_product.size();
                      found_descriptor = 1'b1;
                    end
                    SERIAL_IDX: begin
                      selected_descriptor_data = string_descriptor_serial;
                      current_descriptor_len = string_descriptor_serial.size();
                      found_descriptor = 1'b1;
                    end
                    default: found_descriptor = 1'b0;
                  endcase
                end
                default: found_descriptor = 1'b0; // Unknown descriptor type
              endcase

              if (found_descriptor) begin
                ep0_ack <= 1'b1; // Acknowledge the SETUP packet
                bytes_to_send = (requested_len < current_descriptor_len) ? requested_len : current_descriptor_len;
                if (bytes_to_send > 0) begin
                  next_ep0_state <= DATA_TX_PHASE;
                end else begin // wLength == 0 or descriptor length is 0
                  // For GET_DESCRIPTOR with wLength == 0, ACK is sent, then status stage.
                  next_ep0_state <= STATUS_PHASE;
                end
              end else {
                ep0_stall <= 1'b1; // Stall for unsupported descriptor
                next_ep0_state <= IDLE;
              }
            // Handle SET_ADDRESS: Host-to-Device, Standard, Device
            // bmRequestType: D7=0 (H2D), D6-5=00 (Standard), D4-0=000 (Device) -> 8'h00
            end else if (bmRequestType == REQUESTTYPE_DIR_HOST_TO_DEVICE &&
                       (bmRequestType[6:5] == 2'b00) && // Standard request type
                       (bmRequestType[4:0] == 5'b000) && // Recipient Device
                       bRequest == REQ_SET_ADDRESS) begin
              // New address is in wValue[6:0]
              // The SIE typically handles applying the address after status stage.
              // For simulation, we can set it directly or use a pending_address.
              device_address <= wValue[6:0]; // Update immediately for simulation
              ep0_ack <= 1'b1;
              next_ep0_state <= STATUS_PHASE; // No data phase for SET_ADDRESS

            // Handle SET_CONFIGURATION: Host-to-Device, Standard, Device
            // bmRequestType: D7=0 (H2D), D6-5=00 (Standard), D4-0=000 (Device) -> 8'h00
            end else if (bmRequestType == REQUESTTYPE_DIR_HOST_TO_DEVICE &&
                       (bmRequestType[6:5] == 2'b00) && // Standard request type
                       (bmRequestType[4:0] == 5'b000) && // Recipient Device
                       bRequest == REQ_SET_CONFIGURATION) begin
              logic [7:0] config_val = wValue[7:0]; // Configuration value is in low byte of wValue
              if (config_val == 1 || config_val == 0) begin // Accept 1 (configured) or 0 (deconfigured)
                configured_state <= (config_val == 1);
                // In a real device, setting configuration would enable/disable endpoints
                // and interfaces. For now, just set the state.
                ep0_ack <= 1'b1;
                next_ep0_state <= STATUS_PHASE; // No data phase
              end else {
                ep0_stall <= 1'b1; // Invalid configuration value
                next_ep0_state <= IDLE;
              }
            end else { // Unhandled standard request to device, or other request types/recipients
              ep0_stall <= 1'b1;
              next_ep0_state <= IDLE;
            }
          end else {
            next_ep0_state <= IDLE; // No setup packet, remain IDLE
          }
        end

        DATA_TX_PHASE: begin
          if (bytes_sent_count < bytes_to_send) begin
            // If selected_descriptor_data is null, it's an error, should not happen if logic is correct.
            // However, real hardware might need a check.
            if (selected_descriptor_data == null) { // Should not occur
                ep0_stall <= 1'b1;
                next_ep0_state <= IDLE;
            } else if (ep0_data_tx_ready) begin
              ep0_data_tx_valid <= 1'b1;
              ep0_data_tx <= selected_descriptor_data[current_data_ptr];
              current_data_ptr <= current_data_ptr + 1;
              bytes_sent_count <= bytes_sent_count + 1;

              if (bytes_sent_count + 1 == bytes_to_send) begin
                ep0_data_tx_last <= 1'b1; // This is the last byte
                next_ep0_state <= STATUS_PHASE;
              end else {
                next_ep0_state <= DATA_TX_PHASE; // More data to send
              }
            end else {
              // Wait for host to be ready, remain in DATA_TX_PHASE
              ep0_data_tx_valid <= 1'b0; // Ensure valid is low if not sending
              next_ep0_state <= DATA_TX_PHASE;
            }
          end else { // All bytes_to_send have been sent
             // This case should ideally be caught by "bytes_sent_count + 1 == bytes_to_send"
             // but as a fallback, transition to status.
            ep0_data_tx_last <= 1'b1; // Ensure last is set if it wasn't
            next_ep0_state <= STATUS_PHASE;
          }
        end

        STATUS_PHASE: begin
          // For GET_DESCRIPTOR (IN Data to host), the status phase consists of the host sending
          // a Zero-Length Data Packet (ZLP) on the OUT endpoint (EP0 OUT).
          // The USB device (this module) should ACK this ZLP.
          // The ep0_ack for the SETUP packet was already sent.
          // Here, we are waiting for the host's ZLP. The actual SIE (Serial Interface Engine)
          // would detect this ZLP and signal it. For this conceptual model,
          // we assume the status phase is completed once we enter this state and transition to IDLE.
          // A more complete SIE would require handshaking here (e.g. `ep0_status_ack_sent_by_sie`).
          // For now, we just go to IDLE.
          // If this module were responsible for sending an IN ZLP (e.g. after a SET_ADDRESS),
          // it would be done here.
          next_ep0_state <= IDLE;
        end

        DATA_RX_PHASE: begin
          // This state is for receiving data from the host for EP0 OUT transfers (e.g., SET_LINE_CODING)
          // `requested_len` should be set by the IDLE state (e.g., 7 for SET_LINE_CODING)
          if (bytes_received_count < requested_len) begin
            // Conceptual data reception:
            // In a real SIE, we would check a signal like `ep0_rx_byte_available_from_sie`.
            // `ep0_data_tx_ready` is normally for TX. Here, we use it as a proxy for
            // "host is ready to send next byte / has sent byte".
            // The actual data byte would come from an SIE register `ep0_rx_data_from_sie[7:0]`.
            // This module would then assert `ep0_rx_consumed_byte_ack_to_sie`.

            // SIMPLIFICATION for this stage:
            // We assume the SIE handles byte-by-byte ACK and makes data available.
            // We will "receive" one byte per clock cycle if ep0_data_tx_ready is high,
            // and store a placeholder or assume line_coding_buffer is being filled externally for simulation.
            // The critical part is to count the bytes and then parse.

            if (ep0_data_tx_ready) begin // Simulate host sending one byte that we are "ready" for
              // ** Placeholder for actual data byte storage **
              // line_coding_buffer[bytes_received_count] <= simulated_rx_byte_from_host;
              // For this model, we can't read `ep0_data_tx` as it's an output.
              // We are just counting the bytes. The actual values in line_coding_buffer
              // would need to be driven by a testbench or a more detailed SIE model.
              bytes_received_count <= bytes_received_count + 1;

              if (bytes_received_count + 1 == requested_len) begin
                // All bytes "received". Now, parse them from line_coding_buffer.
                // This assumes line_coding_buffer has been filled by some mechanism.
                line_coding_baudrate <= {line_coding_buffer[3], line_coding_buffer[2], line_coding_buffer[1], line_coding_buffer[0]};
                line_coding_charformat <= line_coding_buffer[4];
                line_coding_paritytype <= line_coding_buffer[5];
                line_coding_databits <= line_coding_buffer[6];

                ep0_ack <= 1'b1; // Acknowledge the successful data reception and processing
                next_ep0_state <= STATUS_PHASE;
              end else {
                next_ep0_state <= DATA_RX_PHASE; // More bytes to "receive"
              }
            end else {
              // Waiting for host to be "ready" to send the next byte
              next_ep0_state <= DATA_RX_PHASE;
            }
          end else { // Should ideally be caught by the condition above, but as a fallback
            // This means all bytes are considered received.
            // Parsing should have happened when the last byte was received.
            // If somehow reached here, ensure ACK and move to status.
            // This state implies line_coding_buffer is now filled.
            line_coding_baudrate <= {line_coding_buffer[3], line_coding_buffer[2], line_coding_buffer[1], line_coding_buffer[0]};
            line_coding_charformat <= line_coding_buffer[4];
            line_coding_paritytype <= line_coding_buffer[5];
            line_coding_databits <= line_coding_buffer[6];
            ep0_ack <= 1'b1;
            next_ep0_state <= STATUS_PHASE;
          }
        end

        default: begin
          next_ep0_state <= IDLE;
        end
      endcase
    end
  end

endmodule : cdc_acm_handler

`endif // CDC_ACM_HANDLER_SV
