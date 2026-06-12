`timescale 1ns/1ps

module tb_wp_adjust;
    localparam PIXEL_BITS = 10;
    localparam FRAC_BITS = 12;
    localparam [PIXEL_BITS-1:0] MAX_PIXEL = {PIXEL_BITS{1'b1}};

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
            $display("FAIL: %0s", msg);
            $finish;
        end
    endtask

    task expect_pixel;
        input [PIXEL_BITS-1:0] exp_r;
        input [PIXEL_BITS-1:0] exp_g;
        input [PIXEL_BITS-1:0] exp_b;
        input [511:0] msg;
        begin
            if (out_r !== exp_r || out_g !== exp_g || out_b !== exp_b) begin
                $display("FAIL: %0s got r=%0d g=%0d b=%0d expected r=%0d g=%0d b=%0d",
                         msg, out_r, out_g, out_b, exp_r, exp_g, exp_b);
                $finish;
            end
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

    task expect_status;
        input exp_pending;
        input exp_consumed;
        input [511:0] msg;
        begin
            cfg_addr = 8'h72;
            #1;
            if (cfg_rdata[0] !== exp_pending || cfg_rdata[1] !== exp_consumed) begin
                $display("FAIL: %0s got pending=%0b consumed=%0b expected pending=%0b consumed=%0b",
                         msg, cfg_rdata[0], cfg_rdata[1], exp_pending, exp_consumed);
                $finish;
            end
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
            expect_status(1'b1, 1'b0, "commit_pending did not set");
            pulse_vsync(4);
            expect_status(1'b0, 1'b1, "commit did not consume on filtered vsync");
        end
    endtask

    task drive_pixel_and_wait;
        input [PIXEL_BITS-1:0] r;
        input [PIXEL_BITS-1:0] g;
        input [PIXEL_BITS-1:0] b;
        begin
            @(posedge clk);
            in_r <= r;
            in_g <= g;
            in_b <= b;
            in_de <= 1'b1;
            repeat (3) @(posedge clk);
        end
    endtask

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

    // Reference model mirroring the wp_adjust datapath contract:
    // scale (or pass through in Q form), optionally add offset in Q form,
    // clamp negative to zero, round half-up at the Q point, saturate high.
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

    task apply_random_config;
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

    task check_random_pixels;
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
                drive_pixel_and_wait(r, g, b);
                expect_pixel(
                    ref_pixel(r, r_gain, r_offset, enable, offset_enable),
                    ref_pixel(g, g_gain, g_offset, enable, offset_enable),
                    ref_pixel(b, b_gain, b_offset, enable, offset_enable),
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
        cfg_addr = 8'h71;
        #1;
        if (cfg_rdata !== 16'h0113) fail("VERSION register mismatch");

        drive_pixel_and_wait(10'd123, 10'd456, 10'd789);
        expect_pixel(10'd123, 10'd456, 10'd789, "reset/default pass-through");

        write_reg(8'h00, 16'h0001);
        write_reg(8'h01, 16'h0800); // R = 0.5
        write_reg(8'h02, 16'h1000); // G = 1.0
        write_reg(8'h03, 16'h1800); // B = 1.5

        cfg_addr = 8'h21;
        #1;
        if (cfg_rdata !== 16'h1000) fail("active value changed before commit");
        cfg_addr = 8'h22;
        #1;
        if (cfg_rdata !== 16'h1000) fail("active G value changed before commit");
        cfg_addr = 8'h23;
        #1;
        if (cfg_rdata !== 16'h1000) fail("active B value changed before commit");

        apply_commit();

        drive_pixel_and_wait(10'd100, 10'd100, 10'd100);
        expect_pixel(10'd50, 10'd100, 10'd150, "known gains");
        drive_pixel_and_wait(10'd101, 10'd101, 10'd101);
        expect_pixel(10'd51, 10'd101, 10'd152, "round half-up ties");

        write_reg(8'h01, 16'h2000); // R = 2.0
        write_reg(8'h02, 16'h1000);
        write_reg(8'h03, 16'h1000);
        apply_commit();

        drive_pixel_and_wait(10'd800, 10'd100, 10'd100);
        expect_pixel(MAX_PIXEL, 10'd100, 10'd100, "over-range saturates");
        // 512 * 2.0 = 1024 = MAX_PIXEL + 1: the smallest over-range result
        // must saturate, not wrap to zero.
        drive_pixel_and_wait(10'd512, 10'd100, 10'd100);
        expect_pixel(MAX_PIXEL, 10'd100, 10'd100, "max-plus-one saturates without wrap");

        write_reg(8'h00, 16'h0001);
        write_reg(8'h01, 16'h0800);
        write_reg(8'h02, 16'h0800);
        write_reg(8'h03, 16'h0800);
        write_reg(8'h7e, 16'hCA1B);
        @(posedge clk);
        expect_status(1'b1, 1'b0, "pending commit before defaults");
        write_reg(8'h7f, 16'hD65D);
        expect_status(1'b0, 1'b0, "defaults did not cancel pending commit");
        drive_pixel_and_wait(10'd333, 10'd444, 10'd555);
        expect_pixel(10'd333, 10'd444, 10'd555, "defaults immediate pass-through");
        pulse_vsync(4);
        drive_pixel_and_wait(10'd333, 10'd444, 10'd555);
        expect_pixel(10'd333, 10'd444, 10'd555, "defaults prevent stale commit");

        write_reg(8'h00, 16'h0002); // offset bit alone must not affect pixels
        write_reg(8'h01, 16'h1000);
        write_reg(8'h02, 16'h1000);
        write_reg(8'h03, 16'h1000);
        write_reg(8'h04, 16'h0032); // +50
        write_reg(8'h05, 16'h0000);
        write_reg(8'h06, 16'h0000);
        apply_commit();

        drive_pixel_and_wait(10'd100, 10'd100, 10'd100);
        expect_pixel(10'd100, 10'd100, 10'd100, "offset enable requires master enable");

        write_reg(8'h00, 16'h0003); // unity gain + offset enable
        write_reg(8'h01, 16'h1000);
        write_reg(8'h02, 16'h1000);
        write_reg(8'h03, 16'h1000);
        write_reg(8'h04, 16'h0032); // +50
        write_reg(8'h05, 16'h0000);
        write_reg(8'h06, 16'h0000);
        apply_commit();

        drive_pixel_and_wait(10'd100, 10'd100, 10'd100);
        expect_pixel(10'd150, 10'd100, 10'd100, "offset with unity gains");

        write_reg(8'h00, 16'h0003); // gain + offset enable
        write_reg(8'h01, 16'h1000);
        write_reg(8'h02, 16'h1000);
        write_reg(8'h03, 16'h1000);
        write_reg(8'h04, 16'hFFEC); // -20
        write_reg(8'h05, 16'h0000);
        write_reg(8'h06, 16'h0000);
        apply_commit();

        drive_pixel_and_wait(10'd10, 10'd10, 10'd10);
        expect_pixel(10'd0, 10'd10, 10'd10, "negative offset clamps to zero");

        write_reg(8'h7f, 16'hD65D);
        write_reg(8'h00, 16'h0001);
        write_reg(8'h01, 16'h0800); // R = 0.5
        write_reg(8'h02, 16'h1000);
        write_reg(8'h03, 16'h1000);
        write_reg(8'h7e, 16'hCA1B);
        @(posedge clk);
        expect_status(1'b1, 1'b0, "pending commit before vsync glitch");
        pulse_vsync(1);
        expect_status(1'b1, 1'b0, "one-cycle vsync glitch consumed commit");
        drive_pixel_and_wait(10'd100, 10'd100, 10'd100);
        expect_pixel(10'd100, 10'd100, 10'd100, "vsync glitch changed active values");
        pulse_vsync(4);
        expect_status(1'b0, 1'b1, "sustained vsync did not consume commit");
        drive_pixel_and_wait(10'd100, 10'd100, 10'd100);
        expect_pixel(10'd50, 10'd100, 10'd100, "sustained vsync applied commit");

        // COMMIT_CANCEL: clears an armed commit without touching shadow or
        // active registers.
        write_reg(8'h7f, 16'hD65D);
        write_reg(8'h00, 16'h0001);
        write_reg(8'h01, 16'h0C00); // R = 0.75
        write_reg(8'h02, 16'h1000);
        write_reg(8'h03, 16'h1000);
        apply_commit();

        write_reg(8'h01, 16'h0A00); // stage a new value, then cancel
        write_reg(8'h7e, 16'hCA1B);
        @(posedge clk);
        expect_status(1'b1, 1'b0, "commit before cancel did not arm");
        write_reg(8'h7e, 16'hC0FF);
        expect_status(1'b0, 1'b0, "cancel did not clear pending commit");
        cfg_addr = 8'h01;
        #1;
        if (cfg_rdata !== 16'h0A00) fail("cancel corrupted shadow register");
        cfg_addr = 8'h21;
        #1;
        if (cfg_rdata !== 16'h0C00) fail("cancel corrupted active register");
        pulse_vsync(4);
        cfg_addr = 8'h21;
        #1;
        if (cfg_rdata !== 16'h0C00) fail("cancelled commit still latched on vsync");
        write_reg(8'h7e, 16'hCA1B); // re-arm: preserved shadow must latch
        pulse_vsync(4);
        expect_status(1'b0, 1'b1, "re-armed commit after cancel did not consume");
        cfg_addr = 8'h21;
        #1;
        if (cfg_rdata !== 16'h0A00) fail("re-armed commit did not latch preserved shadow");

        // V5: negative register-interface tests.
        write_reg(8'h7f, 16'hD65D);
        cfg_addr = 8'h50;
        #1;
        if (cfg_rdata !== 16'd0) fail("unknown address did not read zero");

        write_reg(8'h21, 16'h0123); // write to read-only active register
        cfg_addr = 8'h21;
        #1;
        if (cfg_rdata !== 16'h1000) fail("write to RO active register was not ignored");
        cfg_addr = 8'h01;
        #1;
        if (cfg_rdata !== 16'h1000) fail("write to RO address corrupted shadow");

        write_reg(8'h7e, 16'h1234); // wrong COMMIT magic
        expect_status(1'b0, 1'b0, "wrong COMMIT magic armed a commit");

        write_reg(8'h01, 16'h0ABC);
        write_reg(8'h7f, 16'hD65E); // wrong DEFAULTS magic
        cfg_addr = 8'h01;
        #1;
        if (cfg_rdata !== 16'h0ABC) fail("wrong DEFAULTS magic reset shadow registers");
        write_reg(8'h7f, 16'hD65D);
        cfg_addr = 8'h01;
        #1;
        if (cfg_rdata !== 16'h1000) fail("DEFAULTS did not restore shadow after negative test");

        // V3: exact 2-cycle latency and pixel/sync alignment in pass-through.
        @(negedge clk);
        in_r = {PIXEL_BITS{1'b0}};
        in_g = {PIXEL_BITS{1'b0}};
        in_b = {PIXEL_BITS{1'b0}};
        in_de = 1'b0;
        in_hsync = 1'b0;
        in_vsync = 1'b0;
        repeat (4) @(posedge clk);
        #1;
        if (out_de !== 1'b0) fail("latency pretest: out_de not idle");
        @(negedge clk);
        in_r = 10'd77;
        in_g = 10'd88;
        in_b = 10'd99;
        in_de = 1'b1;
        in_hsync = 1'b1;
        @(negedge clk);
        in_r = {PIXEL_BITS{1'b0}};
        in_g = {PIXEL_BITS{1'b0}};
        in_b = {PIXEL_BITS{1'b0}};
        in_de = 1'b0;
        in_hsync = 1'b0;
        #1;
        if (out_de !== 1'b0) fail("DE appeared before 2-cycle latency");
        @(posedge clk);
        #1;
        if (out_de !== 1'b1 || out_hsync !== 1'b1)
            fail("DE/hsync did not appear at exactly 2-cycle latency");
        expect_pixel(10'd77, 10'd88, 10'd99, "pixel not aligned with its DE");
        @(posedge clk);
        #1;
        if (out_de !== 1'b0 || out_hsync !== 1'b0)
            fail("single-cycle DE pulse was stretched");

        // V1: randomized co-simulation against the reference model.
        rand_seed = 32'h5EED0001;

        // Deterministic extremes first: max gain with max positive offset,
        // then zero gain with most-negative offset.
        apply_random_config(16'hFFFF, 16'hFFFF, 16'hFFFF,
                            16'h7FFF, 16'h7FFF, 16'h7FFF, 1'b1, 1'b1);
        check_random_pixels(16'hFFFF, 16'hFFFF, 16'hFFFF,
                            16'h7FFF, 16'h7FFF, 16'h7FFF, 1'b1, 1'b1, 8);
        apply_random_config(16'h0000, 16'h0000, 16'h0000,
                            16'h8000, 16'h8000, 16'h8000, 1'b1, 1'b1);
        check_random_pixels(16'h0000, 16'h0000, 16'h0000,
                            16'h8000, 16'h8000, 16'h8000, 1'b1, 1'b1, 8);

        for (cfg_i = 0; cfg_i < 10; cfg_i = cfg_i + 1) begin
            rnd_r_gain = $random(rand_seed);
            rnd_g_gain = $random(rand_seed);
            rnd_b_gain = $random(rand_seed);
            rnd_r_offset = $random(rand_seed);
            rnd_g_offset = $random(rand_seed);
            rnd_b_offset = $random(rand_seed);
            rnd_enable = (cfg_i == 0) ? 1'b0 : 1'b1; // keep one pass-through config
            rnd_offset_enable = $random(rand_seed);
            apply_random_config(rnd_r_gain, rnd_g_gain, rnd_b_gain,
                                rnd_r_offset, rnd_g_offset, rnd_b_offset,
                                rnd_enable, rnd_offset_enable);
            check_random_pixels(rnd_r_gain, rnd_g_gain, rnd_b_gain,
                                rnd_r_offset, rnd_g_offset, rnd_b_offset,
                                rnd_enable, rnd_offset_enable, 40);
        end

        write_reg(8'h7f, 16'hD65D);

        $display("PASS: wp_adjust directed tests");
        $finish;
    end
endmodule
