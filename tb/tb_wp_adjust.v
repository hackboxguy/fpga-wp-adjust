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
        if (cfg_rdata !== 16'h0112) fail("VERSION register mismatch");

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

        $display("PASS: wp_adjust directed tests");
        $finish;
    end
endmodule
