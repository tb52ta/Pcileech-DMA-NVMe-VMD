# USB Serial Port Emulator (FT601-Based)

## 1. Overview

This project implements a USB Full-Speed (FS) serial port emulator using SystemVerilog. It is designed to interface with an external FTDI FT601 SuperSpeed USB3.0 to FIFO bridge chip. The FPGA, under the control of this Verilog core, handles the USB enumeration process, CDC-ACM (Communication Device Class - Abstract Control Model) class-specific requests, and serial data buffering. All USB communication with the host is translated into transactions over the FT601's parallel FIFO-like bus.

When the FT601 is connected to a host computer, and the FPGA is correctly programmed and interacting with the FT601, the host should recognize a CDC-ACM device, typically appearing as a virtual COM port. This allows host applications to send and receive serial data as if connected to a standard USB-to-Serial converter.

The primary goal is to create a synthesizable FPGA core that demonstrates how to manage USB device functionality (specifically CDC-ACM) through an FT601 bridge.

## 2. Features

*   **USB Full-Speed (FS) Device Emulation:** Achieved via the FT601 bridge, which handles the low-level USB FS (or HS/SS, though this core focuses on FS logic) physical layer and protocol. The FPGA core implements the higher-level USB device logic.
*   **CDC-ACM Class Implementation:** Emulates a standard USB serial port.
    *   Handles essential EP0 control transfers: GET_DESCRIPTOR (Device, Configuration, String), SET_ADDRESS, SET_CONFIGURATION.
    *   Supports CDC-ACM specific requests: SET_LINE_CODING, GET_LINE_CODING, SET_CONTROL_LINE_STATE.
*   **Data Transfer via FT601:**
    *   EP0 control transfers are packetized and sent/received over the FT601 FIFO interface.
    *   Bulk IN and Bulk OUT endpoints for serial data transmission and reception are mapped to FT601 FIFO channels.
*   **Interrupt IN Endpoint:** Basic implementation for sending `SERIAL_STATE` notifications, reporting DCD (Data Carrier Detect, derived from DTR) and DSR (Data Set Ready, derived from configuration status) state changes.
*   **DMA-Managed Data Buffering:**
    *   BRAM-based buffers for TX (Application to USB/FT601) and RX (USB/FT601 to Application) data paths.
    *   Dedicated DMA controller to move data between BRAMs and FIFOs that interface with the FT601 adapter.
*   **Modular Design:** Composed of distinct modules for FT601 low-level interface, protocol adaptation, CDC handling, DMA, and application-side buffer management.
*   **Comprehensive Simulation Testbench:** Verifies enumeration, data TX/RX paths (including stress tests), and `SERIAL_STATE` notifications under various conditions, including concurrent operations.

## 3. Modules

The project is structured into several key SystemVerilog modules:

*   **`usb_serial_top.sv`**: The top-level module. It instantiates all other components, including the `pcileech_ft601` interface module, the `ft601_protocol_adapter`, the `cdc_acm_handler`, the `dma_controller`, data FIFOs, and BRAMs. It exposes the physical FT601 pins as its primary I/O.
*   **`pcileech_ft601.sv`**: (Adopted from the PCILeech FPGA project) This module manages the low-level 245 FIFO style parallel bus communication with the FT601 chip. It abstracts the FT601's `DATA[31:0]`, `BE[3:0]`, `RXF_N`, `TXE_N`, `RD_N`, `WR_N`, `OE_N` signals into a simpler data + valid interface for sending and receiving 32-bit words.
*   **`ft601_protocol_adapter.sv`**: A crucial new module that sits between the `pcileech_ft601` module and the USB device logic (`cdc_acm_handler`, bulk FIFOs). It implements a channelized protocol over the 32-bit FT601 data words to:
    *   Demultiplex incoming data from the FT601 into EP0 SETUP packets, EP0 OUT data, or Bulk OUT data based on a channel ID.
    *   Multiplex outgoing data (EP0 IN data, Bulk IN data, Interrupt IN data, EP0 status/stall) onto the FT601, adding appropriate channel IDs.
    *   Manages the flow control for EP0 transactions with the `cdc_acm_handler`.
    *   Arbitrates and transmits `SERIAL_STATE` notifications from `cdc_acm_handler` over the FT601 interface using a dedicated channel ID (`CH_INTR_IN_TO_HOST`).
