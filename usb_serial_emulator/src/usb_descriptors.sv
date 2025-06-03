// usb_descriptors.sv
// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2024 Google, Inc.

`ifndef USB_DESCRIPTORS_SV
`define USB_DESCRIPTORS_SV

package usb_descriptors;

  // VID/PID
  parameter byte VID_HIGH = 8'h12;
  parameter byte VID_LOW  = 8'h09;
  parameter byte PID_HIGH = 8'h00;
  parameter byte PID_LOW  = 8'h01;
  parameter byte DEV_REL_HIGH = 8'h01; // Device Release Number (BCD)
  parameter byte DEV_REL_LOW  = 8'h00; // Version 1.0

  // String Descriptor Indices
  parameter byte LANG_ID_IDX      = 0;
  parameter byte MANUFACTURER_IDX = 1;
  parameter byte PRODUCT_IDX      = 2;
  parameter byte SERIAL_IDX       = 3;

  // --- Device Descriptor ---
  parameter byte device_descriptor[] = {
    18,          // bLength: Descriptor size in bytes (18 bytes)
    1,           // bDescriptorType: DEVICE (0x01)
    8'h00, 8'h02, // bcdUSB: USB Specification Release Number (BCD). USB 2.0 (0x0200)
    2,           // bDeviceClass: Communications Device Class (CDC) (0x02)
                 // If this is 0, the class is defined at the interface level.
    0,           // bDeviceSubClass: Unused (0x00)
    0,           // bDeviceProtocol: Unused (0x00)
    64,          // bMaxPacketSize0: Maximum packet size for endpoint zero (64 bytes)
    VID_LOW, VID_HIGH, // idVendor: Vendor ID (e.g., 0x1209)
    PID_LOW, PID_HIGH, // idProduct: Product ID (e.g., 0x0001)
    DEV_REL_LOW, DEV_REL_HIGH, // bcdDevice: Device release number (BCD) (e.g., 0x0100 for V1.0)
    MANUFACTURER_IDX, // iManufacturer: Index of string descriptor for the manufacturer
    PRODUCT_IDX,      // iProduct: Index of string descriptor for the product
    SERIAL_IDX,       // iSerialNumber: Index of string descriptor for the serial number
    1            // bNumConfigurations: Number of possible configurations (1)
  };

  // --- Configuration Descriptor (and all related interface/endpoint descriptors) ---
  // Total length will be calculated later
  parameter byte configuration_descriptor[] = {
    // Configuration Descriptor
    9,           // bLength: Descriptor size in bytes (9 bytes)
    2,           // bDescriptorType: CONFIGURATION (0x02)
    8'h4B, 8'h00, // wTotalLength: Total length of data returned for this configuration (75 bytes). (LSB, MSB)
    2,           // bNumInterfaces: Number of interfaces supported by this configuration (2: CCI and DCI)
    1,           // bConfigurationValue: Value to use as an argument to the SetConfiguration() request
    0,           // iConfiguration: Index of string descriptor describing this configuration (None)
    8'hC0,       // bmAttributes: Configuration characteristics (Self-powered, No remote wakeup) (0xC0)
                 // D7: Reserved (set to 1)
                 // D6: Self-powered
                 // D5: Remote Wakeup
                 // D4..0: Reserved (set to 0)
    250,         // bMaxPower: Maximum power consumption of the USB device from the bus in this
                 // specific configuration when the device is fully operational. Expressed in 2 mA units
                 // (i.e., 250 = 500 mA).

    // Interface Association Descriptor (IAD) for CDC/ACM
    8,           // bLength: Descriptor size in bytes (8 bytes)
    11,          // bDescriptorType: INTERFACE_ASSOCIATION (0x0B)
    0,           // bFirstInterface: Interface number of the first interface that is associated with this function.
    2,           // bInterfaceCount: Number of contiguous interfaces that are associated with this function.
    2,           // bFunctionClass: Class code (0x02 - CDC Control)
    2,           // bFunctionSubClass: Subclass code (0x02 - Abstract Control Model)
    1,           // bFunctionProtocol: Protocol code (0x01 - V.25ter, AT Command Set)
    0,           // iFunction: Index of string descriptor describing this function (None)

    // --- CDC Communication Class Interface (CCI) ---
    // Interface Descriptor
    9,           // bLength: Descriptor size in bytes (9 bytes)
    4,           // bDescriptorType: INTERFACE (0x04)
    0,           // bInterfaceNumber: Number of this interface. Zero-based value. (Interface 0)
    0,           // bAlternateSetting: Value used to select this alternate setting.
    1,           // bNumEndpoints: Number of endpoints used by this interface (excluding endpoint zero). (1 INTR IN EP)
    2,           // bInterfaceClass: Class code (0x02 - CDC Control)
    2,           // bInterfaceSubClass: Subclass code (0x02 - Abstract Control Model)
    1,           // bInterfaceProtocol: Protocol code (0x01 - V.25ter, AT Command Set)
    0,           // iInterface: Index of string descriptor describing this interface (None)

    // CDC Header Functional Descriptor
    5,           // bLength: Descriptor size in bytes (5 bytes)
    36,          // bDescriptorType: CS_INTERFACE (0x24)
    0,           // bDescriptorSubtype: Header Functional Descriptor (0x00)
    8'h10, 8'h01, // bcdCDC: CDC Specification release number (BCD). (0x0110 for V1.10)

    // CDC Call Management Functional Descriptor
    5,           // bLength: Descriptor size in bytes (5 bytes)
    36,          // bDescriptorType: CS_INTERFACE (0x24)
    1,           // bDescriptorSubtype: Call Management Functional Descriptor (0x01)
    0,           // bmCapabilities:
                 // D1: Device can send/receive call management information over Data Class interface.
                 // D0: Device handles call management itself.
                 // (0x00 means device does not handle call management)
    1,           // bDataInterface: Interface number of Data Class interface optionally used for call management. (Interface 1)

    // CDC ACM (Abstract Control Model) Functional Descriptor
    4,           // bLength: Descriptor size in bytes (4 bytes)
    36,          // bDescriptorType: CS_INTERFACE (0x24)
    2,           // bDescriptorSubtype: Abstract Control Management Functional Descriptor (0x02)
    2,           // bmCapabilities: Supports Set_Line_Coding, Set_Control_Line_State, Get_Line_Coding,
                 // Serial_State notifications. (0x02)
                 // D3: Supports Send_Break
                 // D2: Supports Set_Control_Line_State, Get_Line_Coding, Set_Line_Coding, Serial_State
                 // D1: Supports Set_Ringer_Parms, Get_Ringer_Parms, Ring_Abs_Snapping
                 // D0: Supports Set_Line_Parms, Get_Line_Parms, Set_Limit_Power, Get_Limit_Power

    // CDC Union Functional Descriptor
    5,           // bLength: Descriptor size in bytes (5 bytes)
    36,          // bDescriptorType: CS_INTERFACE (0x24)
    6,           // bDescriptorSubtype: Union Functional Descriptor (0x06)
    0,           // bControlInterface: Interface number of the controlling interface (Interface 0 - CCI)
    1,           // bSubordinateInterface0: Interface number of the first subordinate interface (Interface 1 - DCI)

    // Endpoint Descriptor (Interrupt IN for CCI - e.g., EP3 IN)
    7,           // bLength: Descriptor size in bytes (7 bytes)
    5,           // bDescriptorType: ENDPOINT (0x05)
    8'h83,       // bEndpointAddress: Endpoint address (IN endpoint, number 3) (0x83)
                 // D7: Direction (0=OUT, 1=IN)
                 // D6..4: Reserved (reset to 0)
                 // D3..0: Endpoint number
    3,           // bmAttributes: Transfer type (Interrupt) (0x03)
                 // D1..0: Transfer Type (00=Control, 01=Isochronous, 10=Bulk, 11=Interrupt)
                 // D3..2: If Isochronous: Synchronization Type (00=No Sync, 01=Async, 10=Adaptive, 11=Sync)
                 // D5..4: If Isochronous: Usage Type (00=Data EP, 01=Feedback EP, 10=Implicit FB Data EP, 11=Reserved)
    16, 0,       // wMaxPacketSize: Maximum packet size for this endpoint. (16 bytes, SERIAL_STATE is 10 bytes: 8 header + 2 payload) (LSB, MSB)
    8'hFF        // bInterval: Polling interval for data transfers (255ms for FS Interrupt, or a lower value like 10ms (0x0A))

    // --- CDC Data Class Interface (DCI) ---
    // Interface Descriptor
    ,9,          // bLength: Descriptor size in bytes (9 bytes)
    4,           // bDescriptorType: INTERFACE (0x04)
    1,           // bInterfaceNumber: Number of this interface. Zero-based value. (Interface 1)
    0,           // bAlternateSetting: Value used to select this alternate setting.
    2,           // bNumEndpoints: Number of endpoints used by this interface (excluding endpoint zero). (2: Bulk IN & Bulk OUT)
    10,          // bInterfaceClass: Class code (0x0A - CDC Data)
    0,           // bInterfaceSubClass: Subclass code (unused) (0x00)
    0,           // bInterfaceProtocol: Protocol code (unused) (0x00)
    0,           // iInterface: Index of string descriptor describing this interface (None)

    // Endpoint Descriptor (Bulk OUT for DCI)
    7,           // bLength: Descriptor size in bytes (7 bytes)
    5,           // bDescriptorType: ENDPOINT (0x05)
    8'h02,       // bEndpointAddress: Endpoint address (OUT endpoint, number 2) (0x02)
    2,           // bmAttributes: Transfer type (Bulk) (0x02)
    64, 0,       // wMaxPacketSize: Maximum packet size for this endpoint. (64 bytes for FS Bulk) (LSB, MSB)
    0,           // bInterval: Polling interval (ignored for Bulk a FS/HS)

    // Endpoint Descriptor (Bulk IN for DCI)
    7,           // bLength: Descriptor size in bytes (7 bytes)
    5,           // bDescriptorType: ENDPOINT (0x05)
    8'h82,       // bEndpointAddress: Endpoint address (IN endpoint, number 2) (0x82)
    2,           // bmAttributes: Transfer type (Bulk) (0x02)
    64, 0,       // wMaxPacketSize: Maximum packet size for this endpoint. (64 bytes for FS Bulk) (LSB, MSB)
    0            // bInterval: Polling interval (ignored for Bulk at FS/HS)
  };

  // Calculate wTotalLength for Configuration Descriptor
  // The wTotalLength is the sum of:
  // Config_Desc (9) + IAD (8) + CCI_Interface (9) + CDC_Header (5) + CDC_CallMan (5) + CDC_ACM (4) + CDC_Union (5) + EP_Intr (7) + DCI_Interface (9) + EP_BulkOut (7) + EP_BulkIn (7)
  // = 9 + 8 + 9 + 5 + 5 + 4 + 5 + 7 + 9 + 7 + 7 = 75 bytes
  localparam CONFIG_TOTAL_LEN = configuration_descriptor.size();
  // Sanity check, the array size should match the pre-calculated total length
  initial begin
    if (CONFIG_TOTAL_LEN != 75) begin
      $display("Error: configuration_descriptor size (%0d) does not match expected 75. Please update wTotalLength.", CONFIG_TOTAL_LEN);
      $finish;
    end
  end

  // --- String Descriptors ---

  // Language ID String Descriptor (LANGID US English)
  parameter byte string_descriptor_lang_id[] = {
    4,           // bLength: Descriptor size in bytes
    3,           // bDescriptorType: STRING (0x03)
    8'h09, 8'h04  // wLANGID[0]: English (United States) (0x0409)
  };

  // Manufacturer String Descriptor
  parameter byte string_descriptor_manufacturer[] = {
    18,          // bLength: Descriptor size in bytes
    3,           // bDescriptorType: STRING (0x03)
    // "G", "o", "o", "g", "l", "e", ",", " ", "I", "n", "c", ".", - This is 12 chars (24 bytes)
    // Simple placeholder: "Google"
    'G',0, 'o',0, 'o',0, 'g',0, 'l',0, 'e',0 // Unicode characters
  };

  // Product String Descriptor
  parameter byte string_descriptor_product[] = {
    30,          // bLength: Descriptor size in bytes
    3,           // bDescriptorType: STRING (0x03)
    // "U", "S", "B", " ", "S", "e", "r", "i", "a", "l", " ", "E", "m", "u"
    'U',0, 'S',0, 'B',0, ' ',0, 'S',0, 'e',0, 'r',0, 'i',0, 'a',0, 'l',0, ' ',0, 'E',0, 'm',0, 'u',0
  };

  // Serial Number String Descriptor
  parameter byte string_descriptor_serial[] = {
    20,          // bLength: Descriptor size in bytes
    3,           // bDescriptorType: STRING (0x03)
    // "1", "2", "3", "4", "5", "6", "7", "8", "9"
    '0',0, '0',0, '0',0, '-',0, '0',0, '0',0, '0',0, '0',0, '1',0
  };

  // Array of pointers to string descriptors for easy lookup
  // Note: SystemVerilog doesn't directly support arrays of differently sized arrays in a way
  // that's easily synthesizable for this kind of lookup.
  // For actual hardware, you'd typically have a case statement or if-else chain
  // in the cdc_acm_handler to select the descriptor.
  // This is a conceptual representation.
  // typedef byte unsigned byte_array_t[];
  // parameter byte_array_t string_descriptors[4] = {
  //   string_descriptor_lang_id,
  //   string_descriptor_manufacturer,
  //   string_descriptor_product,
  //   string_descriptor_serial
  // };

endpackage : usb_descriptors

`endif // USB_DESCRIPTORS_SV
