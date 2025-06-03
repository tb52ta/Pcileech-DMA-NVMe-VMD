# usb_serial_emulator.xdc
# Constraints for the USB Serial Emulator project using FT601 interface.
# Based on original constraints from pcileech_fpga project for 75T FPGA.

# --- Clock Constraint for FT601 Clock Input ---
# FT601_CLK, 100MHz. Pin K18.
create_clock -period 10.000 -name ft601_clk_i -waveform {0.000 5.000} [get_ports ft601_clk_i]
set_property PACKAGE_PIN K18 [get_ports ft601_clk_i]
set_property IOSTANDARD LVCMOS33 [get_ports ft601_clk_i]

# --- FT601 Data and Control Pin Assignments and I/O Standards ---
# FT601_DATA[31:0], 32-bit Bi-Directional. Pins various.
set_property PACKAGE_PIN U20 [get_ports {ft601_data_io[0]}]
set_property PACKAGE_PIN R19 [get_ports {ft601_data_io[1]}]
set_property PACKAGE_PIN T20 [get_ports {ft601_data_io[2]}]
set_property PACKAGE_PIN R20 [get_ports {ft601_data_io[3]}]
set_property PACKAGE_PIN P20 [get_ports {ft601_data_io[4]}]
set_property PACKAGE_PIN N20 [get_ports {ft601_data_io[5]}]
set_property PACKAGE_PIN M20 [get_ports {ft601_data_io[6]}]
set_property PACKAGE_PIN L20 [get_ports {ft601_data_io[7]}]
set_property PACKAGE_PIN J20 [get_ports {ft601_data_io[8]}]
set_property PACKAGE_PIN K19 [get_ports {ft601_data_io[9]}]
set_property PACKAGE_PIN H20 [get_ports {ft601_data_io[10]}]
set_property PACKAGE_PIN J19 [get_ports {ft601_data_io[11]}]
set_property PACKAGE_PIN G20 [get_ports {ft601_data_io[12]}]
set_property PACKAGE_PIN H18 [get_ports {ft601_data_io[13]}]
set_property PACKAGE_PIN F20 [get_ports {ft601_data_io[14]}]
set_property PACKAGE_PIN G18 [get_ports {ft601_data_io[15]}]
set_property PACKAGE_PIN D19 [get_ports {ft601_data_io[16]}]
set_property PACKAGE_PIN E18 [get_ports {ft601_data_io[17]}]
set_property PACKAGE_PIN C20 [get_ports {ft601_data_io[18]}]
set_property PACKAGE_PIN D18 [get_ports {ft601_data_io[19]}]
set_property PACKAGE_PIN B20 [get_ports {ft601_data_io[20]}]
set_property PACKAGE_PIN C18 [get_ports {ft601_data_io[21]}]
set_property PACKAGE_PIN A20 [get_ports {ft601_data_io[22]}]
set_property PACKAGE_PIN B18 [get_ports {ft601_data_io[23]}]
set_property PACKAGE_PIN B19 [get_ports {ft601_data_io[24]}]
set_property PACKAGE_PIN C17 [get_ports {ft601_data_io[25]}]
set_property PACKAGE_PIN A19 [get_ports {ft601_data_io[26]}]
set_property PACKAGE_PIN B17 [get_ports {ft601_data_io[27]}]
set_property PACKAGE_PIN A18 [get_ports {ft601_data_io[28]}]
set_property PACKAGE_PIN A17 [get_ports {ft601_data_io[29]}]
set_property PACKAGE_PIN A16 [get_ports {ft601_data_io[30]}]
set_property PACKAGE_PIN A15 [get_ports {ft601_data_io[31]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_data_io[*]}]
set_property SLEW FAST [get_ports {ft601_data_io[*]}]

