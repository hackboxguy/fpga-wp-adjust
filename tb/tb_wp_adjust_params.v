`timescale 1ns/1ps

// Parameter-generic wp_adjust testbench.
//
// Unlike tb_wp_adjust.v (which checks hand-computed Q4.12 values), every
// expectation here comes from an in-testbench reference model, so the same
// bench validates any legal PIXEL_BITS/FRAC_BITS combination. Build-time
// overrides select the configuration:
//
//   iverilog -DWP_PIXEL_BITS=8 -DWP_FRAC_BITS=10 ...
//
// Covered per configuration: ID/STATUS frac-bits readback, reset
// pass-through, enabled unity-gain transparency, the MAX_PIXEL+1 saturation
// corner, and randomized gain/offset/enable configurations against the
// reference model.

`ifndef WP_PIXEL_BITS
`define WP_PIXEL_BITS 10
`endif
`ifndef WP_FRAC_BITS
`define WP_FRAC_BITS 12
`endif

module tb_wp_adjust_params;
    localparam PIXEL_BITS = `WP_PIXEL_BITS;
    localparam FRAC_BITS = `WP_FRAC_BITS;
    localparam [PIXEL_BITS-1:0] MAX_PIXEL = {PIXEL_BITS{1'b1}};
    localparam [15:0] UNITY = 16'h0001 << FRAC_BITS;

    reg clk;
    reg rst_n;
    reg [PIXEL_BITS-1:0] in_r;
    reg [PIXEL_BITS-1:0] in_g;
    reg [PIXEL_BITS-1:0] in_b;
    reg in_de;
    reg in_hsync;
    reg in_vsync;
    wire [PIXEL_BITS-1:0] out_r;
    wire [PIXEL_BITS-1:0] out_g;
    wire [PIXEL_BITS-1:0] out_b;
    wire out_de;
    wire out_hsync;
    wire out_vsync;
    reg cfg_wr_en;
    reg [7:0] cfg_addr;
    reg [15:0] cfg_wdata;
    wire [15:0] cfg_rdata;

    integer rand_seed;
    integer cfg_i;
    reg [15:0] rnd_r_gain;
    reg [15:0] rnd_g_gain;
    reg [15:0] rnd_b_gain;
    reg [15:0] rnd_r_offset;
    reg [15:0] rnd_g_offset;
    reg [15:0] rnd_b_offset;
    reg rnd_enable;
    reg rnd_offset_enable;

    wp_adjust #(
        .PIXEL_BITS(PIXEL_BITS),
        .FRAC_BITS(FRAC_BITS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_r(in_r),
        .in_g(in_g),
        .in_b(in_b),
        .in_de(in_de),
        .in_hsync(in_hsync),
        .in_vsync(in_vsync),
        .out_r(out_r),
        .out_g(out_g),
        .out_b(out_b),
        .out_de(out_de),
        .out_hsync(out_hsync),
        .out_vsync(out_vsync),
        .cfg_wr_en(cfg_wr_en),
        .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata),
        .cfg_rdata(cfg_rdata)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task fail;
        input [511:0] msg;
        begin
            $display("FAIL(%0d/%0d): %0s", PIXEL_BITS, FRAC_BITS, msg);
            $finish;
        end
    endtask

    task write_reg;
        input [7:0] addr;
        input [15:0] data;
        begin
            @(negedge clk);
            cfg_addr = addr;
            cfg_wdata = data;
            cfg_wr_en = 1'b1;
            @(negedge clk);
            cfg_wr_en = 1'b0;
            cfg_addr = 8'h00;
            cfg_wdata = 16'h0000;
        end
    endtask

    task pulse_vsync;
        input integer high_cycles;
        integer i;
        begin
            @(negedge clk);
            in_vsync = 1'b1;
            for (i = 0; i < high_cycles; i = i + 1) begin
                @(posedge clk);
            end
            @(negedge clk);
            in_vsync = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task apply_commit;
        begin
            write_reg(8'h7e, 16'hCA1B);
            @(posedge clk);
            pulse_vsync(4);
            cfg_addr = 8'h72;
            #1;
            if (cfg_rdata[1] !== 1'b1) fail("commit did not consume on vsync");
        end
    endtask

    function [PIXEL_BITS-1:0] ref_pixel;
        input [PIXEL_BITS-1:0] pix;
        input [15:0] gain;
        input [15:0] offset;
        input enable;
        input offset_enable;
        reg signed [63:0] acc;
        begin
            if (enable)
                acc = pix * gain;
            else
                acc = pix << FRAC_BITS;
            if (enable && offset_enable)
                acc = acc + ($signed(offset) <<< FRAC_BITS);

            if (acc <= 0) begin
                ref_pixel = {PIXEL_BITS{1'b0}};
            end else begin
                acc = (acc + (64'sd1 << (FRAC_BITS - 1))) >>> FRAC_BITS;
                if (acc > $signed({{(64-PIXEL_BITS){1'b0}}, MAX_PIXEL}))
                    ref_pixel = MAX_PIXEL;
                else
                    ref_pixel = acc[PIXEL_BITS-1:0];
            end
        end
    endfunction

    task drive_and_check;
        input [PIXEL_BITS-1:0] r;
        input [PIXEL_BITS-1:0] g;
        input [PIXEL_BITS-1:0] b;
        input [15:0] r_gain;
        input [15:0] g_gain;
        input [15:0] b_gain;
        input [15:0] r_offset;
        input [15:0] g_offset;
        input [15:0] b_offset;
        input enable;
        input offset_enable;
        input [511:0] msg;
        reg [PIXEL_BITS-1:0] exp_r;
        reg [PIXEL_BITS-1:0] exp_g;
        reg [PIXEL_BITS-1:0] exp_b;
        begin
            exp_r = ref_pixel(r, r_gain, r_offset, enable, offset_enable);
            exp_g = ref_pixel(g, g_gain, g_offset, enable, offset_enable);
            exp_b = ref_pixel(b, b_gain, b_offset, enable, offset_enable);
            @(posedge clk);
            in_r <= r;
            in_g <= g;
            in_b <= b;
            in_de <= 1'b1;
            repeat (3) @(posedge clk);
            if (out_r !== exp_r || out_g !== exp_g || out_b !== exp_b) begin
                $display("FAIL(%0d/%0d): %0s got r=%0d g=%0d b=%0d expected r=%0d g=%0d b=%0d",
                         PIXEL_BITS, FRAC_BITS, msg,
                         out_r, out_g, out_b, exp_r, exp_g, exp_b);
                $finish;
            end
        end
    endtask

    task load_config;
        input [15:0] r_gain;
        input [15:0] g_gain;
        input [15:0] b_gain;
        input [15:0] r_offset;
        input [15:0] g_offset;
        input [15:0] b_offset;
        input enable;
        input offset_enable;
        begin
            write_reg(8'h00, {14'd0, offset_enable, enable});
            write_reg(8'h01, r_gain);
            write_reg(8'h02, g_gain);
            write_reg(8'h03, b_gain);
            write_reg(8'h04, r_offset);
            write_reg(8'h05, g_offset);
            write_reg(8'h06, b_offset);
            apply_commit();
        end
    endtask

    task check_config_random;
        input [15:0] r_gain;
        input [15:0] g_gain;
        input [15:0] b_gain;
        input [15:0] r_offset;
        input [15:0] g_offset;
        input [15:0] b_offset;
        input enable;
        input offset_enable;
        input integer pixel_count;
        integer pix_i;
        reg [PIXEL_BITS-1:0] r;
        reg [PIXEL_BITS-1:0] g;
        reg [PIXEL_BITS-1:0] b;
        begin
            load_config(r_gain, g_gain, b_gain,
                        r_offset, g_offset, b_offset,
                        enable, offset_enable);
            for (pix_i = 0; pix_i < pixel_count; pix_i = pix_i + 1) begin
                if (pix_i == 0) begin
                    r = {PIXEL_BITS{1'b0}};
                    g = MAX_PIXEL;
                    b = {PIXEL_BITS{1'b0}};
                end else if (pix_i == 1) begin
                    r = MAX_PIXEL;
                    g = {PIXEL_BITS{1'b0}};
                    b = MAX_PIXEL;
                end else begin
                    r = $random(rand_seed);
                    g = $random(rand_seed);
                    b = $random(rand_seed);
                end
                drive_and_check(r, g, b,
                                r_gain, g_gain, b_gain,
                                r_offset, g_offset, b_offset,
                                enable, offset_enable,
                                "randomized co-sim mismatch");
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        in_r = {PIXEL_BITS{1'b0}};
        in_g = {PIXEL_BITS{1'b0}};
        in_b = {PIXEL_BITS{1'b0}};
        in_de = 1'b0;
        in_hsync = 1'b0;
        in_vsync = 1'b0;
        cfg_wr_en = 1'b0;
        cfg_addr = 8'h00;
        cfg_wdata = 16'h0000;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        cfg_addr = 8'h70;
        #1;
        if (cfg_rdata !== 16'h57A1) fail("ID register mismatch");
        cfg_addr = 8'h72;
        #1;
        if (cfg_rdata[15:8] !== FRAC_BITS) fail("STATUS FRAC_BITS mismatch");

        // Reset pass-through.
        drive_and_check({PIXEL_BITS{1'b0}} + 17, {PIXEL_BITS{1'b0}} + 3, MAX_PIXEL,
                        UNITY, UNITY, UNITY, 16'd0, 16'd0, 16'd0,
                        1'b0, 1'b0, "reset pass-through");

        // Enabled unity gain must be exactly transparent.
        check_config_random(UNITY, UNITY, UNITY, 16'd0, 16'd0, 16'd0,
                            1'b1, 1'b0, 16);

        // MAX_PIXEL + 1 saturation corner: gain 2.0 on the half-range pixel
        // is the smallest over-range result and must saturate, not wrap.
        // Skipped when 2.0 does not fit the 16-bit gain (FRAC_BITS == 15).
        if (FRAC_BITS <= 14) begin
            load_config(UNITY << 1, UNITY, UNITY, 16'd0, 16'd0, 16'd0,
                        1'b1, 1'b0);
            drive_and_check({1'b1, {(PIXEL_BITS-1){1'b0}}},
                            {PIXEL_BITS{1'b0}} + 1, {PIXEL_BITS{1'b0}} + 1,
                            UNITY << 1, UNITY, UNITY, 16'd0, 16'd0, 16'd0,
                            1'b1, 1'b0, "max-plus-one saturation corner");
        end

        // Deterministic extremes.
        check_config_random(16'hFFFF, 16'hFFFF, 16'hFFFF,
                            16'h7FFF, 16'h7FFF, 16'h7FFF, 1'b1, 1'b1, 8);
        check_config_random(16'h0000, 16'h0000, 16'h0000,
                            16'h8000, 16'h8000, 16'h8000, 1'b1, 1'b1, 8);

        // Randomized configurations.
        rand_seed = 32'h5EED0000 + (PIXEL_BITS * 256) + FRAC_BITS;
        for (cfg_i = 0; cfg_i < 6; cfg_i = cfg_i + 1) begin
            rnd_r_gain = $random(rand_seed);
            rnd_g_gain = $random(rand_seed);
            rnd_b_gain = $random(rand_seed);
            rnd_r_offset = $random(rand_seed);
            rnd_g_offset = $random(rand_seed);
            rnd_b_offset = $random(rand_seed);
            rnd_enable = (cfg_i == 0) ? 1'b0 : 1'b1;
            rnd_offset_enable = $random(rand_seed);
            check_config_random(rnd_r_gain, rnd_g_gain, rnd_b_gain,
                                rnd_r_offset, rnd_g_offset, rnd_b_offset,
                                rnd_enable, rnd_offset_enable, 30);
        end

        $display("PASS: wp_adjust param tests PIXEL_BITS=%0d FRAC_BITS=%0d",
                 PIXEL_BITS, FRAC_BITS);
        $finish;
    end
endmodule
