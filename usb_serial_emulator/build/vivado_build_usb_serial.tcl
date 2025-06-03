# vivado_build_usb_serial.tcl
#
# This script creates a Vivado project for the USB Serial Emulator.
# It adds source files, constraints, and sets the top module.
# Synthesis, implementation, and bitstream generation steps are
# included but commented out. They can be run manually in the Vivado GUI
# or by uncommenting the relevant lines in this script.
#
# To run this script:
# 1. Open Vivado.
# 2. In the Tcl Console, navigate to the 'build' directory of this project.
#    cd /path/to/your/usb_serial_emulator/build
# 3. Source this script:
#    source ./vivado_build_usb_serial.tcl

# --- Project Setup ---
set P_FPGA_PART "xc7a75tfgg484-2"  ;# Target Artix-7 75T part
set P_PROJECT_NAME "usb_serial_emulator_proj"
set P_TOP_MODULE "usb_serial_top"
set P_BUILD_OUTPUT_DIR "./build_output" ;# Output directory relative to this script

# Check if build output directory exists, if so, delete it to ensure a clean build
if {[file isdirectory $P_BUILD_OUTPUT_DIR]} {
    puts "INFO: Deleting existing build output directory: $P_BUILD_OUTPUT_DIR"
    file delete -force $P_BUILD_OUTPUT_DIR
}

puts "INFO: Creating Vivado project '${P_PROJECT_NAME}' in '${P_BUILD_OUTPUT_DIR}' for part '${P_FPGA_PART}'."
create_project -force ${P_PROJECT_NAME} ${P_BUILD_OUTPUT_DIR} -part ${P_FPGA_PART}

# --- Add Source Files ---
# Add all SystemVerilog files from the ../src directory.
# This includes:
#   cdc_acm_handler.sv
#   dma_controller.sv
#   ft601_protocol_adapter.sv
#   pcileech_ft601.sv
#   serial_port_application.sv
#   usb_descriptors.sv
#   usb_serial_top.sv (which contains behavioral BRAM and FIFO models for simulation)
# For synthesis, behavioral BRAM/FIFO models should be replaced by IP cores or inferred.
puts "INFO: Adding source files..."
add_files -norecurse [glob -nocomplain ../src/*.sv]

# If you have IP cores (e.g., for BRAMs, FIFOs, Clock Wizards), add their .xci files:
# add_files -norecurse [glob ../ip/*.xci]


# --- Add Constraints File ---
puts "INFO: Adding constraints file..."
add_files -fileset constrs_1 -norecurse ../constraints/usb_serial_emulator.xdc


# --- Set Top Module ---
puts "INFO: Setting top module to '${P_TOP_MODULE}'."
set_property top ${P_TOP_MODULE} [current_fileset]
# For simulation, tb_usb_serial_top is the top, but for synthesis, it's usb_serial_top.
# If managing simulation sets in Vivado:
# update_compile_order -fileset sources_1
# update_compile_order -fileset sim_1


# --- Optional: Configure Simulation Settings (if using Vivado Simulator) ---
# You might want to add tb_usb_serial_top.sv to a simulation fileset
# add_files -fileset sim_1 -norecurse ../sim/tb_usb_serial_top.sv
# set_property top tb_usb_serial_top [get_filesets sim_1]


# --- Optional: Synthesis, Implementation, and Bitstream Generation ---
# Uncomment the following lines to run these steps automatically.
# It's recommended to run these with appropriate job control for your machine.
# set num_jobs [expr {[llength [get_slice_instances -of_objects [get_sites SLICE]]] / 20000}] ;# Heuristic for job count
# if {$num_jobs < 1} { set num_jobs 1 }
# puts "INFO: Using $num_jobs jobs for synthesis and implementation."

# puts "INFO: Launching Synthesis..."
# launch_runs synth_1 -jobs $num_jobs
# wait_on_run synth_1
# puts "INFO: Synthesis complete."

# puts "INFO: Launching Implementation..."
# launch_runs impl_1 -jobs $num_jobs
# wait_on_run impl_1
# puts "INFO: Implementation complete."

# puts "INFO: Generating Bitstream..."
# launch_runs impl_1 -to_step write_bitstream -jobs $num_jobs
# wait_on_run impl_1
# puts "INFO: Bitstream generation complete."


# --- Final Informational Messages ---
puts "INFO: Vivado project '${P_PROJECT_NAME}' created successfully."
puts "INFO: To run simulation, configure your simulator with 'tb_usb_serial_top.sv' as the top simulation module."
puts "INFO:       Include source files from the 'src' directory and the testbench from 'sim'."
puts "INFO: To synthesize and implement, uncomment relevant lines at the end of this script or use the Vivado GUI."
puts "INFO:       Ensure BRAM and Async FIFO models in 'usb_serial_top.sv' are suitable for synthesis"
puts "INFO:       or replaced with appropriate IP cores for FPGA implementation."

# Example: How to open the project in GUI after script execution (optional)
# start_gui