*   **`cdc_acm_handler.sv`**: Manages USB enumeration and CDC-ACM specific requests for Endpoint 0. Its communication with the "host" (as represented by the FT601) now occurs entirely via the `ft601_protocol_adapter`. It receives SETUP packets and EP0 OUT data from the adapter and provides EP0 IN data to the adapter. It also generates `SERIAL_STATE` notifications upon changes to DTR (affecting DCD) and configuration status (affecting DSR), sending these notifications byte-by-byte to the `ft601_protocol_adapter`.
*   **`dma_controller.sv`**: A simple DMA controller with TX and RX channels.
    *   **TX Channel:** Moves data from the TX BRAM to a Bulk IN FIFO (which is then read by the `ft601_protocol_adapter` for transmission to the host).
    *   **RX Channel:** Moves data from a Bulk OUT FIFO (which is written by the `ft601_protocol_adapter` with data from the host) to the RX BRAM.
*   **`serial_port_application.sv`**: Manages the TX and RX BRAMs from the "application" side. Its role is largely unchanged, but the data it buffers ultimately transits via the FT601 interface. It triggers DMA transfers based on data availability and DTR status (received from `cdc_acm_handler`).
*   **`bram_true_dual_port.sv` (Behavioral, in `usb_serial_top.sv`):** Generic BRAM model for simulation.
*   **`async_fifo.sv` (Behavioral, in `usb_serial_top.sv`):** Generic FIFO model. Since the FT601 clock is now the main system clock, these FIFOs operate synchronously in the current design.

## 4. FT601 FIFO Interface and Protocol
(Section content remains largely the same as previous version, details channel IDs etc.)
*   **Physical FT601 Interface (exposed by `usb_serial_top.sv`):**
    *   `ft601_clk_i`: Clock input from FT601 (typically 100MHz), used as the main system clock.
    *   `ft601_rxf_n_i`: Active low, indicates data is available in FT601's internal RX FIFO (Host to FPGA).
    *   `ft601_txe_n_i`: Active low, indicates FT601's internal TX FIFO has space (FPGA to Host).
    *   `ft601_data_io[31:0]`: Bidirectional 32-bit data bus.
    *   `ft601_be_o[3:0]`: Byte enables for writing to FT601 (FPGA to Host). `pcileech_ft601` manages this.
    *   `ft601_rd_n_o`: Active low, FPGA reads data from FT601.
    *   `ft601_wr_n_o`: Active low, FPGA writes data to FT601.
    *   `ft601_oe_n_o`: Active low, FPGA drives `ft601_data_io` when reading from FT601.
    *   `ft601_siwu_n_o`: Send Immediate / Wake Up (optional, currently tied off).
*   **Internal FIFO-like Interface (from `pcileech_ft601`):**
    *   `dout[31:0]`, `dout_valid`: Data read from FT601 (Host to FPGA).
    *   `din[31:0]`, `din_wr_en`, `din_req_data`: Data written to FT601 (FPGA to Host).
*   **Channelized Protocol (managed by `ft601_protocol_adapter.sv`):**
    *   A simple protocol is defined (see `ft601_protocol_adapter.sv` comments) where the upper bits of the 32-bit FT601 data words are used as a "channel ID" to multiplex different types of USB traffic. Example Channel IDs:
        *   `CH_EP0_SETUP (4'h0)`
        *   `CH_EP0_DATA_OUT_FROM_HOST (4'h1)`
        *   `CH_EP0_DATA_IN_TO_HOST (4'h8)`
        *   `CH_EP0_STATUS_IN_TO_HOST (4'h9)`
        *   `CH_INTR_IN_TO_HOST (4'h5)`: For Interrupt IN data.
        *   `CH_BULK_OUT_FROM_HOST (4'hC)`
        *   `CH_BULK_IN_TO_HOST (4'hD)`
    *   The `ft601_protocol_adapter` is responsible for parsing these channel IDs on incoming data and adding them to outgoing data.

## 5. Clocking

*   **`ft601_clk_i`**: The primary system clock (e.g., 100MHz), provided by the FT601 chip. This clock (`clk_sys`) drives all modules in the FPGA design, including the `cdc_acm_handler`, `dma_controller`, `serial_port_application`, BRAMs, and data FIFOs.
*   **Reset (`rst_sys`):** An external system reset.
*   The data FIFOs between the `ft601_protocol_adapter` and the `dma_controller` are now synchronous, as both sides operate on `clk_sys`.

