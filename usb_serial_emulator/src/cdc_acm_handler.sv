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
    input  logic setup_packet_valid,
    input  logic [63:0] setup_packet_data,
    output logic ep0_data_tx_valid,
    output logic [7:0] ep0_data_tx,
    output logic ep0_data_tx_last,
    input  logic ep0_data_tx_ready,

    input  logic ep0_data_rx_valid_from_adapter,
    input  logic [7:0] ep0_data_rx_from_adapter,
    output logic ep0_data_rx_ready_from_cdc,
    input  logic ep0_in_ack_received_from_adapter,

    output logic ep0_stall,
    output logic ep0_ack,

    // Control Line State Outputs for external use
    output logic dtr_active_o,
    output logic rts_active_o,

    // Interrupt IN Endpoint Interface (to Adapter)
    output logic interrupt_data_valid_o,
    output logic [7:0] interrupt_data_o,
    output logic interrupt_data_last_o,
    input  logic interrupt_data_ready_i
);

  // Setup Packet Fields
  logic [7:0] bmRequestType;
  logic [7:0] bRequest;
  logic [15:0] wValue;
  logic [15:0] wIndex;
  logic [15:0] wLength;

  typedef enum logic [2:0] { IDLE, DATA_TX_PHASE, DATA_RX_PHASE, STATUS_PHASE } ep0_state_e;
  ep0_state_e current_ep0_state, next_ep0_state;

  byte selected_descriptor_data[];
  logic [15:0] current_descriptor_len;
  logic [15:0] requested_len;
  logic [15:0] bytes_to_send;
  logic [15:0] bytes_sent_count;
  logic [15:0] bytes_received_count;
  logic [15:0] current_data_ptr;
  logic [15:0] current_rx_data_ptr;
  logic is_control_read_transfer_reg;

  logic [6:0] device_address;
  logic configured_state;
  logic first_config_done_reg; // To trigger initial DSR notification

  logic [31:0] line_coding_baudrate;
  logic [7:0]  line_coding_charformat;
  logic [7:0]  line_coding_paritytype;
  logic [7:0]  line_coding_databits;
  logic [7:0]  line_coding_buffer [0:6];

  logic        control_line_dtr;
  logic        control_line_rts;

  // SERIAL_STATE Notification
  logic [7:0] serial_state_notification_buffer [0:9]; // 8 header + 2 payload
  logic serial_state_notification_pending;
  logic [3:0] serial_state_bytes_sent_count; // Max 10 bytes
  logic dtr_prev_reg;
  logic dsr_prev_reg; // Track DSR changes too (based on configured_state)


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
  localparam NOTIFICATION_SERIAL_STATE  = 8'h20; // bNotificationCode for SERIAL_STATE
  localparam REQUESTTYPE_CLASS_INTERFACE_D2H_NOTIFICATION = 8'hA1; // bmRequestType for notifications

  localparam REQUESTTYPE_CLASS_INTERFACE_H2D = 8'h21;
  localparam REQUESTTYPE_CLASS_INTERFACE_D2H = 8'hA1;
  localparam CDC_COMM_INTERFACE_IDX = 0;
  localparam DESC_TYPE_DEVICE        = 1;
  localparam DESC_TYPE_CONFIGURATION = 2;
  localparam DESC_TYPE_STRING        = 3;

  assign dtr_active_o = control_line_dtr;
  assign rts_active_o = control_line_rts;

  always_comb begin
    bmRequestType = setup_packet_data[7:0];
    bRequest      = setup_packet_data[15:8];
    wValue        = setup_packet_data[31:16];
    wIndex        = setup_packet_data[47:32];
    wLength       = setup_packet_data[63:48];
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      current_ep0_state <= IDLE;
      ep0_stall <= 1'b0; ep0_ack <= 1'b0;
      ep0_data_tx_valid <= 1'b0; ep0_data_tx_last <= 1'b0;
      bytes_sent_count <= 0; current_data_ptr <= 0;
      requested_len <= 0; bytes_to_send <= 0;
      selected_descriptor_data = null; current_descriptor_len = 0;
      device_address <= 0; configured_state <= 1'b0; first_config_done_reg <= 1'b0;
      line_coding_baudrate <= 32'd9600; line_coding_charformat <= 0;
      line_coding_paritytype <= 0; line_coding_databits <= 8;
      control_line_dtr <= 1'b0; control_line_rts <= 1'b0;
      bytes_received_count <= 0; current_rx_data_ptr <= 0;
      ep0_data_rx_ready_from_cdc <= 1'b0;
      is_control_read_transfer_reg <= 1'b0;
      serial_state_notification_pending <= 1'b0;
      serial_state_bytes_sent_count <= 0;
      dtr_prev_reg <= 1'b0; dsr_prev_reg <= 1'b0;
      for (int i = 0; i < 7; i++) line_coding_buffer[i] = 0;
      for (int i = 0; i < 10; i++) serial_state_notification_buffer[i] = 0;
    end else begin
      ep0_data_rx_ready_from_cdc <= 1'b0;
      ep0_stall <= 1'b0; ep0_ack <= 1'b0;
      ep0_data_tx_valid <= 1'b0; ep0_data_tx_last <= 1'b0;
      interrupt_data_valid_o <= 1'b0; interrupt_data_last_o <= 1'b0;


      // DTR/DSR change detection for SERIAL_STATE notification
      dtr_prev_reg <= control_line_dtr;
      dsr_prev_reg <= configured_state; // Using configured_state as DSR indication

      if (!serial_state_notification_pending) begin // Only prepare if not already sending
        // Trigger on DTR change OR DSR change (initial DSR set after first configuration)
        if ( (control_line_dtr != dtr_prev_reg) ||
             (configured_state != dsr_prev_reg) ||
             (configured_state && !first_config_done_reg) // Trigger once when first configured
           ) begin
          if (configured_state || control_line_dtr) begin // Send only if DTR or DSR is active or just changed
            serial_state_notification_pending <= 1'b1;
            serial_state_bytes_sent_count <= 0;
            serial_state_notification_buffer[0] = REQUESTTYPE_CLASS_INTERFACE_D2H_NOTIFICATION; // bmRequestType
            serial_state_notification_buffer[1] = NOTIFICATION_SERIAL_STATE;    // bNotificationCode
            serial_state_notification_buffer[2] = 8'd0; // wValue LSB (Interface Index)
            serial_state_notification_buffer[3] = 8'd0; // wValue MSB
            serial_state_notification_buffer[4] = CDC_COMM_INTERFACE_IDX; // wIndex LSB (Interface)
            serial_state_notification_buffer[5] = 8'd0; // wIndex MSB
            serial_state_notification_buffer[6] = 8'd2; // wLength LSB (2 bytes payload)
            serial_state_notification_buffer[7] = 8'd0; // wLength MSB
            // UART State Bitmap (Payload)
            // Byte 0: bRxCarrier (DCD), bTxCarrier (DSR)
            serial_state_notification_buffer[8] = (configured_state << 1) | control_line_dtr;
            // Byte 1: bBreak, bRinging, bFraming, bParity, bOverRun
            serial_state_notification_buffer[9] = 8'd0; // No errors/states for now

            if (configured_state && !first_config_done_reg) begin
                first_config_done_reg <= 1'b1;
            end
          end
        end
      end

      // Sending logic for SERIAL_STATE notification
      if (serial_state_notification_pending && serial_state_bytes_sent_count < 10) begin
        interrupt_data_valid_o <= 1'b1;
        interrupt_data_o <= serial_state_notification_buffer[serial_state_bytes_sent_count];
        if (serial_state_bytes_sent_count == 9) begin
          interrupt_data_last_o <= 1'b1;
        end
        if (interrupt_data_ready_i) begin // Adapter is ready for a byte
          serial_state_bytes_sent_count <= serial_state_bytes_sent_count + 1;
          if (serial_state_bytes_sent_count + 1 == 10) begin // After current byte is sent, this was the last
            serial_state_notification_pending <= 1'b0; // Clear pending after last byte is taken
          end
        end
      end

      current_ep0_state <= next_ep0_state;
      // ... (rest of FSM from previous correct version)
      case (current_ep0_state)
        IDLE: begin
          bytes_sent_count <= 0; current_data_ptr <= 0; current_rx_data_ptr <= 0;
          selected_descriptor_data = null; current_descriptor_len = 0;
          bytes_received_count <= 0;
          is_control_read_transfer_reg <= 1'b0;

          if (setup_packet_valid) begin
            logic req_is_device_to_host = bmRequestType[7];
            logic [1:0] req_type        = bmRequestType[6:5];
            logic [4:0] req_recipient   = bmRequestType[4:0];

            if (req_type == REQUESTTYPE_TYPE_STANDARD && req_recipient == REQUESTTYPE_RECIP_DEVICE) begin
              is_control_read_transfer_reg <= req_is_device_to_host;
              if (req_is_device_to_host && bRequest == REQ_GET_DESCRIPTOR) begin
                logic [7:0] desc_type = wValue[15:8]; logic [7:0] desc_idx  = wValue[7:0];
                requested_len = wLength; logic found_descriptor = 1'b0;
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
                device_address <= wValue[6:0]; ep0_ack <= 1'b1; next_ep0_state <= STATUS_PHASE;
              end else if (!req_is_device_to_host && bRequest == REQ_SET_CONFIGURATION) begin
                logic [7:0] config_val = wValue[7:0];
                if (config_val == 1 || config_val == 0) begin
                  configured_state <= (config_val == 1);
                  if (config_val == 0) first_config_done_reg <= 1'b0; // Reset if deconfigured
                  ep0_ack <= 1'b1; next_ep0_state <= STATUS_PHASE;
                end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
              end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
            end else if (req_type == REQUESTTYPE_TYPE_CLASS && req_recipient == REQUESTTYPE_RECIP_INTERFACE) begin
              is_control_read_transfer_reg <= req_is_device_to_host;
              if (wIndex[7:0] == CDC_COMM_INTERFACE_IDX) begin
                if (bmRequestType == REQUESTTYPE_CLASS_INTERFACE_H2D && bRequest == REQ_SET_LINE_CODING) begin
                  if (wLength == 7) begin
                    requested_len = 7; bytes_received_count <= 0; current_rx_data_ptr <= 0;
                    next_ep0_state <= DATA_RX_PHASE;
                  end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
                end else if (bmRequestType == REQUESTTYPE_CLASS_INTERFACE_D2H && bRequest == REQ_GET_LINE_CODING) begin
                  line_coding_buffer[0] = line_coding_baudrate[7:0]; line_coding_buffer[1] = line_coding_baudrate[15:8];
                  line_coding_buffer[2] = line_coding_baudrate[23:16]; line_coding_buffer[3] = line_coding_baudrate[31:24];
                  line_coding_buffer[4] = line_coding_charformat; line_coding_buffer[5] = line_coding_paritytype;
                  line_coding_buffer[6] = line_coding_databits;
                  selected_descriptor_data = line_coding_buffer; current_descriptor_len = 7;
                  bytes_to_send = (wLength < current_descriptor_len) ? wLength : current_descriptor_len;
                  ep0_ack <= 1'b1;
                  if (bytes_to_send > 0) next_ep0_state <= DATA_TX_PHASE;
                  else next_ep0_state <= STATUS_PHASE;
                end else if (bmRequestType == REQUESTTYPE_CLASS_INTERFACE_H2D && bRequest == REQ_SET_CONTROL_LINE_STATE) begin
                  if (wLength == 0) begin
                    control_line_dtr <= wValue[0]; control_line_rts <= wValue[1];
                    ep0_ack <= 1'b1; next_ep0_state <= STATUS_PHASE;
                  end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
                end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
              end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
            end else { ep0_stall <= 1'b1; next_ep0_state <= IDLE; }
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
              if (bytes_sent_count + 1 == bytes_to_send) {
                ep0_data_tx_last <= 1'b1; next_ep0_state <= STATUS_PHASE;
              } else { next_ep0_state <= DATA_TX_PHASE; }
            end else { next_ep0_state <= DATA_TX_PHASE; }
          end else { ep0_data_tx_last <= 1'b1; next_ep0_state <= STATUS_PHASE; }
        end
        STATUS_PHASE: begin
          if (is_control_read_transfer_reg) begin
            if (ep0_in_ack_received_from_adapter) begin
              ep0_ack <= 1'b1; next_ep0_state <= IDLE;
            end else { next_ep0_state <= STATUS_PHASE; }
          end else { ep0_ack <= 1'b1; next_ep0_state <= IDLE; }
        end
        DATA_RX_PHASE: begin
          if (bytes_received_count < requested_len) begin
            ep0_data_rx_ready_from_cdc <= 1'b1;
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
              end else { next_ep0_state <= DATA_RX_PHASE; }
            end else { next_ep0_state <= DATA_RX_PHASE; }
          end else { next_ep0_state <= STATUS_PHASE; }
        end
        default: next_ep0_state <= IDLE;
      endcase
    end
  end
endmodule
`endif // CDC_ACM_HANDLER_SV
