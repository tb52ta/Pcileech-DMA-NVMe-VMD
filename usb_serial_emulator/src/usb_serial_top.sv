// usb_serial_top.sv
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`ifndef USB_SERIAL_TOP_SV
`define USB_SERIAL_TOP_SV

// Behavioral model for a True Dual-Port BRAM
module bram_true_dual_port #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 12,
    parameter DEPTH_BYTES = 1 << ADDR_WIDTH
) (
    // Port A
    input clka, ena, wea,
    input [ADDR_WIDTH-1:0] addra,
    input [DATA_WIDTH-1:0] dina,
    output logic [DATA_WIDTH-1:0] douta,

    // Port B
    input clkb, enb, web,
    input [ADDR_WIDTH-1:0] addrb,
    input [DATA_WIDTH-1:0] dinb,
    output logic [DATA_WIDTH-1:0] doutb
);
  // Behavioral model: Write-first behavior
  logic [DATA_WIDTH-1:0] mem [0:DEPTH_BYTES-1];

  always_ff @(posedge clka) begin
    if (ena) begin
      if (wea) begin
        mem[addra] <= dina;
      end
      douta <= wea ? dina : mem[addra]; // Read-through on write
    end
  end

  always_ff @(posedge clkb) begin
    if (enb) begin
      if (web) begin
        mem[addrb] <= dinb;
      end
      doutb <= web ? dinb : mem[addrb]; // Read-through on write
    end
  end
endmodule


// Behavioral model for an Asynchronous FIFO
// This is a very basic model for simulation purposes.
// Proper async FIFO design involves Gray code pointers and CDC synchronization.
module async_fifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH_BITS = 6, // For DEPTH = 2^DEPTH_BITS (e.g., 64)
    parameter DEPTH = 1 << DEPTH_BITS
) (
    // Write Port
    input  logic wr_clk,
    input  logic wr_rst,
    input  logic wr_en,
    input  logic [DATA_WIDTH-1:0] din,
    output logic full,

    // Read Port
    input  logic rd_clk,
    input  logic rd_rst,
    input  logic rd_en,
    output logic [DATA_WIDTH-1:0] dout,
    output logic empty
);

  logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
  logic [DEPTH_BITS:0]   wr_ptr_reg, rd_ptr_reg; // Pointers are one bit wider to detect full/empty easily
  logic [DEPTH_BITS:0]   fill_count_reg;

  // For simulation, we can simplify fill_count update slightly
  // In reality, this needs careful CDC.

  // Write Logic
  always_ff @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst) begin
      wr_ptr_reg <= '0;
    end else if (wr_en && !full) begin
      mem[wr_ptr_reg[DEPTH_BITS-1:0]] <= din;
      wr_ptr_reg <= wr_ptr_reg + 1;
    end
  end

  // Read Logic
  always_ff @(posedge rd_clk or posedge rd_rst) begin
    if (rd_rst) begin
      rd_ptr_reg <= '0;
      dout <= '0; // Default output on reset
    end else if (rd_en && !empty) begin
      dout <= mem[rd_ptr_reg[DEPTH_BITS-1:0]];
      rd_ptr_reg <= rd_ptr_reg + 1;
    end
  end

  // Fill Count and Full/Empty Logic (Simplified for simulation)
  // This part is synchronous to wr_clk for simplicity of this behavioral model,
  // which is not how a real async FIFO's fill count across domains would work.
  // A proper model would use synchronized pointers.
  always_ff @(posedge wr_clk or posedge wr_rst) begin
      if (wr_rst) begin
          fill_count_reg <= '0;
      end else begin
          if (wr_en && !full && !(rd_en && !empty)) begin // Write, no read
              fill_count_reg <= fill_count_reg + 1;
          end else if (! (wr_en && !full) && (rd_en && !empty)) begin // Read, no write
              fill_count_reg <= fill_count_reg - 1;
          end
          // If both write and read, or neither, count stays same.
      end
  end

  // For rd_rst affecting fill_count (if rd_rst is asserted while wr_rst is not)
  always_ff @(posedge rd_clk or posedge rd_rst) begin
    if (rd_rst) begin
        // This is tricky in a simple behavioral model. If rd_rst clears rd_ptr,
        // and wr_clk domain doesn't know, fill_count becomes inaccurate.
        // For this basic simulation model, we assume rst_sys resets both domains
        // for fill_count, or that fill_count is mainly driven by wr_clk domain logic here.
        // If fill_count_reg were updated by rd_clk domain based on rd_ptr,
        // then it would need to be synchronized to wr_clk domain for `full` signal.
    end
  end

  assign full = (fill_count_reg == DEPTH);
  assign empty = (fill_count_reg == 0);