# FT601_BE[3:0], 4-bit Output. Pins K17,J18,J17,H17. (renamed to ft601_be_o)
set_property PACKAGE_PIN K17 [get_ports {ft601_be_o[0]}]
set_property PACKAGE_PIN J18 [get_ports {ft601_be_o[1]}]
set_property PACKAGE_PIN J17 [get_ports {ft601_be_o[2]}]
set_property PACKAGE_PIN H17 [get_ports {ft601_be_o[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_be_o[*]}]
set_property SLEW FAST [get_ports {ft601_be_o[*]}]

# FT601_OE_N, Output. Pin L17. (renamed to ft601_oe_n_o)
set_property PACKAGE_PIN L17 [get_ports ft601_oe_n_o]
set_property IOSTANDARD LVCMOS33 [get_ports ft601_oe_n_o]
set_property SLEW FAST [get_ports ft601_oe_n_o]

# FT601_RD_N, Output. Pin M18. (renamed to ft601_rd_n_o)
set_property PACKAGE_PIN M18 [get_ports ft601_rd_n_o]
set_property IOSTANDARD LVCMOS33 [get_ports ft601_rd_n_o]
set_property SLEW FAST [get_ports ft601_rd_n_o]

# FT601_WR_N, Output. Pin M19. (renamed to ft601_wr_n_o)
set_property PACKAGE_PIN M19 [get_ports ft601_wr_n_o]
set_property IOSTANDARD LVCMOS33 [get_ports ft601_wr_n_o]
set_property SLEW FAST [get_ports ft601_wr_n_o]

# FT601_RXF_N, Input. Pin L19. (renamed to ft601_rxf_n_i)
set_property PACKAGE_PIN L19 [get_ports ft601_rxf_n_i]
set_property IOSTANDARD LVCMOS33 [get_ports ft601_rxf_n_i]
set_property SLEW FAST [get_ports ft601_rxf_n_i]

# FT601_TXE_N, Input. Pin K16. (renamed to ft601_txe_n_i)
set_property PACKAGE_PIN K16 [get_ports ft601_txe_n_i]
set_property IOSTANDARD LVCMOS33 [get_ports ft601_txe_n_i]
set_property SLEW FAST [get_ports ft601_txe_n_i]

# FT601_SIWU_N, Output. Pin AB18. (renamed to ft601_siwu_n_o)
set_property PACKAGE_PIN AB18 [get_ports ft601_siwu_n_o]
set_property IOSTANDARD LVCMOS33 [get_ports ft601_siwu_n_o]
set_property SLEW FAST [get_ports ft601_siwu_n_o]


# --- FT601 Timing Constraints (Input/Output Delays) ---
# These values are from pcileech_captain_75T.xdc / src/75immt.xdc
# Input Delays (data from FT601 to FPGA)
set_input_delay -clock [get_clocks ft601_clk_i] -min 6.5 [get_ports {ft601_data_io[*]}]
set_input_delay -clock [get_clocks ft601_clk_i] -max 7.0 [get_ports {ft601_data_io[*]}]
set_input_delay -clock [get_clocks ft601_clk_i] -min 6.5 [get_ports ft601_rxf_n_i]
set_input_delay -clock [get_clocks ft601_clk_i] -max 7.0 [get_ports ft601_rxf_n_i]
set_input_delay -clock [get_clocks ft601_clk_i] -min 6.5 [get_ports ft601_txe_n_i]
set_input_delay -clock [get_clocks ft601_clk_i] -max 7.0 [get_ports ft601_txe_n_i]

# Output Delays (data from FPGA to FT601)
# The -min 4.8 value is unusual. Typically, min output delay is negative, specifying hold time for the receiver.
# This means the output must be stable (not changing) for at least 4.8ns *after* the clock edge.
# This might be specific to FT601 requirements or a particular way of constraining.
set_output_delay -clock [get_clocks ft601_clk_i] -max 1.0 [get_ports {ft601_oe_n_o ft601_rd_n_o ft601_wr_n_o}]
set_output_delay -clock [get_clocks ft601_clk_i] -min 4.8 [get_ports {ft601_oe_n_o ft601_rd_n_o ft601_wr_n_o}]
set_output_delay -clock [get_clocks ft601_clk_i] -max 1.0 [get_ports {ft601_be_o[*]}]
set_output_delay -clock [get_clocks ft601_clk_i] -min 4.8 [get_ports {ft601_be_o[*]}]
set_output_delay -clock [get_clocks ft601_clk_i] -max 1.0 [get_ports {ft601_data_io[*]}]
set_output_delay -clock [get_clocks ft601_clk_i] -min 4.8 [get_ports {ft601_data_io[*]}]
set_output_delay -clock [get_clocks ft601_clk_i] -max 1.0 [get_ports ft601_siwu_n_o]
set_output_delay -clock [get_clocks ft601_clk_i] -min 4.8 [get_ports ft601_siwu_n_o]


# --- User I/O (Commented out, not used in current usb_serial_top.sv) ---
# set_property PACKAGE_PIN Y18  [get_ports user_led1_n]
# set_property IOSTANDARD LVCMOS33 [get_ports user_led1_n]
# set_property PACKAGE_PIN Y19  [get_ports user_led2_n]
# set_property IOSTANDARD LVCMOS33 [get_ports user_led2_n]
# set_property PACKAGE_PIN W18  [get_ports user_sw1_n]
# set_property IOSTANDARD LVCMOS33 [get_ports user_sw1_n]
# set_property PULLUP true [get_ports user_sw1_n]
# set_property PACKAGE_PIN W19  [get_ports user_sw2_n]
# set_property IOSTANDARD LVCMOS33 [get_ports user_sw2_n]
# set_property PULLUP true [get_ports user_sw2_n]


# --- FPGA Configuration Constraints ---
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design] ;# FTDI requires this
set_property BITSTREAM.CONFIG.CONFIGRATE 66 [current_design]    ;# Max speed for Artix-7


