// ft601_protocol_adapter.sv
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`ifndef FT601_PROTOCOL_ADAPTER_SV
`define FT601_PROTOCOL_ADAPTER_SV

module ft601_protocol_adapter #(
    parameter FT601_DATA_WIDTH = 32,
    parameter APP_DATA_WIDTH   = 8
) (
    input logic clk_sys,
    input logic rst_sys,

    // Interface to pcileech_ft601 instance
    input  logic [FT601_DATA_WIDTH-1:0] ft601_if_dout,
    input  logic                        ft601_if_dout_valid,
    input  logic                        ft601_if_din_req_data,
    output logic [FT601_DATA_WIDTH-1:0] ft601_if_din,
    output logic                        ft601_if_din_wr_en,

    // Interface to cdc_acm_handler (EP0 signals)
    output logic                        ep0_setup_packet_valid,
    output logic [63:0]                 ep0_setup_packet_data,
    output logic                        ep0_data_tx_ready,
    output logic                        ep0_in_ack_received,
    output logic                        ep0_out_data_available,
    output logic [APP_DATA_WIDTH-1:0]   ep0_out_data,
    output logic                        ep0_out_data_last,

    input  logic [APP_DATA_WIDTH-1:0]   ep0_data_tx,
    input  logic                        ep0_data_tx_valid,
    input  logic                        ep0_data_tx_last,
    input  logic                        ep0_stall,
    input  logic                        ep0_ack,
    input  logic                        ep0_data_rx_ready_from_cdc,

    // Interface for Interrupt IN data from cdc_acm_handler
    input  logic                        intr_data_valid_from_cdc_i,
    input  logic [APP_DATA_WIDTH-1:0]   intr_data_from_cdc_i,
    input  logic                        intr_data_last_from_cdc_i,
    output logic                        intr_data_ready_to_cdc_o,

    // Interface to Bulk OUT FIFO (Adapter to FIFO)
    output logic [APP_DATA_WIDTH-1:0]   bulk_out_din,
    output logic                        bulk_out_wr_en,

    // Interface from Bulk IN FIFO (FIFO to Adapter)
    input  logic [APP_DATA_WIDTH-1:0]   bulk_in_dout,
    input  logic                        bulk_in_empty,
    output logic                        bulk_in_rd_en
);

  localparam CH_WIDTH = 4;
  localparam CH_POS   = FT601_DATA_WIDTH - CH_WIDTH;

  localparam CH_EP0_SETUP              = 4'h0;
  localparam CH_EP0_DATA_OUT_FROM_HOST = 4'h1;
  localparam CH_EP0_IN_STATUS_FROM_HOST= 4'h2;

  localparam CH_EP0_DATA_IN_TO_HOST    = 4'h8;
  localparam CH_EP0_STATUS_IN_TO_HOST  = 4'h9;
  localparam CH_EP0_STALL_TO_HOST      = 4'hA;

  localparam CH_INTR_IN_TO_HOST        = 4'h5; // New channel for Interrupt IN

  localparam CH_BULK_OUT_FROM_HOST     = 4'hC;
  localparam CH_BULK_IN_TO_HOST        = 4'hD;

  typedef enum logic [2:0] { RX_IDLE, RX_SETUP_P1, RX_SETUP_P2,
                              RX_EP0_OUT_DATA_WORD, RX_AWAIT_CDC_ACK_AFTER_OUT,
                              RX_BULK_OUT_WORD } rx_state_e;
  rx_state_e current_rx_state, next_rx_state;
  logic [63:0] setup_packet_buffer_reg;
  logic [APP_DATA_WIDTH-1:0] ep0_out_data_byte_reg;
  logic [15:0] expected_ep0_out_len_reg;
  logic [15:0] received_ep0_out_bytes_count_reg;
  logic cdc_acked_setup_or_data_reg;
  logic [63:0] current_setup_data_for_ep0_out_len;

  typedef enum logic [2:0] { TX_IDLE, TX_EP0_IN_DATA_WORD, TX_INTERRUPT_IN_DATA_WORD,
                              TX_BULK_IN_WORD, TX_EP0_STATUS_ZLP, TX_SEND_STALL,
                              TX_AWAIT_HOST_IN_ACK } tx_state_e;
  tx_state_e current_tx_state, next_tx_state;
  logic [APP_DATA_WIDTH-1:0] ep0_tx_byte_reg;
  logic ep0_tx_last_reg;
  logic [APP_DATA_WIDTH-1:0] intr_tx_byte_reg; // Latch for interrupt data
  logic intr_tx_last_reg;                     // Latch for interrupt last flag
  logic send_ep0_status_zlp_req_reg;
  logic send_stall_req_reg;
  logic is_control_read_data_phase_pending_ack;

  assign ep0_setup_packet_valid = (current_rx_state == RX_SETUP_P2) && (next_rx_state != RX_SETUP_P2);
  assign ep0_setup_packet_data  = setup_packet_buffer_reg;
  assign ep0_data_tx_ready      = (current_tx_state == TX_IDLE) && !send_stall_req_reg && !send_ep0_status_zlp_req_reg && !is_control_read_data_phase_pending_ack && !intr_data_valid_from_cdc_i; // Also ready if no higher prio TX
  assign intr_data_ready_to_cdc_o = (current_tx_state == TX_IDLE) && !send_stall_req_reg && !send_ep0_status_zlp_req_reg && !is_control_read_data_phase_pending_ack && !ep0_data_tx_valid; // Ready if no EP0 TX active

  assign ep0_in_ack_received    = 1'b0;
  assign ep0_out_data_available = 1'b0;
  assign ep0_out_data           = ep0_out_data_byte_reg;
  assign ep0_out_data_last      = (received_ep0_out_bytes_count_reg == expected_ep0_out_len_reg) && (expected_ep0_out_len_reg > 0);

  assign bulk_out_din     = ft601_if_dout[APP_DATA_WIDTH-1:0];
  assign bulk_out_wr_en   = 1'b0;
  assign bulk_in_rd_en    = 1'b0;
  assign ft601_if_din     = '0;
  assign ft601_if_din_wr_en = 1'b0;

  // RX Logic (unchanged from previous correct version, just ensure defaults are handled)
  always_ff @(posedge clk_sys or posedge rst_sys) begin
    if (rst_sys) begin
      current_rx_state <= RX_IDLE; setup_packet_buffer_reg <= '0;
      ep0_out_data_byte_reg <= '0; cdc_acked_setup_or_data_reg <= 1'b0;
      expected_ep0_out_len_reg <= 0; received_ep0_out_bytes_count_reg <= 0;
      current_setup_data_for_ep0_out_len <= '0;
    end else begin
      current_rx_state <= next_rx_state;
      cdc_acked_setup_or_data_reg <= ep0_ack;
      if (current_rx_state == RX_IDLE && next_rx_state == RX_SETUP_P1) begin
          // Latch setup_packet_data from cdc_acm_handler (actually from adapter input, but conceptually)
          // This seems to be an error from merge: current_setup_data_for_ep0_out_len should be based on actual setup from FT601
          // For now, assume setup_packet_data is valid when CH_EP0_SETUP arrives.
          // The ft601_protocol_adapter should form ep0_setup_packet_data from FT601 words.
      end
      if (current_rx_state == RX_SETUP_P2 && ep0_ack) begin
          automatic logic [7:0] bmRT_setup = setup_packet_buffer_reg[7:0]; // Assuming direct mapping now
          automatic logic [15:0] wL_setup = setup_packet_buffer_reg[63:48];
          if (bmRT_setup[7] == 0 && wL_setup > 0) {
              expected_ep0_out_len_reg <= wL_setup;
              received_ep0_out_bytes_count_reg <= 0;
          } else {
              expected_ep0_out_len_reg <= 0;
              received_ep0_out_bytes_count_reg <= 0;
          }
      end
      if (current_rx_state == RX_EP0_OUT_DATA_WORD && ep0_out_data_available && ep0_data_rx_ready_from_cdc) begin
          received_ep0_out_bytes_count_reg <= received_ep0_out_bytes_count_reg + 1;
      end
      case (current_rx_state)
        RX_IDLE: if (ft601_if_dout_valid && ft601_if_dout[CH_POS+:CH_WIDTH] == CH_EP0_SETUP) setup_packet_buffer_reg[31:0] <= ft601_if_dout[FT601_DATA_WIDTH-1:0];
        RX_SETUP_P1: if (ft601_if_dout_valid && ft601_if_dout[CH_POS+:CH_WIDTH] == CH_EP0_SETUP) setup_packet_buffer_reg[63:32] <= ft601_if_dout[FT601_DATA_WIDTH-1:0];
        RX_EP0_OUT_DATA_WORD: if (ep0_out_data_available) ep0_out_data_byte_reg <= ft601_if_dout[APP_DATA_WIDTH-1:0];
        default: ;
      endcase
    end
  end

  always_comb begin
    next_rx_state = current_rx_state;
    assign bulk_out_wr_en   = 1'b0;
    assign ep0_out_data_available = 1'b0;
    assign ep0_in_ack_received = 1'b0;
    case (current_rx_state)
      RX_IDLE: if (ft601_if_dout_valid) begin
          automatic logic [CH_WIDTH-1:0] channel = ft601_if_dout[CH_POS +: CH_WIDTH];
          if (channel == CH_EP0_SETUP) next_rx_state = RX_SETUP_P1;
          else if (channel == CH_EP0_DATA_OUT_FROM_HOST && expected_ep0_out_len_reg > 0 && received_ep0_out_bytes_count_reg < expected_ep0_out_len_reg && ep0_data_rx_ready_from_cdc) next_rx_state = RX_EP0_OUT_DATA_WORD;
          else if (channel == CH_BULK_OUT_FROM_HOST) { assign bulk_out_wr_en = 1'b1; next_rx_state = RX_IDLE; } // Consume immediately
          else if (channel == CH_EP0_IN_STATUS_FROM_HOST) assign ep0_in_ack_received = 1'b1; // Pulse
      end
      RX_SETUP_P1: if (ft601_if_dout_valid && ft601_if_dout[CH_POS+:CH_WIDTH] == CH_EP0_SETUP) next_rx_state = RX_SETUP_P2; else if (ft601_if_dout_valid) next_rx_state = RX_IDLE;
      RX_SETUP_P2: if (cdc_acked_setup_or_data_reg) begin
          if (expected_ep0_out_len_reg > 0) begin
            if (ep0_data_rx_ready_from_cdc) next_rx_state = RX_EP0_OUT_DATA_WORD; else next_rx_state = RX_IDLE;
          end else next_rx_state = RX_IDLE;
      end
      RX_EP0_OUT_DATA_WORD: begin
        assign ep0_out_data_available = ft601_if_dout_valid && (ft601_if_dout[CH_POS+:CH_WIDTH] == CH_EP0_DATA_OUT_FROM_HOST);
        if (ep0_out_data_available && ep0_data_rx_ready_from_cdc) begin
          if (received_ep0_out_bytes_count_reg + 1 == expected_ep0_out_len_reg) next_rx_state = RX_AWAIT_CDC_ACK_AFTER_OUT;
          else next_rx_state = RX_IDLE;
        end
      end
      RX_AWAIT_CDC_ACK_AFTER_OUT: if (cdc_acked_setup_or_data_reg) next_rx_state = RX_IDLE;
      default: next_rx_state = RX_IDLE;
    endcase
  end

  // TX Logic
  always_ff @(posedge clk_sys or posedge rst_sys) begin
    if (rst_sys) begin
      current_tx_state <= TX_IDLE; ep0_tx_byte_reg <= '0; ep0_tx_last_reg <= 1'b0;
      intr_tx_byte_reg <= '0; intr_tx_last_reg <= 1'b0;
      send_ep0_status_zlp_req_reg <= 1'b0; send_stall_req_reg <= 1'b0;
      is_control_read_data_phase_pending_ack <= 1'b0;
    end else begin
      current_tx_state <= next_tx_state;
      if (ep0_stall && (current_tx_state == TX_IDLE || current_tx_state == TX_EP0_IN_DATA_WORD || current_tx_state == TX_INTERRUPT_IN_DATA_WORD)) send_stall_req_reg <= 1'b1;
      if (current_tx_state == TX_SEND_STALL && ft601_if_din_req_data) send_stall_req_reg <= 1'b0;
      if (ep0_data_tx_valid && ep0_data_tx_ready) { ep0_tx_byte_reg <= ep0_data_tx; ep0_tx_last_reg <= ep0_data_tx_last; }
      if (intr_data_valid_from_cdc_i && intr_data_ready_to_cdc_o) { intr_tx_byte_reg <= intr_data_from_cdc_i; intr_tx_last_reg <= intr_data_last_from_cdc_i; }
      if (cdc_acked_setup_or_data_reg && ( (current_rx_state == RX_AWAIT_CDC_ACK_AFTER_OUT) || (current_rx_state == RX_SETUP_P2 && expected_ep0_out_len_reg == 0 && !setup_packet_buffer_reg[7/*bmRequestType.Direction*/]) ) ) send_ep0_status_zlp_req_reg <= 1'b1;
      if (current_tx_state == TX_EP0_STATUS_ZLP && ft601_if_din_req_data) send_ep0_status_zlp_req_reg <= 1'b0;
      if (current_tx_state == TX_EP0_IN_DATA_WORD && ep0_tx_last_reg && ft601_if_din_wr_en) is_control_read_data_phase_pending_ack <= 1'b1;
      if (is_control_read_data_phase_pending_ack && ep0_in_ack_received) is_control_read_data_phase_pending_ack <= 1'b0;
      if (current_tx_state != TX_AWAIT_HOST_IN_ACK && current_tx_state != TX_EP0_IN_DATA_WORD) is_control_read_data_phase_pending_ack <= 1'b0;
    end
  end

  always_comb begin
    next_tx_state = current_tx_state;
    assign ep0_data_tx_ready = (current_tx_state == TX_IDLE) && !send_stall_req_reg && !send_ep0_status_zlp_req_reg && !is_control_read_data_phase_pending_ack && !intr_data_valid_from_cdc_i;
    assign intr_data_ready_to_cdc_o = (current_tx_state == TX_IDLE) && !send_stall_req_reg && !send_ep0_status_zlp_req_reg && !is_control_read_data_phase_pending_ack && !ep0_data_tx_valid;

    automatic logic [FT601_DATA_WIDTH-1:0] temp_ft601_din = '0;
    automatic logic temp_ft601_din_wr_en = 1'b0;
    automatic logic temp_bulk_in_rd_en = 1'b0;

    case (current_tx_state)
      TX_IDLE: begin
        if (send_stall_req_reg && ft601_if_din_req_data) next_tx_state = TX_SEND_STALL;
        else if (send_ep0_status_zlp_req_reg && ft601_if_din_req_data) next_tx_state = TX_EP0_STATUS_ZLP;
        else if (is_control_read_data_phase_pending_ack) next_tx_state = TX_AWAIT_HOST_IN_ACK;
        else if (ep0_data_tx_valid && ft601_if_din_req_data) next_tx_state = TX_EP0_IN_DATA_WORD;
        else if (intr_data_valid_from_cdc_i && ft601_if_din_req_data) next_tx_state = TX_INTERRUPT_IN_DATA_WORD;
        else if (!bulk_in_empty && ft601_if_din_req_data) next_tx_state = TX_BULK_IN_WORD;
      end
      TX_EP0_IN_DATA_WORD: begin
        if (ft601_if_din_req_data) begin
          temp_ft601_din = {CH_EP0_DATA_IN_TO_HOST, {(FT601_DATA_WIDTH-CH_WIDTH-APP_DATA_WIDTH){1'b0}}, ep0_tx_byte_reg};
          temp_ft601_din_wr_en = 1'b1;
          if (ep0_tx_last_reg) next_tx_state = TX_AWAIT_HOST_IN_ACK;
          else next_tx_state = TX_IDLE;
        end
      end
      TX_INTERRUPT_IN_DATA_WORD: begin
        if (ft601_if_din_req_data) begin
            temp_ft601_din = {CH_INTR_IN_TO_HOST, {(FT601_DATA_WIDTH-CH_WIDTH-APP_DATA_WIDTH){1'b0}}, intr_tx_byte_reg};
            temp_ft601_din_wr_en = 1'b1;
            // CDC handler manages pending flag based on last byte. Adapter just sends.
            next_tx_state = TX_IDLE; // Assume one byte per request for now, or CDC will assert valid again
        end
      end
      TX_BULK_IN_WORD: begin
        if (!bulk_in_empty && ft601_if_din_req_data) begin
          temp_bulk_in_rd_en = 1'b1;
          temp_ft601_din = {CH_BULK_IN_TO_HOST, {(FT601_DATA_WIDTH-CH_WIDTH-APP_DATA_WIDTH){1'b0}}, bulk_in_dout};
          temp_ft601_din_wr_en = 1'b1;
        end
        next_tx_state = TX_IDLE;
      end
      TX_SEND_STALL: begin
        if (ft601_if_din_req_data) begin
          temp_ft601_din = {CH_EP0_STALL_TO_HOST, {(FT601_DATA_WIDTH-CH_WIDTH){1'b0}} };
          temp_ft601_din_wr_en = 1'b1;
          next_tx_state = TX_IDLE;
        end
      end
      TX_EP0_STATUS_ZLP: begin
        if (ft601_if_din_req_data) begin
          temp_ft601_din = {CH_EP0_STATUS_IN_TO_HOST, {(FT601_DATA_WIDTH-CH_WIDTH){1'b0}} };
          temp_ft601_din_wr_en = 1'b1;
          next_tx_state = TX_IDLE;
        end
      end
      TX_AWAIT_HOST_IN_ACK: begin
        if (ep0_in_ack_received) next_tx_state = TX_IDLE;
      end
      default: next_tx_state = TX_IDLE;
    endcase

    assign ft601_if_din = temp_ft601_din;
    assign ft601_if_din_wr_en = temp_ft601_din_wr_en;
    assign bulk_in_rd_en = temp_bulk_in_rd_en;
  end

endmodule

`endif // FT601_PROTOCOL_ADAPTER_SV
