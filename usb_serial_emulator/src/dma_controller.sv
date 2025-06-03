// dma_controller.sv
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`ifndef DMA_CONTROLLER_SV
`define DMA_CONTROLLER_SV

module dma_controller #(
    parameter BRAM_ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 8
) (
    // System Interface
    input logic clk_sys,
    input logic rst_sys,

    // TX Channel BRAM Interface
    input  logic [DATA_WIDTH-1:0] tx_bram_read_data, // Data from BRAM
    output logic [BRAM_ADDR_WIDTH-1:0] tx_bram_addr,      // Address to read from BRAM
    output logic tx_bram_read_enable,                   // Enable BRAM read

    // TX Channel Endpoint FIFO Interface
    input  logic tx_ep_fifo_full,                       // Endpoint FIFO is full
    output logic [DATA_WIDTH-1:0] tx_ep_fifo_write_data, // Data to write to Endpoint FIFO
    output logic tx_ep_fifo_write_enable,               // Enable write to Endpoint FIFO

    // TX Channel Control/Status Interface
    input  logic tx_start,                              // Signal to begin DMA transfer
    input  logic [BRAM_ADDR_WIDTH-1:0] tx_bram_source_addr, // Starting address in BRAM
    input  logic [15:0] tx_length_bytes,                // Number of bytes to transfer
    output logic tx_busy,                               // DMA transfer is in progress
    output logic tx_done,                               // DMA transfer completed for the current transaction

    // RX Channel Endpoint FIFO Interface
    input  logic [DATA_WIDTH-1:0] rx_ep_fifo_read_data, // Data from RX Endpoint FIFO
    input  logic rx_ep_fifo_empty,                      // RX Endpoint FIFO is empty
    output logic rx_ep_fifo_read_enable,                // Enable read from RX Endpoint FIFO

    // RX Channel BRAM Interface
    output logic [BRAM_ADDR_WIDTH-1:0] rx_bram_write_addr_out, // Address to write to BRAM
    output logic [DATA_WIDTH-1:0] rx_bram_write_data,   // Data to write to BRAM
    output logic rx_bram_write_enable,                  // Enable BRAM write

    // RX Channel Control/Status Interface
    input  logic rx_start,                              // Signal to begin RX DMA transfer
    input  logic [BRAM_ADDR_WIDTH-1:0] rx_bram_dest_addr,   // Starting BRAM address to write to
    input  logic [15:0] rx_length_bytes,                // Number of bytes to transfer
    output logic rx_busy,                               // RX DMA transfer is in progress
    output logic rx_done                                // RX DMA transfer completed
);

  // Internal TX Channel Registers
  logic [BRAM_ADDR_WIDTH-1:0] current_bram_addr_reg;
  logic [15:0] remaining_length_reg;
  logic tx_busy_reg;
  logic tx_done_reg; // Held high for one cycle upon completion

  // For managing BRAM read latency and data path (TX)
  logic tx_bram_read_issued_reg; // Indicates a read was issued in ST_READ_BRAM
  logic [DATA_WIDTH-1:0] data_from_bram_latch_reg; // Latches data from BRAM

  // Internal RX Channel Registers
  logic [BRAM_ADDR_WIDTH-1:0] current_bram_write_addr_reg;
  logic [15:0] rx_remaining_length_reg;
  logic rx_busy_reg;
  logic rx_done_reg; // Held high for one cycle upon completion

  // For managing FIFO read latency and data path (RX)
  logic rx_fifo_read_issued_reg; // Indicates a read was issued in ST_READ_FIFO_RX
  logic [DATA_WIDTH-1:0] data_from_fifo_latch_reg; // Latches data from RX FIFO

  // TX Channel State Machine
  typedef enum logic [1:0] {
    ST_IDLE,
    ST_READ_BRAM, // Issue BRAM read
    ST_WRITE_FIFO // Wait for BRAM data, then write to FIFO
  } tx_state_e;
  tx_state_e current_tx_state, next_tx_state;

  // RX Channel State Machine
  typedef enum logic [1:0] {
    ST_IDLE_RX,
    ST_READ_FIFO_RX, // Issue FIFO Read
    ST_WRITE_BRAM_RX // Wait for FIFO data, then write to BRAM
  } rx_state_e;
  rx_state_e current_rx_state, next_rx_state;


  // Sequential Logic
  always_ff @(posedge clk_sys or posedge rst_sys) begin
    if (rst_sys) begin
      // TX Reset
      current_tx_state <= ST_IDLE;
      tx_busy_reg <= 1'b0;
      tx_done_reg <= 1'b0;
      current_bram_addr_reg <= '0;
      remaining_length_reg <= '0;
      tx_bram_read_issued_reg <= 1'b0;
      data_from_bram_latch_reg <= '0;
    end else begin
      current_tx_state <= next_tx_state;
      tx_done_reg <= 1'b0; // Default: tx_done is a one-cycle pulse

      // State-dependent register updates
      case (next_tx_state) // Use next_tx_state for predictive updates
        ST_IDLE: begin
          tx_bram_read_issued_reg <= 1'b0;
          if (current_tx_state != ST_IDLE) begin // Just finished a transfer
            tx_busy_reg <= 1'b0;
            tx_done_reg <= 1'b1;
          end
          // If tx_start and zero length, it's handled in combinational to pulse done
          if (tx_start && tx_length_bytes == 0 && current_tx_state == ST_IDLE) begin
             tx_busy_reg <= 1'b0; // Not busy for zero length
             tx_done_reg <= 1'b1; // Pulse done
          end
        end

        ST_READ_BRAM: begin
          if (current_tx_state == ST_IDLE) begin // Starting new transfer
            tx_busy_reg <= 1'b1;
            tx_done_reg <= 1'b0; // Clear done when starting
            current_bram_addr_reg <= tx_bram_source_addr;
            remaining_length_reg <= tx_length_bytes;
          end
          tx_bram_read_issued_reg <= 1'b1;
        end

        ST_WRITE_FIFO: begin
          // If a read was just issued, latch the data now (simulating 1 cycle BRAM latency)
          if (tx_bram_read_issued_reg) begin
            data_from_bram_latch_reg <= tx_bram_read_data;
            tx_bram_read_issued_reg <= 1'b0; // Consume the "issued" flag
          end

          // If data is ready (latched) and FIFO is not full, update pointers
          if (!tx_bram_read_issued_reg && !tx_ep_fifo_full) { // Ensure data is from latch, not new read data this cycle
             if (remaining_length_reg > 0) begin // Check if there's data to write
                current_bram_addr_reg <= current_bram_addr_reg + 1;
                remaining_length_reg <= remaining_length_reg - 1;
             end
          }
        end
      endcase
    end
  end

  // Combinational Logic for Next State and Outputs
  always_comb begin
    // Default assignments
    next_tx_state = current_tx_state;
    tx_bram_read_enable = 1'b0;
    tx_ep_fifo_write_enable = 1'b0;

    tx_bram_addr = current_bram_addr_reg;
    tx_ep_fifo_write_data = data_from_bram_latch_reg; // Data to FIFO comes from latch
    tx_busy = tx_busy_reg;
    tx_done = tx_done_reg;

    case (current_tx_state)
      ST_IDLE: begin
        if (tx_start) begin
          if (tx_length_bytes > 0) begin
            next_tx_state = ST_READ_BRAM;
          end else { // Zero-length transfer
            // tx_done is pulsed by FF logic when tx_start & tx_length_bytes == 0
            next_tx_state = ST_IDLE;
          end
        end
      end

      ST_READ_BRAM: begin
        tx_bram_read_enable = 1'b1; // Assert read enable
        next_tx_state = ST_WRITE_FIFO; // Always go to WRITE_FIFO to wait for data
      end

      ST_WRITE_FIFO: begin
        // Data was latched in FF if tx_bram_read_issued_reg was high.
        // Now, tx_bram_read_issued_reg is low (consumed in FF).
        // This means data_from_bram_latch_reg holds the data read in the previous cycle.
        if (!tx_bram_read_issued_reg) begin // Indicates data is latched and ready
            if (!tx_ep_fifo_full) begin
                if (remaining_length_reg > 0) begin // Check if there's data to write (already latched)
                    tx_ep_fifo_write_enable = 1'b1;
                    if (remaining_length_reg == 1) begin // Current write is the last byte
                        next_tx_state = ST_IDLE; // Transition to IDLE after this write
                    end else {
                        next_tx_state = ST_READ_BRAM; // Go read next byte
                    }
                end else { // No more bytes to send, but somehow in ST_WRITE_FIFO without valid remaining_length
                    next_tx_state = ST_IDLE; // Should have been caught by remaining_length_reg == 1
                }
            end else { // FIFO is full, stall
                next_tx_state = ST_WRITE_FIFO; // Retry writing same data from latch
            }
        end else {
            // This case means tx_bram_read_issued_reg is still high, implies we are in the same cycle as ST_READ_BRAM output.
            // Hold state, waiting for data to be latched in FF on next clock edge.
            next_tx_state = ST_WRITE_FIFO;
        }
      end
      default: begin
        next_tx_state = ST_IDLE;
      end
    endcase
  end

endmodule : dma_controller

`endif // DMA_CONTROLLER_SV