# --- IOB Properties for FT601 Interface (adapted for new hierarchy) ---
# These force related FFs into IOBs for better timing with the FT601.
# Path is usb_serial_top -> ft601_inst (pcileech_ft601) -> internal registers
set_property IOB TRUE [get_cells -hierarchical -filter {NAME =~ *ft601_inst/FT601_DATA_reg[*]}]
set_property IOB TRUE [get_cells -hierarchical -filter {NAME =~ *ft601_inst/FT601_BE_reg[*]}]
set_property IOB TRUE [get_cells -hierarchical -filter {NAME =~ *ft601_inst/oe_reg}]
set_property IOB TRUE [get_cells -hierarchical -filter {NAME =~ *ft601_inst/rd_reg}]
set_property IOB TRUE [get_cells -hierarchical -filter {NAME =~ *ft601_inst/wr_reg}]
# Input path registers in pcileech_ft601 might also benefit if they exist and are directly connected to pads.
# Example (if such registers exist directly at the input boundary of pcileech_ft601):
# set_property IOB TRUE [get_cells -hierarchical -filter {NAME =~ *ft601_inst/rxf_n_reg}] ; # Assuming such a register
# set_property IOB TRUE [get_cells -hierarchical -filter {NAME =~ *ft601_inst/txe_n_reg}] ; # Assuming such a register


# --- Multicycle Path Constraints (Example, needs review for current design) ---
# The original constraint was for a PCIe design. This needs to be adapted if there are
# known multicycle paths related to the FT601 interface or other parts of this design.
# For now, commenting out the original PCIe specific one.
# set_multicycle_path 2 -from [get_pins i_pcileech_com/i_pcileech_ft601/oe_reg/C] -to [get_pins i_pcileech_com/i_pcileech_ft601/FT601_DATA_reg[0]/CE]
# If ft601_inst/oe_reg to ft601_inst/FT601_DATA_reg path exists and needs MCP:
# set_multicycle_path 2 -from [get_pins ft601_inst/oe_reg/C] -to [get_pins ft601_inst/FT601_DATA_reg[*]/CE]

puts "INFO: FT601 related constraints applied."
