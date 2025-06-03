// serial_port_application.sv
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`ifndef SERIAL_PORT_APPLICATION_SV
`define SERIAL_PORT_APPLICATION_SV

module serial_port_application #(
    parameter BRAM_ADDR_WIDTH = 12, // For 4KB BRAM (2^12 bytes)
    parameter DATA_WIDTH = 8,
    parameter BRAM_DEPTH_BYTES = 1 << BRAM_ADDR_WIDTH, // e.g., 4096
    parameter MAX_DMA_TRANSFER_LEN = 64 // Typical USB full-speed bulk packet size
) (
    // Clock & Reset
    input logic clk_sys,
    input logic rst_sys,

    // TX BRAM Port A (Application Writes)
    output logic [BRAM_ADDR_WIDTH-1:0] app_tx_bram_addr_o,
    output logic [DATA_WIDTH-1:0]      app_tx_bram_din_o,
    output logic                       app_tx_bram_wen_o,
    // TX BRAM Port B (DMA Reads) - Note: BRAM output (doutb) connects to DMA's input
    input  logic [DATA_WIDTH-1:0]      dma_tx_bram_dout_i, // Data from TX BRAM Port B to DMA
    // DMA provides address and enable for Port B of TX BRAM externally

    // RX BRAM Port A (DMA Writes) - Note: BRAM inputs connect to DMA's outputs
    // DMA provides address, data, and write enable for Port A of RX BRAM externally
    // RX BRAM Port B (Application Reads)
    output logic [BRAM_ADDR_WIDTH-1:0] app_rx_bram_addr_o,
    input  logic [DATA_WIDTH-1:0]      app_rx_bram_dout_i, // Data from RX BRAM Port B to App
    output logic                       app_rx_bram_en_o,   // App enables read from RX BRAM Port B

    // Application Side (Data In/Out)
    input  logic [DATA_WIDTH-1:0] app_tx_byte_in,
    input  logic app_tx_byte_valid,
    output logic app_tx_buffer_full,

    output logic [DATA_WIDTH-1:0] app_rx_byte_out,
    output logic app_rx_byte_available,
    input  logic app_rx_byte_read,

    // DMA Control Interface
    input  logic dma_tx_busy,
    input  logic dma_tx_done, // Assumed to be a 1-cycle pulse
    input  logic dma_rx_busy,
    input  logic dma_rx_done, // Assumed to be a 1-cycle pulse

    output logic dma_tx_start, // To DMA controller
    output logic [BRAM_ADDR_WIDTH-1:0] dma_tx_bram_start_addr,
    output logic [15:0] dma_tx_transfer_length, // DMA controller might have its own length width

    output logic dma_rx_start, // To DMA controller
    output logic [BRAM_ADDR_WIDTH-1:0] dma_rx_bram_start_addr,
    output logic [15:0] dma_rx_transfer_length,

    // CDC Control Signals
    input logic dtr_active // Host DTR signal state (e.g., from cdc_acm_handler)
);

  // TX Buffer Management
  logic [BRAM_ADDR_WIDTH-1:0] tx_bram_app_write_ptr_reg, tx_bram_dma_read_ptr_reg; // Renamed for clarity
  logic [BRAM_ADDR_WIDTH:0]   tx_bram_fill_level_reg; // One extra bit for full/empty differentiation
  logic [15:0] last_dma_tx_length_reg; // Store the length of the last TX DMA

  // RX Buffer Management
  logic [BRAM_ADDR_WIDTH-1:0] rx_bram_dma_write_ptr_reg, rx_bram_app_read_ptr_reg; // Renamed for clarity
  logic [BRAM_ADDR_WIDTH:0]   rx_bram_fill_level_reg;
  logic [15:0] last_dma_rx_length_reg; // Store the length of the last RX DMA

  // Internal signals for DMA start requests
  logic app_tx_bram_wen_internal;
  logic app_rx_bram_en_internal;
  logic dma_tx_start_internal;
  logic dma_rx_start_internal;

  // --- Sequential Logic ---
  always_ff @(posedge clk_sys or posedge rst_sys) begin
    if (rst_sys) begin
      // TX Reset
      tx_bram_app_write_ptr_reg <= '0;
      tx_bram_dma_read_ptr_reg <= '0;
      tx_bram_fill_level_reg <= '0;
      dma_tx_start <= 1'b0;
      last_dma_tx_length_reg <= '0;
      app_tx_bram_wen_o <= 1'b0;

      // RX Reset
      rx_bram_dma_write_ptr_reg <= '0;
      rx_bram_app_read_ptr_reg <= '0;
      rx_bram_fill_level_reg <= '0;
      dma_rx_start <= 1'b0;
      last_dma_rx_length_reg <= '0;
      app_rx_bram_en_o <= 1'b0;

    end else begin
      // Default assignments for BRAM control signals
      app_tx_bram_wen_o <= 1'b0;
      app_rx_bram_en_o <= 1'b0;

      // TX Buffer - Application Writing Data
      if (app_tx_byte_valid && !app_tx_buffer_full) begin
        // app_tx_bram_addr_o is tx_bram_app_write_ptr_reg (combinational)
        // app_tx_bram_din_o is app_tx_byte_in (combinational)
        app_tx_bram_wen_o <= 1'b1; // Assert BRAM write enable
        tx_bram_app_write_ptr_reg <= tx_bram_app_write_ptr_reg + 1; // Wraps due to width
        tx_bram_fill_level_reg <= tx_bram_fill_level_reg + 1;
      end

      // TX Buffer - DMA Reading Data (on DMA done)
      // DMA read address is dma_tx_bram_start_addr (from tx_bram_dma_read_ptr_reg)
      // DMA read enable is handled by DMA controller externally to BRAM
      if (dma_tx_done) begin
        tx_bram_dma_read_ptr_reg <= tx_bram_dma_read_ptr_reg + last_dma_tx_length_reg; // Wraps
        tx_bram_fill_level_reg <= tx_bram_fill_level_reg - last_dma_tx_length_reg;
      end

      // DMA TX Start Logic
      if (dma_tx_start_internal && !dma_tx_busy) begin
        dma_tx_start <= 1'b1;
        last_dma_tx_length_reg <= (tx_bram_fill_level_reg > MAX_DMA_TRANSFER_LEN) ? MAX_DMA_TRANSFER_LEN : tx_bram_fill_level_reg;
      end else begin
        dma_tx_start <= 1'b0;
      end

      // RX Buffer - DMA Writing Data (on DMA done)
      // DMA write address is dma_rx_bram_start_addr (from rx_bram_dma_write_ptr_reg)
      // DMA write data and enable are handled by DMA controller externally to BRAM
      if (dma_rx_done) begin
        rx_bram_dma_write_ptr_reg <= rx_bram_dma_write_ptr_reg + last_dma_rx_length_reg; // Wraps
        rx_bram_fill_level_reg <= rx_bram_fill_level_reg + last_dma_rx_length_reg;
      end

      // RX Buffer - Application Reading Data
      if (app_rx_byte_read && app_rx_byte_available) begin
        // app_rx_bram_addr_o is rx_bram_app_read_ptr_reg (combinational)
        app_rx_bram_en_o <= 1'b1; // Assert BRAM read enable for app
        rx_bram_app_read_ptr_reg <= rx_bram_app_read_ptr_reg + 1; // Wraps
        rx_bram_fill_level_reg <= rx_bram_fill_level_reg - 1;
      end

      // DMA RX Start Logic
      if (dma_rx_start_internal && !dma_rx_busy) begin
        dma_rx_start <= 1'b1;
        // Store the transfer length (fixed to MAX_DMA_TRANSFER_LEN for RX for now)
        last_dma_rx_length_reg <= MAX_DMA_TRANSFER_LEN;
      end else begin
        dma_rx_start <= 1'b0;
      end
    end
  end

  // --- Combinational Logic ---

  // TX Buffer Full/Empty and DMA Triggering
  assign app_tx_buffer_full = (tx_bram_fill_level_reg == BRAM_DEPTH_BYTES);
  assign app_tx_bram_addr_o = tx_bram_app_write_ptr_reg; // App writes to current write pointer
  assign app_tx_bram_din_o = app_tx_byte_in;            // App data to be written
  // app_tx_bram_wen_o is driven by sequential logic

  assign dma_tx_start_internal = dtr_active && !dma_tx_busy && (tx_bram_fill_level_reg > 0);
  assign dma_tx_bram_start_addr = tx_bram_dma_read_ptr_reg; // DMA reads from current DMA read pointer
  // dma_tx_transfer_length calculation remains the same
  assign dma_tx_transfer_length = (dma_tx_start_internal) ?
                                  ((tx_bram_fill_level_reg > MAX_DMA_TRANSFER_LEN) ? MAX_DMA_TRANSFER_LEN : tx_bram_fill_level_reg) :
                                  last_dma_tx_length_reg;


  // RX Buffer Full/Empty and DMA Triggering
  assign app_rx_byte_available = (rx_bram_fill_level_reg > 0);
  assign app_rx_bram_addr_o = rx_bram_app_read_ptr_reg; // App reads from current app read pointer
  assign app_rx_byte_out = app_rx_bram_dout_i;         // App gets data from BRAM output port
  // app_rx_bram_en_o is driven by sequential logic

  assign dma_rx_start_internal = dtr_active && !dma_rx_busy && ((BRAM_DEPTH_BYTES - rx_bram_fill_level_reg) >= MAX_DMA_TRANSFER_LEN);
  assign dma_rx_bram_start_addr = rx_bram_dma_write_ptr_reg; // DMA writes to current DMA write pointer
  // dma_rx_transfer_length calculation remains the same
  assign dma_rx_transfer_length = (dma_rx_start_internal) ? MAX_DMA_TRANSFER_LEN : last_dma_rx_length_reg;

endmodule : serial_port_application

`endif // SERIAL_PORT_APPLICATION_SV