## 6. Simulation

*   The testbench `sim/tb_usb_serial_top.sv` has been updated to reflect the FT601 interface.
*   It simulates a host interacting with the FT601's FIFO bus by:
    *   Driving `tb_ft601_rxf_n` and `tb_ft601_txe_n` to mimic FT601 FIFO status.
    *   Sending and receiving 32-bit data words on `ft601_data_io` using tasks that model the FT601 read/write strobes.
    *   Using the defined channelized protocol to send SETUP packets and interpret EP0/Bulk/Interrupt data.
*   **Test Capabilities:**
    *   **USB Enumeration:** Verifies basic enumeration sequence (GET_DESCRIPTORs, SET_ADDRESS, SET_CONFIGURATION).
    *   **CDC-ACM Requests:** Tests `SET_LINE_CODING` (including data phase) and `SET_CONTROL_LINE_STATE`.
    *   **Interrupt IN Endpoint:** Verifies `SERIAL_STATE` notifications by simulating DTR changes and checking the received notification content (header, DCD, DSR bits).
    *   **TX Data Path Stress Test:** Sends large volumes of data (e.g., 2KB) from the simulated application to test the TX DMA channel, `serial_port_application` TX buffer management, and `ft601_protocol_adapter` bulk TX handling under sustained load. Data integrity is verified.
    *   **RX Data Path Stress Test:** Simulates the host sending large volumes of data to test the RX DMA channel, `serial_port_application` RX buffer management, and `ft601_protocol_adapter` bulk RX handling. Data integrity is verified in the application layer. This includes tests for single byte, full DMA packet, larger than DMA packet, and back-to-back small transfers.
    *   **Concurrent Data Flow Simulation:** Includes test scenarios where TX bulk, RX bulk, and Interrupt IN data flows are initiated concurrently or are rapidly interleaved. This is achieved by forking multiple producer and consumer tasks in the testbench. This setup aims to stress the arbitration logic within `ft601_protocol_adapter.sv` and test overall system stability under concurrent operations.
*   The testbench uses hierarchical signal access for stimulus and verification where necessary.

## 7. Project Status

The RTL design has been subjected to comprehensive testbench scenarios including enumeration, basic CDC class request handling, interrupt notifications, data path stress tests (TX and RX), and concurrent operations. Further refinements would typically be based on results from more exhaustive simulation runs, formal verification, and ultimately, hardware testing.

## 8. Future Work / TODO

*   **Robust EP0 Handling in Adapter:** Fully implement and test EP0 OUT data phase handling (multi-byte transfers with correct `ep0_out_data_last` signaling) and more robust status phase management (sending/receiving ZLPs, STALL handshake) in `ft601_protocol_adapter.sv`.
*   **Host-Side Application/Driver:** A compatible host-side application is required to communicate with the FPGA via the FT601 using the defined channelized protocol for EP0 and bulk transfers.
*   **Interrupt IN Endpoint Notifications:**
    *   Implement generation and reporting of other `SERIAL_STATE` bits (e.g., break, errors like bOverRun, bParity, bFraming) if corresponding conditions are ever modeled in the DUT.
    *   More comprehensive testing of Interrupt IN endpoint under various conditions (e.g., back-to-back status changes, concurrent with high bulk traffic).
*   **Line Coding Application:** The `cdc_acm_handler` stores line coding parameters; these could be outputted for an actual UART if one were part of the design.
*   **FT601 Configuration/EEPROM:** Consider if any specific FT601 EEPROM configurations are needed (e.g., for device descriptors, though currently handled by FPGA). The `pcileech_ft601` module may assume certain FT601 modes (e.g., 245 FIFO).
*   **Error Handling & Timeouts:** Improve error detection and timeout mechanisms in the `ft601_protocol_adapter` and testbench.
*   **Advanced CDC-ACM Features:** Support for break signalling, carrier control, etc.
*   **Power Management:** Handle USB suspend/resume events (may require FT601 SIWU usage).
*   **FPGA Implementation:**
    *   Replace generic BRAM/FIFO models with FPGA vendor primitives for optimal resource usage and timing.
    *   Develop comprehensive XDC constraints for timing closure.
    *   Test on actual FPGA hardware with an FT601.

## 9. Tools
* Vivado for synthesis and implementation (example build script provided).
* A SystemVerilog simulator for testing.
