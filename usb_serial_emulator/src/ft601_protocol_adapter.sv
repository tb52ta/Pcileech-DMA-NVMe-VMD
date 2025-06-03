// ft601_protocol_adapter.sv
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`ifndef FT601_PROTOCOL_ADAPTER_SV
`define FT601_PROTOCOL_ADAPTER_SV

module ft601_protocol_adapter #(
    parameter FT601_DATA_WIDTH = 32, // Data width of the pcileech_ft601 interface
    parameter APP_DATA_WIDTH   = 8   // Data width for bulk FIFOs and CDC EP0 data bytes
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
    output logic                        ep0_data_tx_ready,      // Adapter ready for EP0 IN data byte from CDC
    output logic                        ep0_in_ack_received,    // Adapter received host IN ZLP/ACK for EP0 IN data
    output logic                        ep0_out_data_available, // Data from host for EP0 OUT is available for CDC
    output logic [APP_DATA_WIDTH-1:0]   ep0_out_data,
    output logic                        ep0_out_data_last,

    input  logic [APP_DATA_WIDTH-1:0]   ep0_data_tx,
    input  logic                        ep0_data_tx_valid,
    input  logic                        ep0_data_tx_last,
    input  logic                        ep0_stall,      // CDC requests EP0 stall
    input  logic                        ep0_ack,        // CDC ACKed SETUP, or completed DATA/STATUS for its part

    input  logic                        ep0_data_rx_ready_from_cdc, // CDC ready for next EP0 OUT byte

    // Interface to Bulk OUT FIFO (Adapter to FIFO)
    output logic [APP_DATA_WIDTH-1:0]   bulk_out_din,
    output logic                        bulk_out_wr_en,

    // Interface from Bulk IN FIFO (FIFO to Adapter)
    input  logic [APP_DATA_WIDTH-1:0]   bulk_in_dout,
    input  logic                        bulk_in_empty,
    output logic                        bulk_in_rd_en
);

  // Protocol Definition
  localparam CH_WIDTH = 4;
  localparam CH_POS   = FT601_DATA_WIDTH - CH_WIDTH;

  localparam CH_EP0_SETUP              = 4'h0; // H->F: Setup packet (2 words for 8 bytes)
  localparam CH_EP0_DATA_OUT_FROM_HOST = 4'h1; // H->F: Data for EP0 OUT (byte per word in lower bits)
  localparam CH_EP0_IN_STATUS_FROM_HOST= 4'h2; // H->F: Host ACK for EP0 IN data (ZLP or status packet)

  localparam CH_EP0_DATA_IN_TO_HOST    = 4'h8; // F->H: Data for EP0 IN (byte per word in lower bits)
  localparam CH_EP0_STATUS_IN_TO_HOST  = 4'h9; // F->H: ZLP status after Control Write data stage
  localparam CH_EP0_STALL_TO_HOST      = 4'hA; // F->H: Signal EP0 STALL

  localparam CH_BULK_OUT_FROM_HOST     = 4'hC; // H->F: Bulk OUT data (byte per word)
  localparam CH_BULK_IN_TO_HOST        = 4'hD; // F->H: Bulk IN data (byte per word)

  // RX State Machine (ft601_if_dout -> EP0/Bulk OUT FIFO)
  typedef enum logic [2:0] { RX_IDLE, RX_SETUP_P1, RX_SETUP_P2,
                              RX_EP0_OUT_DATA_WORD, RX_BULK_OUT_WORD } rx_state_e;
  rx_state_e current_rx_state, next_rx_state;
  logic [63:0] setup_packet_buffer_reg;
  logic [APP_DATA_WIDTH-1:0] ep0_out_data_byte_reg;
  logic ep0_out_last_byte_reg; // TODO: How is last byte of EP0 OUT data indicated by host?
  logic cdc_acked_setup; // Flag that CDC handler has ACKed the setup packet

  // TX State Machine (EP0/Bulk IN FIFO -> ft601_if_din)
  typedef enum logic [2:0] { TX_IDLE, TX_EP0_IN_DATA_WORD, TX_BULK_IN_WORD,
                              TX_EP0_STATUS_ZLP, TX_SEND_STALL } tx_state_e;
  tx_state_e current_tx_state, next_tx_state;
  logic [APP_DATA_WIDTH-1:0] ep0_tx_byte_reg;
  logic ep0_tx_last_reg;
  logic send_ep0_status_zlp_req;
  logic send_stall_req;


  // Default assignments for outputs
  assign ep0_setup_packet_valid = 1'b0;
  assign ep0_setup_packet_data  = setup_packet_buffer_reg;
  assign ep0_data_tx_ready      = 1'b0;
  assign ep0_in_ack_received    = 1'b0;
  assign ep0_out_data_available = 1'b0;
  assign ep0_out_data           = ep0_out_data_byte_reg;
  assign ep0_out_data_last      = ep0_out_last_byte_reg;

  assign bulk_out_din     = ft601_if_dout[APP_DATA_WIDTH-1:0]; // Default connection
  assign bulk_out_wr_en   = 1'b0;
  assign bulk_in_rd_en    = 1'b0;
  assign ft601_if_din     = '0;
  assign ft601_if_din_wr_en = 1'b0;

  // RX Logic: Processing data from FT601
  always_ff @(posedge clk_sys or posedge rst_sys) begin
    if (rst_sys) begin
      current_rx_state <= RX_IDLE;
      setup_packet_buffer_reg <= '0;
      ep0_out_data_byte_reg <= '0;
      ep0_out_last_byte_reg <= 1'b0;
      cdc_acked_setup <= 1'b0;
    end else begin
      current_rx_state <= next_rx_state;
      // Latch EP0 OUT data if valid and in the correct state
      if (current_rx_state == RX_EP0_OUT_DATA_WORD && ft601_if_dout_valid &&
          ft601_if_dout[CH_POS +: CH_WIDTH] == CH_EP0_DATA_OUT_FROM_HOST) begin
          ep0_out_data_byte_reg <= ft601_if_dout[APP_DATA_WIDTH-1:0];
          // TODO: ep0_out_last_byte_reg needs a way to be set from FT601 packet protocol
      end

      if (ep0_ack) begin // CDC handler ACKed setup or data/status phase
          cdc_acked_setup <= 1'b1;
      end
      if (current_rx_state == RX_IDLE) begin // Reset cdc_acked_setup when returning to RX_IDLE
          cdc_acked_setup <= 1'b0;
      end

      case (current_rx_state)
        RX_IDLE: begin
          if (ft601_if_dout_valid && ft601_if_dout[CH_POS +: CH_WIDTH] == CH_EP0_SETUP) begin
            setup_packet_buffer_reg[31:0] <= ft601_if_dout[FT601_DATA_WIDTH-1:0];
          end
        end
        RX_SETUP_P1: begin
          if (ft601_if_dout_valid && ft601_if_dout[CH_POS +: CH_WIDTH] == CH_EP0_SETUP) begin // Expecting 2nd word
            setup_packet_buffer_reg[63:32] <= ft601_if_dout[FT601_DATA_WIDTH-1:0];
          end
        end
        default: begin
        end
      endcase
    end
  end

  always_comb begin
    next_rx_state = current_rx_state;
    // Combinational outputs that depend on current_rx_state or inputs
    assign ep0_setup_packet_valid = (current_rx_state == RX_SETUP_P2);
    assign ep0_out_data_available = (current_rx_state == RX_EP0_OUT_DATA_WORD) && ft601_if_dout_valid && (ft601_if_dout[CH_POS +: CH_WIDTH] == CH_EP0_DATA_OUT_FROM_HOST);

    // Default bulk path (can be overridden by EP0 logic if conditions met)
    assign bulk_out_wr_en = (current_rx_state == RX_BULK_OUT_WORD && ft601_if_dout_valid && ft601_if_dout[CH_POS +: CH_WIDTH] == CH_BULK_OUT_FROM_HOST);

    case (current_rx_state)
      RX_IDLE: begin
        if (ft601_if_dout_valid) begin
          automatic logic [CH_WIDTH-1:0] channel = ft601_if_dout[CH_POS +: CH_WIDTH];
          if (channel == CH_EP0_SETUP) begin
            next_rx_state = RX_SETUP_P1;
          end else if (channel == CH_EP0_DATA_OUT_FROM_HOST) begin
            // Check if CDC handler is expecting OUT data (e.g. after a relevant SETUP ACK)
            // For now, assume ep0_data_rx_ready_from_cdc implies this.
            if(ep0_data_rx_ready_from_cdc) next_rx_state = RX_EP0_OUT_DATA_WORD;
            // else stay IDLE, let host retry or timeout.
          end else if (channel == CH_BULK_OUT_FROM_HOST) begin
            next_rx_state = RX_BULK_OUT_WORD;
          end else if (channel == CH_EP0_IN_STATUS_FROM_HOST) begin
            // This is host's ACK (ZLP) after we sent EP0 IN data.
            assign ep0_in_ack_received = 1'b1; // Pulse for one cycle
            // No state change needed, just signal CDC.
          end
        end
      end
      RX_SETUP_P1: begin
        if (ft601_if_dout_valid && ft601_if_dout[CH_POS +: CH_WIDTH] == CH_EP0_SETUP) begin
          next_rx_state = RX_SETUP_P2;
        end else if (ft601_if_dout_valid) { // Unexpected packet
           next_rx_state = RX_IDLE; // Or error state
        } // else wait for valid data
      end
      RX_SETUP_P2: begin // Full setup packet in buffer_reg, ep0_setup_packet_valid asserted this cycle
        if (cdc_acked_setup) begin // CDC handler processed the setup packet
          next_rx_state = RX_IDLE; // Or transition based on if data phase is expected
                                   // This needs more info from CDC: is it DATA_IN, DATA_OUT, or NO_DATA?
                                   // For now, assuming adapter's job for setup is done once CDC ACKs.
        end
        // else hold state, ep0_setup_packet_valid remains asserted.
      end
      RX_EP0_OUT_DATA_WORD: begin
        // ep0_out_data_available is asserted if ft601_if_dout_valid and correct channel
        if (ep0_out_data_available && ep0_data_rx_ready_from_cdc) begin
          // CDC handler consumed the byte.
          // TODO: Need logic for multi-byte EP0 OUT transfers and ep0_out_data_last.
          // For now, assume single byte, then status.
          // This would typically wait for cdc_ack for data stage.
          next_rx_state = RX_IDLE; // Simplified: assume data phase done
        end
        // else if !ft601_if_dout_valid, wait for next word or timeout
        // else if !ep0_data_rx_ready_from_cdc, wait for CDC
      end
      RX_BULK_OUT_WORD: begin
        // bulk_out_wr_en is asserted combinationally if conditions are met
        next_rx_state = RX_IDLE; // Assume data consumed by FIFO or FIFO handles backpressure
      end
      default: next_rx_state = RX_IDLE;
    endcase
  end

  // TX Logic: Sending data to FT601
  always_ff @(posedge clk_sys or posedge rst_sys) begin
    if (rst_sys) begin
      current_tx_state <= TX_IDLE;
      ep0_tx_byte_reg <= '0;
      ep0_tx_last_reg <= 1'b0;
      send_ep0_status_zlp_req <= 1'b0;
      send_stall_req <= 1'b0;
    end else begin
      current_tx_state <= next_tx_state;

      if (ep0_stall && (current_tx_state == TX_IDLE || current_tx_state == TX_EP0_IN_DATA_WORD)) begin
          send_stall_req <= 1'b1; // Prioritize STALL if requested by CDC
      end
      if (current_tx_state == TX_SEND_STALL && ft601_if_din_req_data) begin // Stall sent
          send_stall_req <= 1'b0;
      end

      // Latch EP0 IN data from CDC
      if (ep0_data_tx_valid && ep0_data_tx_ready) begin // If CDC has data AND adapter is ready
        ep0_tx_byte_reg <= ep0_data_tx;
        ep0_tx_last_reg <= ep0_data_tx_last;
      end

      // Check if CDC expects us to send a ZLP status for Control Write
      // This happens when CDC acks a transaction that had an OUT data phase or no data phase.
      // Condition: ep0_ack is high, and the previous transaction was a control write.
      // This needs more state tracking of the current EP0 transaction direction.
      // Simplified: if ep0_ack is from a non-GET_DESCRIPTOR type handled by CDC.
      // For now, this is manually triggered by testbench or higher logic if needed.
      // if (cdc_acked_control_write_data_phase) send_ep0_status_zlp_req <= 1'b1;
      if (current_tx_state == TX_EP0_STATUS_ZLP && ft601_if_din_req_data) begin
          send_ep0_status_zlp_req <= 1'b0; // ZLP sent
      end
    end
  end

  always_comb begin
    next_tx_state = current_tx_state;
    assign ep0_data_tx_ready = (current_tx_state == TX_IDLE) && !send_stall_req && !send_ep0_status_zlp_req;

    // Default assignments for FT601 TX path
    logic [FT601_DATA_WIDTH-1:0] current_ft601_din;
    logic current_ft601_din_wr_en;

    current_ft601_din = '0;
    current_ft601_din_wr_en = 1'b0;
    assign bulk_in_rd_en = 1'b0; // Default

    case (current_tx_state)
      TX_IDLE: begin
        if (send_stall_req && ft601_if_din_req_data) begin
          next_tx_state = TX_SEND_STALL;
        end else if (send_ep0_status_zlp_req && ft601_if_din_req_data) begin
          next_tx_state = TX_EP0_STATUS_ZLP;
        end else if (ep0_data_tx_valid && ft601_if_din_req_data) begin // EP0 IN data from CDC
          next_tx_state = TX_EP0_IN_DATA_WORD;
        end else if (!bulk_in_empty && ft601_if_din_req_data) begin // Bulk IN data from FIFO
          next_tx_state = TX_BULK_IN_WORD;
        end
      end
      TX_EP0_IN_DATA_WORD: begin
        current_ft601_din = {CH_EP0_DATA_IN_TO_HOST, {(FT601_DATA_WIDTH-CH_WIDTH-APP_DATA_WIDTH){1'b0}}, ep0_tx_byte_reg};
        current_ft601_din_wr_en = ft601_if_din_req_data;
        if (ft601_if_din_req_data) begin // Successfully sent current byte
          if (ep0_tx_last_reg) begin
            // After last data byte of an IN transfer, host sends ZLP status.
            // Adapter waits for CH_EP0_IN_STATUS_FROM_HOST.
            next_tx_state = TX_IDLE;
          end else {
            // Ready for next byte from CDC (ep0_data_tx_ready will be high via IDLE state if din_req_data still high)
            next_tx_state = TX_IDLE;
          end
        end
        // else stay in TX_EP0_IN_DATA_WORD, retry sending same byte
      end
      TX_BULK_IN_WORD: begin
        if (!bulk_in_empty && ft601_if_din_req_data) begin
          assign bulk_in_rd_en = 1'b1; // Enable read from FIFO
          current_ft601_din = {CH_BULK_IN_TO_HOST, {(FT601_DATA_WIDTH-CH_WIDTH-APP_DATA_WIDTH){1'b0}}, bulk_in_dout};
          current_ft601_din_wr_en = 1'b1;
        end
        next_tx_state = TX_IDLE; // Go back to IDLE to re-evaluate
      end
      TX_SEND_STALL: begin
        current_ft601_din = {CH_EP0_STALL_TO_HOST, {(FT601_DATA_WIDTH-CH_WIDTH){1'b0}} };
        current_ft601_din_wr_en = ft601_if_din_req_data;
        if (ft601_if_din_req_data) begin // Stall signal sent
            next_tx_state = TX_IDLE;
        end
      end
      TX_EP0_STATUS_ZLP: begin // For Control-Write status phase (Device to Host ZLP)
        current_ft601_din = {CH_EP0_STATUS_IN_TO_HOST, {(FT601_DATA_WIDTH-CH_WIDTH){1'b0}} }; // Zero length data payload
        current_ft601_din_wr_en = ft601_if_din_req_data;
        if (ft601_if_din_req_data) begin // ZLP sent
            next_tx_state = TX_IDLE;
        end
      end
      default: next_tx_state = TX_IDLE;
    endcase

    assign ft601_if_din = current_ft601_din;
    assign ft601_if_din_wr_en = current_ft601_din_wr_en;
  end

endmodule

`endif // FT601_PROTOCOL_ADAPTER_SV
