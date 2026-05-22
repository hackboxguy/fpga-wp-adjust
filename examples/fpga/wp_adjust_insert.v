`timescale 1ns/1ps

// Example wrapper showing where wp_adjust fits in a display pipeline.
//
// This file is not intended to replace the project's real top-level wiring.
// Adapt signal names, reset handling, and register-bank connections to the
// target FPGA design.

module wp_adjust_insert #(
    parameter PIXEL_BITS = 10,
    parameter FRAC_BITS  = 12
) (
    input  wire                  pixel_clk,
    input  wire                  rst_n,

    input  wire [PIXEL_BITS-1:0] pixel_comp_r,
    input  wire [PIXEL_BITS-1:0] pixel_comp_g,
    input  wire [PIXEL_BITS-1:0] pixel_comp_b,
    input  wire                  pixel_comp_de,
    input  wire                  pixel_comp_hsync,
    input  wire                  pixel_comp_vsync,

    output wire [PIXEL_BITS-1:0] lvds_r,
    output wire [PIXEL_BITS-1:0] lvds_g,
    output wire [PIXEL_BITS-1:0] lvds_b,
    output wire                  lvds_de,
    output wire                  lvds_hsync,
    output wire                  lvds_vsync,

    // Connect these to a CDC-safe register bank in pixel_clk domain.
    input  wire                  wp_cfg_wr_en,
    input  wire [7:0]            wp_cfg_addr,
    input  wire [15:0]           wp_cfg_wdata,
    output wire [15:0]           wp_cfg_rdata
);

    wp_adjust #(
        .PIXEL_BITS(PIXEL_BITS),
        .FRAC_BITS(FRAC_BITS)
    ) u_wp_adjust (
        .clk(pixel_clk),
        .rst_n(rst_n),

        .in_r(pixel_comp_r),
        .in_g(pixel_comp_g),
        .in_b(pixel_comp_b),
        .in_de(pixel_comp_de),
        .in_hsync(pixel_comp_hsync),
        .in_vsync(pixel_comp_vsync),

        .out_r(lvds_r),
        .out_g(lvds_g),
        .out_b(lvds_b),
        .out_de(lvds_de),
        .out_hsync(lvds_hsync),
        .out_vsync(lvds_vsync),

        .cfg_wr_en(wp_cfg_wr_en),
        .cfg_addr(wp_cfg_addr),
        .cfg_wdata(wp_cfg_wdata),
        .cfg_rdata(wp_cfg_rdata)
    );

endmodule
