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

    // EP0 Control Interface
    input  logic setup_packet_valid,         // Indicates a new setup packet is available
    input  logic [63:0] setup_packet_data,   // bmRequestType, bRequest, wValue, wIndex, wLength
    output logic ep0_data_tx_valid,         // Asserted when data is driven on ep0_data_tx
    output logic [7:0] ep0_data_tx,         // Data byte to be transmitted on EP0
    output logic ep0_data_tx_last,          // Asserted with the last byte of EP0 data transfer
    input  logic ep0_data_tx_ready,          // Adapter is ready for next EP0 IN data byte

    // EP0 OUT Data Path (from Adapter, for Control Write data stages)
    input  logic ep0_data_rx_valid_from_adapter, // Adapter has valid EP0 OUT data byte
    input  logic [7:0] ep0_data_rx_from_adapter,   // EP0 OUT data byte from Adapter
    output logic ep0_data_rx_ready_from_cdc,   // CDC Handler is ready for next EP0 OUT data byte

    output logic ep0_stall,                 // Assert to stall EP0
    output logic ep0_ack,                   // Assert to acknowledge setup packet or successful data/status stage

    // Control Line State Outputs
    output logic dtr_active_o,
    output logic rts_active_o
);

  // Setup Packet Fields (parsed from setup_packet_data)
  logic [7:0] bmRequestType;
  logic [7:0] bRequest;
  logic [15:0] wValue;
  logic [15:0] wIndex;
  logic [15:0] wLength;

  // Internal state for EP0 transfers
  typedef enum logic [2:0] {
    IDLE,
    DATA_TX_PHASE,
    DATA_RX_PHASE,
    STATUS_PHASE
  } ep0_state_e;

  ep0_state_e current_ep0_state, next_ep0_state;

  // Descriptor handling
  byte selected_descriptor_data[];
  logic [15:0] current_descriptor_len;
  logic [15:0] requested_len;
  logic [15:0] bytes_to_send;
  logic [15:0] bytes_sent_count;
  logic [15:0] bytes_received_count;   // For EP0 OUT data
  logic [15:0] current_data_ptr;       // For TX
  logic [15:0] current_rx_data_ptr;    // For RX (into line_coding_buffer)

  // USB Device State
  logic [6:0] device_address;
  logic configured_state;

  // CDC-ACM Line Coding and Control Line State
  logic [31:0] line_coding_baudrate;
  logic [7:0]  line_coding_charformat;
  logic [7:0]  line_coding_paritytype;
  logic [7:0]  line_coding_databits;
  logic [7:0]  line_coding_buffer [0:6];

  logic        control_line_dtr;
  logic        control_line_rts;

  // Constants for Setup Packet parsing
  localparam REQUESTTYPE_DIR_DEVICE_TO_HOST = 8'h80;
  localparam REQUESTTYPE_DIR_HOST_TO_DEVICE = 8'h00;
  localparam REQUESTTYPE_TYPE_STANDARD    = 2'b00;
  localparam REQUESTTYPE_TYPE_CLASS       = 2'b01;
  localparam REQUESTTYPE_RECIP_DEVICE     = 5'b00000;
  localparam REQUESTTYPE_RECIP_INTERFACE  = 5'b00001;
  localparam REQ_GET_DESCRIPTOR    = 6;
  localparam REQ_SET_ADDRESS       = 5;
  localparam REQ_SET_CONFIGURATION = 9;
  localparam REQ_SET_LINE_CODING        = 8'h20;
  localparam REQ_GET_LINE_CODING        = 8'h21;
  localparam REQ_SET_CONTROL_LINE_STATE = 8'h22;
  localparam REQUESTTYPE_CLASS_INTERFACE_H2D = 8'h21; // H2D, Class, Interface
  localparam REQUESTTYPE_CLASS_INTERFACE_D2H = 8'hA1; // D2H, Class, Interface
  localparam CDC_COMM_INTERFACE_IDX = 0;
  localparam DESC_TYPE_DEVICE        = 1;
  localparam DESC_TYPE_CONFIGURATION = 2;
  localparam DESC_TYPE_STRING        = 3;

  // Parse Setup Packet
  always_comb begin
    // Assign control line outputs
    dtr_active_o = control_line_dtr;
    rts_active_o = control_line_rts;

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
      selected_descriptor_data = null;
      current_descriptor_len = 0;
      device_address = 7'd0;
      configured_state = 1'b0;
      line_coding_baudrate <= 32'd9600;
      line_coding_charformat <= 8'd0;
      line_coding_paritytype <= 8'd0;
      line_coding_databits <= 8'd8;
      control_line_dtr <= 1'b0;
      control_line_rts <= 1'b0;
      bytes_received_count <= 16'd0;
      current_rx_data_ptr <= 16'd0;
      ep0_data_rx_ready_from_cdc <= 1'b0;
      for (int i = 0; i < 7; i++) begin
        line_coding_buffer[i] = 8'd0;
      end
    end else begin
      // Default outputs
      ep0_data_rx_ready_from_cdc <= 1'b0;
      ep0_stall <= 1'b0;
      ep0_ack <= 1'b0;
      ep0_data_tx_valid <= 1'b0;
      ep0_data_tx_last <= 1'b0;

      current_ep0_state <= next_ep0_state;

      case (current_ep0_state)
        IDLE: begin
          bytes_sent_count <= 16'd0;
          current_data_ptr <= 16'd0;
          current_rx_data_ptr <= 16'd0;
          selected_descriptor_data = null;
          current_descriptor_len = 0;
          bytes_received_count <= 16'd0;

          if (setup_packet_valid) begin
            logic req_is_device_to_host = bmRequestType[7];
            logic [1:0] req_type        = bmRequestType[6:5];
            logic [4:0] req_recipient   = bmRequestType[4:0];

            if (req_type == REQUESTTYPE_TYPE_STANDARD && req_recipient == REQUESTTYPE_RECIP_DEVICE) begin
              if (req_is_device_to_host && bRequest == REQ_GET_DESCRIPTOR) begin
                logic [7:0] desc_type = wValue[15:8];
                logic [7:0] desc_idx  = wValue[7:0];
                requested_len = wLength;
                logic found_descriptor = 1'b0;
                case (desc_type)
                  DESC_TYPE_DEVICE: begin selected_descriptor_data = device_descriptor; current_descriptor_len = device_descriptor.size(); found_descriptor = 1'b1; end
                  DESC_TYPE_CONFIGURATION: if (desc_idx == 0) begin selected_descriptor_data = configuration_descriptor; current_descriptor_len = configuration_descriptor.size(); found_descriptor = 1'b1; end
                  DESC_TYPE_STRING: begin
                    case (desc_idx)
                      LANG_ID_IDX:      begin selected_descriptor_data = string_descriptor_lang_id; current_descriptor_len = string_descriptor_lang_id.size(); found_descriptor = 1'b1; end
                      MANUFACTURER_IDX: begin selected_descriptor_data = string_descriptor_manufacturer; current_descriptor_len = string_descriptor_manufacturer.size(); found_descriptor = 1'b1; end
                      PRODUCT_IDX:      begin selected_descriptor_data = string_descriptor_product; current_descriptor_len = string_descriptor_product.size(); found_descriptor = 1'b1; end
                      SERIAL_IDX:       begin selected_descriptor_data = string_descriptor_serial; current_descriptor_len = string_descriptor_serial.size(); found_descriptor = 1'b1; end
                      default: found_descriptor = 1'b0;
                    endcase
                  end
                  default: found_descriptor = 1'b0;
                endcase
                if (found_descriptor) begin
                  ep0_ack <= 1'b1;
                  bytes_to_send = (requested_len < current_descriptor_len) ? requested_len : current_descriptor_len;
                  if (bytes_to_send > 0) next_ep0_state <= DATA_TX_PHASE;
                  else next_ep0_state <= STATUS_PHASE;
                end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
              end else if (!req_is_device_to_host && bRequest == REQ_SET_ADDRESS) begin
                device_address <= wValue[6:0];
                ep0_ack <= 1'b1;
                next_ep0_state <= STATUS_PHASE;
              end else if (!req_is_device_to_host && bRequest == REQ_SET_CONFIGURATION) begin
                logic [7:0] config_val = wValue[7:0];
                if (config_val == 1 || config_val == 0) begin
                  configured_state <= (config_val == 1);
                  ep0_ack <= 1'b1;
                  next_ep0_state <= STATUS_PHASE;
                end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
              end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; } // Unhandled Standard Device Request
            end else if (req_type == REQUESTTYPE_TYPE_CLASS && req_recipient == REQUESTTYPE_RECIP_INTERFACE) begin
              if (wIndex[7:0] == CDC_COMM_INTERFACE_IDX) begin
                if (bmRequestType == REQUESTTYPE_CLASS_INTERFACE_H2D && bRequest == REQ_SET_LINE_CODING) begin
                  if (wLength == 7) begin
                    requested_len = 7;
                    bytes_received_count <= 16'd0;
                    current_rx_data_ptr <= 16'd0;
                    next_ep0_state <= DATA_RX_PHASE;
                  end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
                end else if (bmRequestType == REQUESTTYPE_CLASS_INTERFACE_D2H && bRequest == REQ_GET_LINE_CODING) begin
                  line_coding_buffer[0] = line_coding_baudrate[7:0];
                  line_coding_buffer[1] = line_coding_baudrate[15:8];
                  line_coding_buffer[2] = line_coding_baudrate[23:16];
                  line_coding_buffer[3] = line_coding_baudrate[31:24];
                  line_coding_buffer[4] = line_coding_charformat;
                  line_coding_buffer[5] = line_coding_paritytype;
                  line_coding_buffer[6] = line_coding_databits;
                  selected_descriptor_data = line_coding_buffer;
                  current_descriptor_len = 7;
                  bytes_to_send = (wLength < current_descriptor_len) ? wLength : current_descriptor_len;
                  ep0_ack <= 1'b1;
                  if (bytes_to_send > 0) next_ep0_state <= DATA_TX_PHASE;
                  else next_ep0_state <= STATUS_PHASE;
                end else if (bmRequestType == REQUESTTYPE_CLASS_INTERFACE_H2D && bRequest == REQ_SET_CONTROL_LINE_STATE) begin
                  if (wLength == 0) begin
                    control_line_dtr <= wValue[0];
                    control_line_rts <= wValue[1];
                    ep0_ack <= 1'b1;
                    next_ep0_state <= STATUS_PHASE;
                  end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
                end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; } // Unhandled Class Interface Request
              end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; } // Incorrect Interface
            end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; } // Unhandled request type/recipient
          end else { next_ep0_state <= IDLE; }
        end

        DATA_TX_PHASE: begin
          if (bytes_sent_count < bytes_to_send) begin
            if (selected_descriptor_data == null) { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
            else if (ep0_data_tx_ready) begin
              ep0_data_tx_valid <= 1'b1;
              ep0_data_tx <= selected_descriptor_data[current_data_ptr];
              current_data_ptr <= current_data_ptr + 1;
              bytes_sent_count <= bytes_sent_count + 1;
              if (bytes_sent_count + 1 == bytes_to_send) begin
                ep0_data_tx_last <= 1'b1;
                next_ep0_state <= STATUS_PHASE;
              end else { next_ep0_state <= DATA_TX_PHASE; }
            end else { next_ep0_state <= DATA_TX_PHASE; }
          end else { ep0_data_tx_last <= 1'b1; next_ep0_state <= STATUS_PHASE; }
        end

        STATUS_PHASE: begin
          ep0_ack <= 1'b1; // Signal completion of data/status phase to adapter
          next_ep0_state <= IDLE;
        end

        DATA_RX_PHASE: begin // For EP0 OUT data (e.g. SET_LINE_CODING)
          if (bytes_received_count < requested_len) begin
            ep0_data_rx_ready_from_cdc <= 1'b1; // Ready for a byte from adapter

            if (ep0_data_rx_valid_from_adapter) begin
              line_coding_buffer[current_rx_data_ptr] <= ep0_data_rx_from_adapter;
              current_rx_data_ptr <= current_rx_data_ptr + 1;
              bytes_received_count <= bytes_received_count + 1;

              if (bytes_received_count + 1 == requested_len) begin
                line_coding_baudrate <= {line_coding_buffer[3], line_coding_buffer[2], line_coding_buffer[1], line_coding_buffer[0]};
                line_coding_charformat <= line_coding_buffer[4];
                line_coding_paritytype <= line_coding_buffer[5];
                line_coding_databits <= line_coding_buffer[6];
                next_ep0_state <= STATUS_PHASE;
              end else {
                next_ep0_state <= DATA_RX_PHASE;
              }
            end else {
              next_ep0_state <= DATA_RX_PHASE; // Wait for adapter data
            }
          end else {
            next_ep0_state <= STATUS_PHASE; // All bytes received, move to status
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