endmodule


module usb_serial_top #(
    parameter BRAM_ADDR_WIDTH = 12, // For App BRAMs (e.g., 4KB)
    parameter APP_DATA_WIDTH = 8,
    parameter DMA_DATA_WIDTH = 8, // DMA controller also uses 8-bit data width
    parameter CDC_FIFO_DEPTH_BITS = 6 // e.g., 64 elements
) (
    // System Interface & FT601 Clock
    input logic ft601_clk_i,   // Clock from FT601, likely becomes the main system clock
    input logic rst_sys,       // System reset

    // FT601 Interface Ports
    input  logic        ft601_rxf_n_i, // RX FIFO Not Empty in FT601 (data available to read)
    input  logic        ft601_txe_n_i, // TX FIFO Not Full in FT601 (space available to write)
    output logic [3:0]  ft601_be_o,    // Byte Enables for FT601 Data (used by pcileech_ft601)
    output logic        ft601_oe_n_o,  // Output Enable for FT601 Data (Active Low, used by pcileech_ft601)
    output logic        ft601_rd_n_o,  // Read Strobe to FT601 (Active Low, used by pcileech_ft601)
    output logic        ft601_wr_n_o,  // Write Strobe to FT601 (Active Low, used by pcileech_ft601)
    output logic        ft601_siwu_n_o,// Send Immediate / Wake Up (Active Low, optional)
    inout  logic [31:0] ft601_data_io  // Bidirectional Data Bus with FT601
);

  // --- Internal Clocks and Resets ---
  logic clk_sys; // System clock, derived from ft601_clk_i
  // rst_sys is used directly

  assign clk_sys = ft601_clk_i; // FT601 clock is now the system clock

  // For FIFOs that were previously async, clk_usb and rst_usb will now be clk_sys and rst_sys
  // Retain clk_usb and rst_usb for clarity in existing module instantiations, but they are now synchronous.
  logic clk_usb;
  logic rst_usb;
  assign clk_usb = clk_sys;
  assign rst_usb = rst_sys;


  // --- Wires for Inter-Module Connections ---

  // FT601 Interface (pcileech_ft601 instance outputs)
  logic [31:0] ft601_dout_w;          // Data out from FT601 (FPGA RX path)
  logic        ft601_dout_valid_w;    // Valid signal for ft601_dout_w
  // FT601 Interface (pcileech_ft601 instance inputs)
  logic [31:0] ft601_din_w;           // Data in to FT601 (FPGA TX path)
  logic        ft601_din_wr_en_w;     // Write enable for ft601_din_w (from our logic to pcileech_ft601)
  logic        ft601_din_req_data_w;  // pcileech_ft601 requests data to send (from pcileech_ft601 to our logic)


  // CDC ACM Handler EP0 signals (will be tied off or need routing logic via FT601)
  logic        ep0_data_tx_valid_from_cdc;
  logic [7:0]  ep0_data_tx_from_cdc;
  logic        ep0_data_tx_last_from_cdc;
  logic        ep0_stall_from_cdc;
  logic        ep0_ack_to_cdc;
  logic        setup_packet_valid_to_cdc;
  logic [63:0] setup_packet_data_to_cdc;
  logic        ep0_data_tx_ready_to_cdc;

  // CDC ACM Handler DTR output
  logic dtr_active_from_cdc; // This remains relevant

  // Serial Port Application <-> TX BRAM
  logic [BRAM_ADDR_WIDTH-1:0] app_tx_bram_addr_to_bram;
  logic [APP_DATA_WIDTH-1:0]  app_tx_bram_din_to_bram;
  logic                       app_tx_bram_wen_to_bram;
  logic [APP_DATA_WIDTH-1:0]  dma_tx_bram_dout_from_bram; // This is Port B Dout of TX BRAM

  // Serial Port Application <-> RX BRAM
  logic [BRAM_ADDR_WIDTH-1:0] app_rx_bram_addr_to_bram;
  logic [APP_DATA_WIDTH-1:0]  app_rx_bram_dout_from_bram; // This is Port B Dout of RX BRAM
  logic                       app_rx_bram_en_to_bram;
  // DMA writes to RX BRAM Port A are dma_rx_bram_addr, dma_rx_bram_din, dma_rx_bram_wen from DMA controller

  // Serial Port Application <-> DMA Controller
  logic dma_tx_busy_from_dma;
  logic dma_tx_done_from_dma;
  logic dma_rx_busy_from_dma;
  logic dma_rx_done_from_dma;
  logic dma_tx_start_to_dma;
  logic [BRAM_ADDR_WIDTH-1:0] dma_tx_bram_start_addr_to_dma;
  logic [15:0] dma_tx_transfer_length_to_dma;
  logic dma_rx_start_to_dma;
  logic [BRAM_ADDR_WIDTH-1:0] dma_rx_bram_start_addr_to_dma;
  logic [15:0] dma_rx_transfer_length_to_dma;

  // DMA Controller <-> TX BRAM (Port B of TX BRAM)
  logic [BRAM_ADDR_WIDTH-1:0] dma_tx_bram_addr_to_bram_portb; // From DMA
  logic                       dma_tx_bram_ren_to_bram_portb;  // From DMA

  // DMA Controller <-> RX BRAM (Port A of RX BRAM)
  logic [BRAM_ADDR_WIDTH-1:0] dma_rx_bram_addr_to_bram_porta; // From DMA
  logic [DMA_DATA_WIDTH-1:0]  dma_rx_bram_din_to_bram_porta;  // From DMA
  logic                       dma_rx_bram_wen_to_bram_porta;  // From DMA

  // DMA Controller <-> Bulk OUT FIFO (RX Path)
  logic [DMA_DATA_WIDTH-1:0] bulk_out_data_from_fifo;
  logic                      bulk_out_fifo_empty;
  logic                      dma_rx_fifo_read_enable_to_fifo;

  // DMA Controller <-> Bulk IN FIFO (TX Path)
  logic [DMA_DATA_WIDTH-1:0] dma_tx_data_to_fifo;
  logic                      bulk_in_fifo_full;
  logic                      dma_tx_fifo_write_enable_to_fifo;

  // Conceptual SIE <-> Bulk OUT FIFO (RX Path) -> Now FT601 dout -> FIFO
  // logic [APP_DATA_WIDTH-1:0] bulk_out_data_from_sie; // Replaced by ft601_dout_w (or part of it)
  // logic                      bulk_out_valid_from_sie;  // Replaced by ft601_dout_valid_w
  logic                      bulk_out_fifo_full_to_ft601; // Feedback to FT601 source (implicitly via ft601_rd_n_o)

  // Conceptual SIE <-> Bulk IN FIFO (TX Path) -> Now FIFO -> FT601 din
  // logic [APP_DATA_WIDTH-1:0] bulk_in_data_to_sie; // Replaced by ft601_din_w via adapter
  logic                      bulk_in_fifo_empty_from_fifo_to_adapter_wire; // Renamed wire
  // logic                      bulk_in_ready_from_sie; // Replaced by FT601 signals + adapter logic

  // --- FT601 Protocol Adapter Wires ---
  // Adapter -> pcileech_ft601 (din path)
  logic [FT601_DATA_WIDTH-1:0] adapter_to_ft601_din_w;
  logic                        adapter_to_ft601_din_wr_en_w;

  // CDC EP0 path: Adapter -> cdc_acm_handler
  // setup_packet_valid_to_cdc, setup_packet_data_to_cdc, ep0_data_tx_ready_to_cdc are already declared
  // ep0_ack_to_cdc is also declared (this is adapter's output to cdc for host's IN status ack)
  // Wires for EP0 OUT data from Adapter to CDC Handler
  logic                        ep0_rx_data_valid_to_cdc_from_adapter_wire;
  logic [APP_DATA_WIDTH-1:0]   ep0_rx_data_to_cdc_from_adapter_wire;
  logic                        ep0_rx_data_last_to_cdc_from_adapter_wire;

  // CDC EP0 path: cdc_acm_handler -> Adapter
  // ep0_data_tx_valid_from_cdc, ep0_data_tx_from_cdc, ep0_data_tx_last_from_cdc, ep0_stall_from_cdc are declared
  logic                        ep0_ack_from_cdc_to_adapter_wire; // cdc_acm_handler's general ACK, input to adapter
  logic                        ep0_data_rx_ready_from_cdc_to_adapter_wire; // cdc_acm_handler ready for EP0 OUT data

  // Bulk OUT path: Adapter -> Bulk OUT FIFO
  logic [APP_DATA_WIDTH-1:0]   adapter_to_bulk_out_fifo_din_w;
  logic                        adapter_to_bulk_out_fifo_wr_en_w;

  // Bulk IN path: Bulk IN FIFO -> Adapter
  logic [APP_DATA_WIDTH-1:0]   bulk_in_fifo_dout_to_adapter_w;
  logic                        adapter_to_bulk_in_fifo_rd_en_w;


  // --- Instantiate pcileech_ft601 ---
  // This module handles the FT601 protocol and presents a simpler FIFO-like interface.
  // We assume APP_DATA_WIDTH (8-bit) for the data path through FIFOs.
  // pcileech_ft601 internally handles the 32-bit FT601_DATA bus and byte enables.
  // For this integration, we will assume pcileech_ft601 provides/consumes 8-bit data
  // on its dout/din ports for simplicity, or we use only one byte of its 32-bit interface.
  // For now, let's assume its dout/din are 32-bit and we connect to the lower 8 bits.
  // (* keep_hierarchy = "yes" *) // Synthesis attribute if needed
  pcileech_ft601 ft601_inst (
      .clk(clk_sys), // Assuming pcileech_ft601 runs on the same clock as our system
      .rst(rst_sys),

      // FT601 Physical Interface
      .FT601_DATA(ft601_data_io),
      .FT601_BE(ft601_be_o), // Byte enables for 32-bit bus
      .FT601_RXF_N(ft601_rxf_n_i),
      .FT601_TXE_N(ft601_txe_n_i),
      .FT601_WR_N(ft601_wr_n_o),
      .FT601_RD_N(ft601_rd_n_o),
      .FT601_OE_N(ft601_oe_n_o),
      .FT601_SIWU_N(ft601_siwu_n_o),

      // FIFO-like interface from pcileech_ft601
      .dout(ft601_dout_w),             // Data received from host (FPGA RX)
      .dout_valid(ft601_dout_valid_w), // Valid for dout
      .din(ft601_din_w),               // Data to send to host (FPGA TX)
      .din_wr_en(ft601_din_wr_en_w),   // Write enable for din (from our logic)
      .din_req_data(ft601_din_req_data_w) // pcileech_ft601 is requesting data to send
  );
  // Note: ft601_be_o will need to be driven correctly if using 32-bit wide FIFOs.
  // For 8-bit data path through our system, we'd typically use only one BE.
  // If ft601_din_w/ft601_dout_w are 32-bit, we will use ft601_din_w[7:0] and ft601_dout_w[7:0].

  // --- Instantiate BRAMs ---
  // TX BRAM: App writes on Port A, DMA reads on Port B
  bram_true_dual_port #(
      .DATA_WIDTH(APP_DATA_WIDTH),
      .ADDR_WIDTH(BRAM_ADDR_WIDTH)
  ) tx_bram_inst (
      // Port A (Application Writes) - clk_sys
      .clka(clk_sys),
      .ena(1'b1),
      .wea(app_tx_bram_wen_to_bram),
      .addra(app_tx_bram_addr_to_bram),
      .dina(app_tx_bram_din_to_bram),
      .douta(),
      // Port B (DMA Reads) - clk_sys
      .clkb(clk_sys),
      .enb(dma_tx_bram_ren_to_bram_portb),
      .web(1'b0),
      .addrb(dma_tx_bram_addr_to_bram_portb),
      .dinb('0),
      .doutb(dma_tx_bram_dout_from_bram) // To DMA Controller
  );

  // RX BRAM: DMA writes on Port A, App reads on Port B
  bram_true_dual_port #(
      .DATA_WIDTH(APP_DATA_WIDTH),
      .ADDR_WIDTH(BRAM_ADDR_WIDTH)
  ) rx_bram_inst (
      // Port A (DMA Writes) - clk_sys
      .clka(clk_sys),
      .ena(1'b1),
      .wea(dma_rx_bram_wen_to_bram_porta),
      .addra(dma_rx_bram_addr_to_bram_porta),
      .dina(dma_rx_bram_din_to_bram_porta),
      .douta(),
      // Port B (Application Reads) - clk_sys
      .clkb(clk_sys),
      .enb(app_rx_bram_en_to_bram),
      .web(1'b0),
      .addrb(app_rx_bram_addr_to_bram),
      .dinb('0),
      .doutb(app_rx_bram_dout_from_bram) // To Serial Port App
  );

  // --- Instantiate Data Path FIFOs (now synchronous as clk_usb = clk_sys) ---
  // Bulk OUT FIFO (FT601 RX -> DMA RX)
  // Data from FT601 (ft601_dout_w) is 32-bit.
  async_fifo #(
      .DATA_WIDTH(APP_DATA_WIDTH),
      .DEPTH_BITS(CDC_FIFO_DEPTH_BITS)
  ) ep_bulk_out_fifo_inst (
      .wr_clk(clk_sys),
      .wr_rst(rst_sys),
      .wr_en(adapter_to_bulk_out_fifo_wr_en_w), // From Adapter
      .din(adapter_to_bulk_out_fifo_din_w),     // From Adapter
      .full(bulk_out_fifo_full_to_ft601),
      .rd_clk(clk_sys),
      .rd_rst(rst_sys),
      .rd_en(dma_rx_fifo_read_enable_to_fifo), // From DMA
      .dout(bulk_out_data_from_fifo),          // To DMA
      .empty(bulk_out_fifo_empty)             // To DMA
  );

  // Bulk IN FIFO (DMA TX -> Adapter -> FT601 TX)
  // Data to FT601 (ft601_din_w) is 32-bit.
  async_fifo #(
      .DATA_WIDTH(APP_DATA_WIDTH),
      .DEPTH_BITS(CDC_FIFO_DEPTH_BITS)
  ) ep_bulk_in_fifo_inst (
      .wr_clk(clk_sys),
      .wr_rst(rst_sys),
      .wr_en(dma_tx_fifo_write_enable_to_fifo), // From DMA
      .din(dma_tx_data_to_fifo),                // From DMA
      .full(bulk_in_fifo_full),                 // To DMA
      .rd_clk(clk_sys),
      .rd_rst(rst_sys),
      .rd_en(adapter_to_bulk_in_fifo_rd_en_w),   // From Adapter
      .dout(bulk_in_fifo_dout_to_adapter_w),     // To Adapter
      .empty(bulk_in_fifo_empty_from_fifo_to_adapter_wire) // To Adapter
  );


  // --- Instantiate FT601 Protocol Adapter ---
  ft601_protocol_adapter #(
      .FT601_DATA_WIDTH(32),
      .APP_DATA_WIDTH(APP_DATA_WIDTH)
  ) ft601_adapter_inst (
      .clk_sys(clk_sys),
      .rst_sys(rst_sys),
      // FT601 side
      .ft601_if_dout(ft601_dout_w),
      .ft601_if_dout_valid(ft601_dout_valid_w),
      .ft601_if_din_req_data(ft601_din_req_data_w),
      .ft601_if_din(adapter_to_ft601_din_w),
      .ft601_if_din_wr_en(adapter_to_ft601_din_wr_en_w),
      // CDC EP0 side
      .ep0_setup_packet_valid(setup_packet_valid_to_cdc),
      .ep0_setup_packet_data(setup_packet_data_to_cdc),
      .ep0_data_tx_ready(ep0_data_tx_ready_to_cdc),
      .ep0_in_ack_received(ep0_ack_to_cdc),
      .ep0_out_data_available(ep0_rx_data_valid_to_cdc_from_adapter_wire),
      .ep0_out_data(ep0_rx_data_to_cdc_from_adapter_wire),
      .ep0_out_data_last(ep0_rx_data_last_to_cdc_from_adapter_wire),
      .ep0_data_tx(ep0_data_tx_from_cdc),
      .ep0_data_tx_valid(ep0_data_tx_valid_from_cdc),
      .ep0_data_tx_last(ep0_data_tx_last_from_cdc),
      .ep0_stall(ep0_stall_from_cdc),
      .ep0_ack(ep0_ack_from_cdc_to_adapter_wire),
      .ep0_data_rx_ready_from_cdc(ep0_data_rx_ready_from_cdc_to_adapter_wire),
      // Bulk OUT FIFO side
      .bulk_out_din(adapter_to_bulk_out_fifo_din_w),
      .bulk_out_wr_en(adapter_to_bulk_out_fifo_wr_en_w),
      // Bulk IN FIFO side
      .bulk_in_dout(bulk_in_fifo_dout_to_adapter_w),
      .bulk_in_empty(bulk_in_fifo_empty_from_fifo_to_adapter_wire),
      .bulk_in_rd_en(adapter_to_bulk_in_fifo_rd_en_w)
  );
  // Connect adapter outputs to pcileech_ft601 inputs
  assign ft601_din_w = adapter_to_ft601_din_w;
  assign ft601_din_wr_en_w = adapter_to_ft601_din_wr_en_w;


  // --- Instantiate Sub-Modules ---
  cdc_acm_handler cdc_acm_handler_inst (
      .clk(clk_usb), // Retaining clk_usb for cdc_acm_handler as it was before
      .rst(rst_usb), // Retaining rst_usb for cdc_acm_handler
      .setup_packet_valid(setup_packet_valid_to_cdc),
      .setup_packet_data(setup_packet_data_to_cdc),
      .ep0_data_tx_valid(ep0_data_tx_valid_from_cdc),
      .ep0_data_tx(ep0_data_tx_from_cdc),
      .ep0_data_tx_last(ep0_data_tx_last_from_cdc),
      .ep0_data_tx_ready(ep0_data_tx_ready_to_cdc),
      .ep0_stall(ep0_stall_from_cdc),
      .ep0_ack(ep0_ack_from_cdc_to_adapter_wire), // cdc_acm_handler's output ack, input to adapter
      // EP0 OUT Data Path from Adapter
      .ep0_data_rx_valid_from_adapter(ep0_rx_data_valid_to_cdc_from_adapter_wire),
      .ep0_data_rx_from_adapter(ep0_rx_data_to_cdc_from_adapter_wire),
      .ep0_data_rx_ready_from_cdc(ep0_data_rx_ready_from_cdc_to_adapter_wire), // Output from CDC, input to adapter
      // Control Line State Outputs
      .dtr_active_o(dtr_active_from_cdc), // Changed from .dtr_active
      .rts_active_o(rts_from_cdc_w)       // New port
  );

  dma_controller #(
      .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH),
      .DATA_WIDTH(DMA_DATA_WIDTH)
  ) dma_controller_inst (
      .clk_sys(clk_sys),
      .rst_sys(rst_sys),
      // TX Channel (BRAM -> FIFO)
      .tx_bram_read_data(dma_tx_bram_dout_from_bram),
      .tx_bram_addr(dma_tx_bram_addr_to_bram_portb),
      .tx_bram_read_enable(dma_tx_bram_ren_to_bram_portb),
      .tx_ep_fifo_full(bulk_in_fifo_full),
      .tx_ep_fifo_write_data(dma_tx_data_to_fifo),
      .tx_ep_fifo_write_enable(dma_tx_fifo_write_enable_to_fifo),
      .tx_start(dma_tx_start_to_dma),
      .tx_bram_source_addr(dma_tx_bram_start_addr_to_dma),
      .tx_length_bytes(dma_tx_transfer_length_to_dma),
      .tx_busy(dma_tx_busy_from_dma),
      .tx_done(dma_tx_done_from_dma),
      // RX Channel (FIFO -> BRAM)
      .rx_ep_fifo_read_data(bulk_out_data_from_fifo),
      .rx_ep_fifo_empty(bulk_out_fifo_empty),
      .rx_ep_fifo_read_enable(dma_rx_fifo_read_enable_to_fifo),
      .rx_bram_write_addr_out(dma_rx_bram_addr_to_bram_porta),
      .rx_bram_write_data(dma_rx_bram_din_to_bram_porta),
      .rx_bram_write_enable(dma_rx_bram_wen_to_bram_porta),
      .rx_start(dma_rx_start_to_dma),
      .rx_bram_dest_addr(dma_rx_bram_start_addr_to_dma),
      .rx_length_bytes(dma_rx_transfer_length_to_dma),
      .rx_busy(dma_rx_busy_from_dma),
      .rx_done(dma_rx_done_from_dma)
  );

  serial_port_application #(
      .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH),
      .DATA_WIDTH(APP_DATA_WIDTH),
      .MAX_DMA_TRANSFER_LEN(64)
  ) serial_port_application_inst (
      .clk_sys(clk_sys),
      .rst_sys(rst_sys),
      // App TX BRAM Port A (App Writes)
      .app_tx_bram_addr_o(app_tx_bram_addr_to_bram),
      .app_tx_bram_din_o(app_tx_bram_din_to_bram),
      .app_tx_bram_wen_o(app_tx_bram_wen_to_bram),
      .dma_tx_bram_dout_i(dma_tx_bram_dout_from_bram),
      // App RX BRAM Port B (App Reads)
      .app_rx_bram_addr_o(app_rx_bram_addr_to_bram),
      .app_rx_bram_dout_i(app_rx_bram_dout_from_bram),
      .app_rx_bram_en_o(app_rx_bram_en_to_bram),
      // Application Side (Data In/Out) - Tied off for now
      .app_tx_byte_in('0'),
      .app_tx_byte_valid(1'b0),
      .app_tx_buffer_full(),
      .app_rx_byte_out(),
      .app_rx_byte_available(),
      .app_rx_byte_read(1'b0),
      .dma_tx_busy(dma_tx_busy_from_dma),
      .dma_tx_done(dma_tx_done_from_dma),
      .dma_rx_busy(dma_rx_busy_from_dma),
      .dma_rx_done(dma_rx_done_from_dma),
      .dma_tx_start(dma_tx_start_to_dma),
      .dma_tx_bram_start_addr(dma_tx_bram_start_addr_to_dma),
      .dma_tx_transfer_length(dma_tx_transfer_length_to_dma),
      .dma_rx_start(dma_rx_start_to_dma),
      .dma_rx_bram_start_addr(dma_rx_bram_start_addr_to_dma),
      .dma_rx_transfer_length(dma_rx_transfer_length_to_dma),
      // CDC Control Signals
      .dtr_active(dtr_active_from_cdc) // This should be dtr_from_cdc_w if that wire is used
  );

  // EP0 related signals are now connected to/from ft601_adapter_inst.
  // The adapter is responsible for the protocol over FT601 for these.

  // The direct assignment of ft601_din_wr_en_w based on bulk FIFO status is removed.
  // It's now controlled by the adapter: adapter_to_ft601_din_wr_en_w.

  // Tie off SIWU (Send Immediate Wake Up) for now, can be controlled by adapter if needed.
  assign ft601_siwu_n_o = 1'b1;

endmodule : usb_serial_top
`endif // USB_SERIAL_TOP_SV
  );

  dma_controller #(
      .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH),
      .DATA_WIDTH(DMA_DATA_WIDTH)
  ) dma_controller_inst (
      .clk_sys(clk_sys),
      .rst_sys(rst_sys),
      // TX Channel (BRAM -> FIFO)
      .tx_bram_read_data(dma_tx_bram_dout_from_bram),
      .tx_bram_addr(dma_tx_bram_addr_to_bram_portb),
      .tx_bram_read_enable(dma_tx_bram_ren_to_bram_portb),
      .tx_ep_fifo_full(bulk_in_fifo_full),
      .tx_ep_fifo_write_data(dma_tx_data_to_fifo),
      .tx_ep_fifo_write_enable(dma_tx_fifo_write_enable_to_fifo),
      .tx_start(dma_tx_start_to_dma),
      .tx_bram_source_addr(dma_tx_bram_start_addr_to_dma),
      .tx_length_bytes(dma_tx_transfer_length_to_dma),
      .tx_busy(dma_tx_busy_from_dma),
      .tx_done(dma_tx_done_from_dma),
      // RX Channel (FIFO -> BRAM)
      .rx_ep_fifo_read_data(bulk_out_data_from_fifo),
      .rx_ep_fifo_empty(bulk_out_fifo_empty),
      .rx_ep_fifo_read_enable(dma_rx_fifo_read_enable_to_fifo),
      .rx_bram_write_addr_out(dma_rx_bram_addr_to_bram_porta),
      .rx_bram_write_data(dma_rx_bram_din_to_bram_porta),
      .rx_bram_write_enable(dma_rx_bram_wen_to_bram_porta),
      .rx_start(dma_rx_start_to_dma),
      .rx_bram_dest_addr(dma_rx_bram_start_addr_to_dma),
      .rx_length_bytes(dma_rx_transfer_length_to_dma),
      .rx_busy(dma_rx_busy_from_dma),
      .rx_done(dma_rx_done_from_dma)
  );

  serial_port_application #(
      .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH),
      .DATA_WIDTH(APP_DATA_WIDTH),
      .MAX_DMA_TRANSFER_LEN(64)
  ) serial_port_application_inst (
      .clk_sys(clk_sys),
      .rst_sys(rst_sys),
      // App TX BRAM Port A (App Writes)
      .app_tx_bram_addr_o(app_tx_bram_addr_to_bram),
      .app_tx_bram_din_o(app_tx_bram_din_to_bram),
      .app_tx_bram_wen_o(app_tx_bram_wen_to_bram),
      .dma_tx_bram_dout_i(dma_tx_bram_dout_from_bram),
      // App RX BRAM Port B (App Reads)
      .app_rx_bram_addr_o(app_rx_bram_addr_to_bram),
      .app_rx_bram_dout_i(app_rx_bram_dout_from_bram),
      .app_rx_bram_en_o(app_rx_bram_en_to_bram),
      // Application Side (Data In/Out) - Tied off for now
      .app_tx_byte_in('0'),
      .app_tx_byte_valid(1'b0),
      .app_tx_buffer_full(),
      .app_rx_byte_out(),
      .app_rx_byte_available(),
      .app_rx_byte_read(1'b0),
      .dma_tx_busy(dma_tx_busy_from_dma),
      .dma_tx_done(dma_tx_done_from_dma),
      .dma_rx_busy(dma_rx_busy_from_dma),
      .dma_rx_done(dma_rx_done_from_dma),
      .dma_tx_start(dma_tx_start_to_dma),
      .dma_tx_bram_start_addr(dma_tx_bram_start_addr_to_dma),
      .dma_tx_transfer_length(dma_tx_transfer_length_to_dma),
      .dma_rx_start(dma_rx_start_to_dma),
      .dma_rx_bram_start_addr(dma_rx_bram_start_addr_to_dma),
      .dma_rx_transfer_length(dma_rx_transfer_length_to_dma),
      // CDC Control Signals
      .dtr_active(dtr_active_from_cdc)
  );

  // --- Conceptual SIE/PHY connections (tie-offs for now) ---
  assign setup_packet_valid_to_cdc = 1'b0;
  assign setup_packet_data_to_cdc = 64'b0;
  assign ep0_data_tx_ready_to_cdc = 1'b1;
  assign ep0_ack_to_cdc = 1'b0;

  assign bulk_out_data_from_sie = '0;
  assign bulk_out_valid_from_sie = 1'b0;

  assign bulk_in_ready_from_sie = 1'b1;

  assign usb_pullup_en_o = dtr_active_from_cdc;

  assign usb_dp_o = 1'b0;
  assign usb_dn_o = 1'b0;

endmodule : usb_serial_top
`endif // USB_SERIAL_TOP_SV
