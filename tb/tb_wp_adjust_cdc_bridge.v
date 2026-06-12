`timescale 1ns/1ps

module tb_wp_adjust_cdc_bridge;
    localparam PIXEL_BITS = 10;
    localparam FRAC_BITS = 12;

    reg bus_clk;
    reg bus_rst_n;
    reg bus_req;
    reg bus_we;
    reg [7:0] bus_addr;
    reg [15:0] bus_wdata;
    wire bus_busy;
    wire bus_ack;
    wire [15:0] bus_rdata;

    reg pix_clk;
    reg pix_rst_n;
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

    wire cfg_wr_en;
    wire [7:0] cfg_addr;
    wire [15:0] cfg_wdata;
    wire [15:0] cfg_rdata;
    integer cfg_write_count;

    wp_adjust_cdc_bridge bridge (
        .bus_clk(bus_clk),
        .bus_rst_n(bus_rst_n),
        .pix_clk(pix_clk),
        .pix_rst_n(pix_rst_n),
        .bus_req(bus_req),
        .bus_we(bus_we),
        .bus_addr(bus_addr),
        .bus_wdata(bus_wdata),
        .bus_busy(bus_busy),
        .bus_ack(bus_ack),
        .bus_rdata(bus_rdata),
        .cfg_wr_en(cfg_wr_en),
        .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata),
        .cfg_rdata(cfg_rdata)
    );

    wp_adjust #(
        .PIXEL_BITS(PIXEL_BITS),
        .FRAC_BITS(FRAC_BITS)
    ) dut (
        .clk(pix_clk),
        .rst_n(pix_rst_n),
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

    // Bus-clock half period is overridable so `make test` can sweep ratios:
    // slower bus (default 7), faster bus (+bus_half=3), and an integer-related
    // 2:1 ratio (+bus_half=10) against the fixed 5ns pixel half period.
    integer bus_half_period;
    initial begin
        if (!$value$plusargs("bus_half=%d", bus_half_period))
            bus_half_period = 7;
        $display("CDC bridge test: bus half period %0d ns, pix half period 5 ns",
                 bus_half_period);
        bus_clk = 1'b0;
        forever #(bus_half_period) bus_clk = ~bus_clk;
    end

    initial pix_clk = 1'b0;
    always #5 pix_clk = ~pix_clk;

    always @(posedge pix_clk) begin
        if (!pix_rst_n) begin
            cfg_write_count <= 0;
        end else if (cfg_wr_en) begin
            cfg_write_count <= cfg_write_count + 1;
        end
    end

    task fail;
        input [511:0] msg;
        begin
            $display("FAIL: %0s", msg);
            $finish;
        end
    endtask

    task bus_write;
        input [7:0] addr;
        input [15:0] data;
        begin
            @(negedge bus_clk);
            while (bus_busy) @(negedge bus_clk);
            bus_addr = addr;
            bus_wdata = data;
            bus_we = 1'b1;
            bus_req = 1'b1;
            @(negedge bus_clk);
            bus_req = 1'b0;
            bus_we = 1'b0;
            bus_addr = 8'h00;
            bus_wdata = 16'h0000;
            while (!bus_ack) @(posedge bus_clk);
        end
    endtask

    task bus_write_held_req;
        input [7:0] addr;
        input [15:0] data;
        input [511:0] msg;
        integer count_before;
        begin
            @(negedge bus_clk);
            while (bus_busy) @(negedge bus_clk);
            count_before = cfg_write_count;
            bus_addr = addr;
            bus_wdata = data;
            bus_we = 1'b1;
            bus_req = 1'b1;
            while (!bus_ack) @(posedge bus_clk);
            repeat (12) @(posedge bus_clk);
            bus_req = 1'b0;
            bus_we = 1'b0;
            bus_addr = 8'h00;
            bus_wdata = 16'h0000;
            repeat (4) @(posedge pix_clk);
            if (cfg_write_count !== count_before + 1) begin
                $display("FAIL: %0s repeated transaction count_before=%0d count_after=%0d",
                         msg, count_before, cfg_write_count);
                $finish;
            end
        end
    endtask

    task bus_read;
        input [7:0] addr;
        output [15:0] data;
        begin
            @(negedge bus_clk);
            while (bus_busy) @(negedge bus_clk);
            bus_addr = addr;
            bus_wdata = 16'h0000;
            bus_we = 1'b0;
            bus_req = 1'b1;
            @(negedge bus_clk);
            bus_req = 1'b0;
            bus_addr = 8'h00;
            while (!bus_ack) @(posedge bus_clk);
            data = bus_rdata;
        end
    endtask

    task expect_read;
        input [7:0] addr;
        input [15:0] exp;
        input [511:0] msg;
        reg [15:0] data;
        begin
            bus_read(addr, data);
            if (data !== exp) begin
                $display("FAIL: %0s read 0x%02x got 0x%04x expected 0x%04x",
                         msg, addr, data, exp);
                $finish;
            end
        end
    endtask

    task expect_status_bits;
        input exp_pending;
        input exp_consumed;
        input [511:0] msg;
        reg [15:0] status;
        begin
            bus_read(8'h72, status);
            if (status[0] !== exp_pending || status[1] !== exp_consumed) begin
                $display("FAIL: %0s got pending=%0b consumed=%0b expected pending=%0b consumed=%0b",
                         msg, status[0], status[1], exp_pending, exp_consumed);
                $finish;
            end
        end
    endtask

    task pulse_vsync;
        input integer high_cycles;
        integer i;
        begin
            @(negedge pix_clk);
            in_vsync = 1'b1;
            for (i = 0; i < high_cycles; i = i + 1) begin
                @(posedge pix_clk);
            end
            @(negedge pix_clk);
            in_vsync = 1'b0;
            repeat (2) @(posedge pix_clk);
        end
    endtask

    initial begin
        bus_rst_n = 1'b0;
        bus_req = 1'b0;
        bus_we = 1'b0;
        bus_addr = 8'h00;
        bus_wdata = 16'h0000;

        pix_rst_n = 1'b0;
        in_r = {PIXEL_BITS{1'b0}};
        in_g = {PIXEL_BITS{1'b0}};
        in_b = {PIXEL_BITS{1'b0}};
        in_de = 1'b0;
        in_hsync = 1'b0;
        in_vsync = 1'b0;

        repeat (4) @(posedge bus_clk);
        repeat (4) @(posedge pix_clk);
        bus_rst_n = 1'b1;
        pix_rst_n = 1'b1;
        repeat (4) @(posedge bus_clk);
        repeat (4) @(posedge pix_clk);

        expect_read(8'h70, 16'h57A1, "ID did not cross CDC bridge");
        expect_read(8'h71, 16'h0113, "VERSION did not cross CDC bridge");
        expect_read(8'h72, 16'h0C00, "reset STATUS mismatch");

        bus_write(8'h00, 16'h0001);
        bus_write(8'h01, 16'h0800);
        bus_write(8'h02, 16'h1000);
        bus_write(8'h03, 16'h1800);

        expect_read(8'h01, 16'h0800, "shadow R write lost");
        expect_read(8'h02, 16'h1000, "shadow G write lost");
        expect_read(8'h03, 16'h1800, "shadow B write lost");
        expect_read(8'h21, 16'h1000, "active R changed before COMMIT");
        expect_read(8'h23, 16'h1000, "active B changed before COMMIT");

        bus_write(8'h7e, 16'hCA1B);
        expect_status_bits(1'b1, 1'b0, "COMMIT did not set pending");
        expect_read(8'h21, 16'h1000, "active R changed before vsync");
        pulse_vsync(4);
        expect_status_bits(1'b0, 1'b1, "COMMIT did not consume after vsync");
        expect_read(8'h21, 16'h0800, "active R did not update after vsync");
        expect_read(8'h23, 16'h1800, "active B did not update after vsync");

        bus_write(8'h01, 16'h0400);
        bus_write(8'h02, 16'h0400);
        bus_write(8'h03, 16'h0400);
        bus_write(8'h7e, 16'hCA1B);
        expect_status_bits(1'b1, 1'b0, "second COMMIT did not set pending");
        expect_status_bits(1'b1, 1'b0, "pending state was not stable before vsync");
        pulse_vsync(1);
        expect_status_bits(1'b1, 1'b0, "one-cycle vsync glitch consumed commit");
        expect_read(8'h21, 16'h0800, "active R changed on vsync glitch");
        pulse_vsync(4);
        expect_status_bits(1'b0, 1'b1, "second COMMIT did not consume");
        expect_read(8'h21, 16'h0400, "second active R update lost");

        bus_write(8'h01, 16'h2000);
        bus_write(8'h7e, 16'hCA1B);
        expect_status_bits(1'b1, 1'b0, "pending before DEFAULTS did not set");
        bus_write(8'h7f, 16'hD65D);
        expect_status_bits(1'b0, 1'b0, "DEFAULTS did not clear pending");
        expect_read(8'h21, 16'h1000, "DEFAULTS did not restore active R");
        pulse_vsync(4);
        expect_read(8'h21, 16'h1000, "stale pending commit survived DEFAULTS");

        bus_write(8'h01, 16'h0900);
        bus_write(8'h7e, 16'hCA1B);
        expect_status_bits(1'b1, 1'b0, "commit before cancel did not arm");
        bus_write(8'h7e, 16'hC0FF);
        expect_status_bits(1'b0, 1'b0, "cancel did not clear pending across bridge");
        expect_read(8'h01, 16'h0900, "cancel corrupted shadow across bridge");
        expect_read(8'h21, 16'h1000, "cancel changed active across bridge");
        pulse_vsync(4);
        expect_read(8'h21, 16'h1000, "cancelled commit latched across bridge");

        bus_write_held_req(8'h01, 16'h0700, "held bus_req re-fired write");
        expect_read(8'h01, 16'h0700, "held bus_req write did not land once");

        $display("PASS: wp_adjust CDC bridge tests");
        $finish;
    end
endmodule
