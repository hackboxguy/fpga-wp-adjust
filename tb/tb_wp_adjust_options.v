`timescale 1ns/1ps

// Tests for the opt-in wp_adjust integration parameters, which default off
// and therefore are not covered by tb_wp_adjust.v:
//
//   GATE_BLANKING=1     out_r/g/b forced to zero when delayed DE is low
//   VSYNC_ACTIVE_HIGH=0 commit consumes on the filtered active edge of an
//                       active-low vsync; out_vsync keeps input polarity
//
// Each option gets its own DUT instance with independent stimulus.

module tb_wp_adjust_options;
    localparam PIXEL_BITS = 10;
    localparam FRAC_BITS = 12;

    reg clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    task fail;
        input [511:0] msg;
        begin
            $display("FAIL: %0s", msg);
            $finish;
        end
    endtask

    // ------------------------------------------------------------------
    // DUT 1: GATE_BLANKING = 1
    // ------------------------------------------------------------------
    reg rst_n_gate;
    reg [PIXEL_BITS-1:0] gate_in_r;
    reg [PIXEL_BITS-1:0] gate_in_g;
    reg [PIXEL_BITS-1:0] gate_in_b;
    reg gate_in_de;
    reg gate_in_vsync;
    wire [PIXEL_BITS-1:0] gate_out_r;
    wire [PIXEL_BITS-1:0] gate_out_g;
    wire [PIXEL_BITS-1:0] gate_out_b;
    wire gate_out_de;
    reg gate_cfg_wr_en;
    reg [7:0] gate_cfg_addr;
    reg [15:0] gate_cfg_wdata;
    wire [15:0] gate_cfg_rdata;

    wp_adjust #(
        .PIXEL_BITS(PIXEL_BITS),
        .FRAC_BITS(FRAC_BITS),
        .GATE_BLANKING(1)
    ) dut_gate (
        .clk(clk),
        .rst_n(rst_n_gate),
        .in_r(gate_in_r),
        .in_g(gate_in_g),
        .in_b(gate_in_b),
        .in_de(gate_in_de),
        .in_hsync(1'b0),
        .in_vsync(gate_in_vsync),
        .out_r(gate_out_r),
        .out_g(gate_out_g),
        .out_b(gate_out_b),
        .out_de(gate_out_de),
        .out_hsync(),
        .out_vsync(),
        .cfg_wr_en(gate_cfg_wr_en),
        .cfg_addr(gate_cfg_addr),
        .cfg_wdata(gate_cfg_wdata),
        .cfg_rdata(gate_cfg_rdata)
    );

    task gate_write_reg;
        input [7:0] addr;
        input [15:0] data;
        begin
            @(negedge clk);
            gate_cfg_addr = addr;
            gate_cfg_wdata = data;
            gate_cfg_wr_en = 1'b1;
            @(negedge clk);
            gate_cfg_wr_en = 1'b0;
            gate_cfg_addr = 8'h00;
            gate_cfg_wdata = 16'h0000;
        end
    endtask

    task gate_drive_pixel;
        input [PIXEL_BITS-1:0] r;
        input de;
        begin
            @(posedge clk);
            gate_in_r <= r;
            gate_in_g <= r;
            gate_in_b <= r;
            gate_in_de <= de;
            repeat (3) @(posedge clk);
        end
    endtask

    task gate_pulse_vsync;
        integer i;
        begin
            @(negedge clk);
            gate_in_vsync = 1'b1;
            for (i = 0; i < 4; i = i + 1) @(posedge clk);
            @(negedge clk);
            gate_in_vsync = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // DUT 2: VSYNC_ACTIVE_HIGH = 0
    // ------------------------------------------------------------------
    reg rst_n_vsl;
    reg vsl_in_vsync;
    wire vsl_out_vsync;
    reg vsl_cfg_wr_en;
    reg [7:0] vsl_cfg_addr;
    reg [15:0] vsl_cfg_wdata;
    wire [15:0] vsl_cfg_rdata;

    wp_adjust #(
        .PIXEL_BITS(PIXEL_BITS),
        .FRAC_BITS(FRAC_BITS),
        .VSYNC_ACTIVE_HIGH(0)
    ) dut_vsl (
        .clk(clk),
        .rst_n(rst_n_vsl),
        .in_r({PIXEL_BITS{1'b0}}),
        .in_g({PIXEL_BITS{1'b0}}),
        .in_b({PIXEL_BITS{1'b0}}),
        .in_de(1'b0),
        .in_hsync(1'b0),
        .in_vsync(vsl_in_vsync),
        .out_r(),
        .out_g(),
        .out_b(),
        .out_de(),
        .out_hsync(),
        .out_vsync(vsl_out_vsync),
        .cfg_wr_en(vsl_cfg_wr_en),
        .cfg_addr(vsl_cfg_addr),
        .cfg_wdata(vsl_cfg_wdata),
        .cfg_rdata(vsl_cfg_rdata)
    );

    task vsl_write_reg;
        input [7:0] addr;
        input [15:0] data;
        begin
            @(negedge clk);
            vsl_cfg_addr = addr;
            vsl_cfg_wdata = data;
            vsl_cfg_wr_en = 1'b1;
            @(negedge clk);
            vsl_cfg_wr_en = 1'b0;
            vsl_cfg_addr = 8'h00;
            vsl_cfg_wdata = 16'h0000;
        end
    endtask

    task vsl_expect_status;
        input exp_pending;
        input exp_consumed;
        input [511:0] msg;
        begin
            vsl_cfg_addr = 8'h72;
            #1;
            if (vsl_cfg_rdata[0] !== exp_pending || vsl_cfg_rdata[1] !== exp_consumed)
                fail(msg);
        end
    endtask

    task vsl_pulse_active_low;
        input integer low_cycles;
        integer i;
        begin
            @(negedge clk);
            vsl_in_vsync = 1'b0;
            for (i = 0; i < low_cycles; i = i + 1) @(posedge clk);
            @(negedge clk);
            vsl_in_vsync = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        // --- GATE_BLANKING tests ---
        rst_n_gate = 1'b0;
        gate_in_r = {PIXEL_BITS{1'b0}};
        gate_in_g = {PIXEL_BITS{1'b0}};
        gate_in_b = {PIXEL_BITS{1'b0}};
        gate_in_de = 1'b0;
        gate_in_vsync = 1'b0;
        gate_cfg_wr_en = 1'b0;
        gate_cfg_addr = 8'h00;
        gate_cfg_wdata = 16'h0000;

        // --- active-low vsync DUT init (idle high) ---
        rst_n_vsl = 1'b0;
        vsl_in_vsync = 1'b1;
        vsl_cfg_wr_en = 1'b0;
        vsl_cfg_addr = 8'h00;
        vsl_cfg_wdata = 16'h0000;

        repeat (4) @(posedge clk);
        rst_n_gate = 1'b1;
        rst_n_vsl = 1'b1;
        repeat (2) @(posedge clk);

        // Pass-through mode: active pixels pass, blanking pixels are gated.
        gate_drive_pixel(10'd123, 1'b1);
        if (gate_out_r !== 10'd123 || gate_out_de !== 1'b1)
            fail("gated DUT did not pass active pixel");
        gate_drive_pixel(10'd123, 1'b0);
        if (gate_out_r !== 10'd0 || gate_out_g !== 10'd0 || gate_out_b !== 10'd0)
            fail("blanking pixel was not gated to zero in pass-through mode");
        if (gate_out_de !== 1'b0)
            fail("gating corrupted delayed DE");

        // Enabled gain + positive offset: blanking stays zero, active scales.
        gate_write_reg(8'h00, 16'h0003);
        gate_write_reg(8'h01, 16'h0800); // 0.5
        gate_write_reg(8'h02, 16'h0800);
        gate_write_reg(8'h03, 16'h0800);
        gate_write_reg(8'h04, 16'h0032); // +50
        gate_write_reg(8'h05, 16'h0032);
        gate_write_reg(8'h06, 16'h0032);
        gate_write_reg(8'h7e, 16'hCA1B);
        gate_pulse_vsync;

        gate_drive_pixel(10'd100, 1'b1);
        if (gate_out_r !== 10'd100) // 100*0.5 + 50
            fail("gated DUT gain math wrong on active pixel");
        gate_drive_pixel(10'd100, 1'b0);
        if (gate_out_r !== 10'd0 || gate_out_g !== 10'd0 || gate_out_b !== 10'd0)
            fail("positive offset leaked into gated blanking interval");

        // --- VSYNC_ACTIVE_HIGH=0 tests ---
        vsl_write_reg(8'h00, 16'h0001);
        vsl_write_reg(8'h01, 16'h0800);
        vsl_write_reg(8'h7e, 16'hCA1B);
        @(posedge clk);
        vsl_expect_status(1'b1, 1'b0, "active-low DUT did not arm commit");

        // Inactive (high) vsync must not consume the commit.
        repeat (8) @(posedge clk);
        vsl_expect_status(1'b1, 1'b0, "inactive-high vsync consumed commit");
        if (vsl_out_vsync !== 1'b1)
            fail("out_vsync did not keep input polarity while idle high");

        // A one-cycle active-low glitch must be filtered out.
        vsl_pulse_active_low(1);
        vsl_expect_status(1'b1, 1'b0, "one-cycle active-low glitch consumed commit");

        // A real active-low pulse consumes the commit.
        vsl_pulse_active_low(4);
        vsl_expect_status(1'b0, 1'b1, "active-low vsync pulse did not consume commit");
        vsl_cfg_addr = 8'h21;
        #1;
        if (vsl_cfg_rdata !== 16'h0800)
            fail("active-low commit did not latch shadow gain");

        // The commit must consume at the START of the active-low pulse
        // (filtered active edge), not at its trailing return-to-high edge —
        // check while vsync is still held low.
        vsl_write_reg(8'h01, 16'h0700);
        vsl_write_reg(8'h7e, 16'hCA1B);
        @(posedge clk);
        vsl_expect_status(1'b1, 1'b0, "second active-low commit did not arm");
        @(negedge clk);
        vsl_in_vsync = 1'b0;
        repeat (5) @(posedge clk);
        vsl_expect_status(1'b0, 1'b1,
            "commit did not consume during the active-low pulse itself");
        @(negedge clk);
        vsl_in_vsync = 1'b1;
        repeat (2) @(posedge clk);
        vsl_cfg_addr = 8'h21;
        #1;
        if (vsl_cfg_rdata !== 16'h0700)
            fail("second active-low commit did not latch shadow gain");

        $display("PASS: wp_adjust option tests (GATE_BLANKING, VSYNC_ACTIVE_HIGH=0)");
        $finish;
    end
endmodule
