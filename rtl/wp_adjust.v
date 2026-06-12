`timescale 1ns/1ps

// White point adjustment block for a streaming RGB video path.
//
// Intended placement:
//   pixel compensation -> wp_adjust -> LVDS transmitter
//
// Pixel-path latency is 2 clk cycles in both enabled and disabled modes.
// RGB values are processed every cycle; de/hsync/vsync are delayed to match
// the RGB path but do not gate the gain math during blanking.
//
// The cfg_* port is a small register-write/read interface intended to be
// driven by an existing I2C register slave in the pixel clock domain. If the
// I2C slave uses a different clock, synchronize cfg_wr_en/cfg_addr/cfg_wdata
// before connecting them here. COMMIT copies shadow registers to active
// registers after the next filtered rising edge of the (polarity-adjusted)
// in_vsync. in_vsync must be synchronous to clk; set VSYNC_ACTIVE_HIGH=0 if
// the integration's vsync is active-low (only commit timing is affected; the
// delayed out_vsync always carries the original polarity).
//
// Parameters:
//   PIXEL_BITS        pixel width per channel, supported range [4, 15]
//   FRAC_BITS         gain fractional bits, supported range [2, 15];
//                     out-of-range values fail at elaboration
//   VSYNC_ACTIVE_HIGH 1 (default): commit on filtered rising edge of in_vsync
//                     0: commit on filtered falling edge (active-low vsync)
//   GATE_BLANKING     0 (default): pixel math runs during blanking, so
//                     blanking-interval RGB values are not preserved
//                     1: out_r/g/b are forced to zero when delayed DE is low
//
// Register map, 16-bit data:
//   0x00 CONTROL shadow
//        bit 0: master enable for gain/offset datapath
//        bit 1: enable signed offsets; requires bit 0 to affect pixels
//   0x01 R_GAIN shadow, unsigned Q(COEFF_BITS-FRAC_BITS).FRAC_BITS
//   0x02 G_GAIN shadow, unsigned Q(COEFF_BITS-FRAC_BITS).FRAC_BITS
//   0x03 B_GAIN shadow, unsigned Q(COEFF_BITS-FRAC_BITS).FRAC_BITS
//        unity gain = 1 << FRAC_BITS, default 0x1000 for FRAC_BITS=12
//   0x04 R_OFFSET shadow, signed output-code offset
//   0x05 G_OFFSET shadow, signed output-code offset
//   0x06 B_OFFSET shadow, signed output-code offset
//   0x20 CONTROL active, read-only
//   0x21 R_GAIN active, read-only
//   0x22 G_GAIN active, read-only
//   0x23 B_GAIN active, read-only
//   0x24 R_OFFSET active, read-only
//   0x25 G_OFFSET active, read-only
//   0x26 B_OFFSET active, read-only
//   0x70 ID, read-only, 16'h57A1
//   0x71 VERSION, read-only, 16'h0113
//        bits 15:8: register-map major version, 8'h01 = scalar v1
//        bits  7:0: implementation revision, 8'h13
//   0x72 STATUS, read-only
//        bit 0: commit pending
//        bit 1: last commit consumed on vsync, sticky until next COMMIT/DEFAULTS
//        bit 2: active gain adjustment enabled
//        bit 3: active offsets enabled
//        bits 15:8: FRAC_BITS
//   0x7e COMMIT: write 16'hCA1B to copy shadow registers to active on the
//        next filtered active edge of in_vsync.
//        Write 16'hC0FF to cancel an armed commit; shadow and active
//        registers are left untouched. A cancel that races the commit vsync
//        edge may arrive after the update has latched; read the active
//        registers after canceling to confirm.
//        Do not write new shadow values while STATUS[0] is set.
//   0x7f DEFAULTS: write 16'hD65D to restore unity/pass-through defaults immediately
//
// Recommended calibration usage:
//   - Prefer reducing the stronger channels instead of boosting weaker ones.
//   - Keep one channel, commonly green, at unity when possible.
//   - Use offsets only for low-level grayscale tint correction; leave disabled
//     for normal white-point trim.

module wp_adjust #(
    parameter PIXEL_BITS = 10,
    parameter FRAC_BITS  = 12,
    parameter VSYNC_ACTIVE_HIGH = 1,
    parameter GATE_BLANKING = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [PIXEL_BITS-1:0] in_r,
    input  wire [PIXEL_BITS-1:0] in_g,
    input  wire [PIXEL_BITS-1:0] in_b,
    input  wire                  in_de,
    input  wire                  in_hsync,
    input  wire                  in_vsync,

    output reg  [PIXEL_BITS-1:0] out_r,
    output reg  [PIXEL_BITS-1:0] out_g,
    output reg  [PIXEL_BITS-1:0] out_b,
    output reg                   out_de,
    output reg                   out_hsync,
    output reg                   out_vsync,

    input  wire                  cfg_wr_en,
    input  wire [7:0]            cfg_addr,
    input  wire [15:0]           cfg_wdata,
    output reg  [15:0]           cfg_rdata
);

    localparam COEFF_BITS = 16;
    localparam ACC_BITS = PIXEL_BITS + COEFF_BITS + 4;
    localparam [15:0] WP_ADJUST_ID = 16'h57A1;
    localparam [15:0] WP_ADJUST_VERSION = 16'h0113;

    // Elaboration-time parameter guards. Out-of-range parameters reference a
    // module that intentionally does not exist, so elaboration/synthesis
    // fails with the range encoded in the error message instead of producing
    // silently broken hardware (e.g. FRAC_BITS=16 would overflow UNITY_GAIN
    // to zero and reset to a black screen).
    generate
        if (FRAC_BITS < 2 || FRAC_BITS > 15) begin : gen_frac_bits_range_check
            wp_adjust_ERROR_FRAC_BITS_supported_range_is_2_to_15 u_frac_bits_guard();
        end
        if (PIXEL_BITS < 4 || PIXEL_BITS > 15) begin : gen_pixel_bits_range_check
            wp_adjust_ERROR_PIXEL_BITS_supported_range_is_4_to_15 u_pixel_bits_guard();
        end
    endgenerate
    localparam [7:0] FRAC_BITS_BYTE = FRAC_BITS;
    localparam [COEFF_BITS-1:0] UNITY_GAIN =
        ({{(COEFF_BITS-1){1'b0}}, 1'b1} << FRAC_BITS);
    localparam signed [ACC_BITS-1:0] ROUND_Q =
        {{(ACC_BITS-FRAC_BITS){1'b0}}, 1'b1, {(FRAC_BITS-1){1'b0}}};
    localparam signed [ACC_BITS-1:0] MAX_PIXEL_ACC =
        {{(ACC_BITS-PIXEL_BITS){1'b0}}, {PIXEL_BITS{1'b1}}};

    reg                  shadow_enable;
    reg                  shadow_offset_enable;
    reg [COEFF_BITS-1:0] shadow_r_gain;
    reg [COEFF_BITS-1:0] shadow_g_gain;
    reg [COEFF_BITS-1:0] shadow_b_gain;
    reg signed [15:0]    shadow_r_offset;
    reg signed [15:0]    shadow_g_offset;
    reg signed [15:0]    shadow_b_offset;

    reg                  active_enable;
    reg                  active_offset_enable;
    reg [COEFF_BITS-1:0] active_r_gain;
    reg [COEFF_BITS-1:0] active_g_gain;
    reg [COEFF_BITS-1:0] active_b_gain;
    reg signed [15:0]    active_r_offset;
    reg signed [15:0]    active_g_offset;
    reg signed [15:0]    active_b_offset;
    reg                  commit_pending;
    reg                  commit_consumed;
    reg                  vsync_filter_s0;
    reg                  vsync_filter_s1;
    reg                  vsync_filtered_d;

    reg signed [ACC_BITS-1:0] r_scaled_s1;
    reg signed [ACC_BITS-1:0] g_scaled_s1;
    reg signed [ACC_BITS-1:0] b_scaled_s1;
    reg signed [ACC_BITS-1:0] r_offset_s1;
    reg signed [ACC_BITS-1:0] g_offset_s1;
    reg signed [ACC_BITS-1:0] b_offset_s1;
    reg                       de_s1;
    reg                       hsync_s1;
    reg                       vsync_s1;

    function [PIXEL_BITS-1:0] sat_round_to_pixel;
        input signed [ACC_BITS-1:0] value_q;
        reg signed [ACC_BITS-1:0] rounded_q;
        reg signed [ACC_BITS-1:0] shifted;
        begin
            if (value_q[ACC_BITS-1] || (value_q == {ACC_BITS{1'b0}})) begin
                sat_round_to_pixel = {PIXEL_BITS{1'b0}};
            end else begin
                rounded_q = value_q + ROUND_Q;
                shifted = rounded_q >>> FRAC_BITS;

                if (shifted > MAX_PIXEL_ACC) begin
                    sat_round_to_pixel = {PIXEL_BITS{1'b1}};
                end else begin
                    sat_round_to_pixel = shifted[PIXEL_BITS-1:0];
                end
            end
        end
    endfunction

    wire signed [ACC_BITS-1:0] r_offset_ext =
        $signed({{(ACC_BITS-16){active_r_offset[15]}}, active_r_offset}) <<< FRAC_BITS;
    wire signed [ACC_BITS-1:0] g_offset_ext =
        $signed({{(ACC_BITS-16){active_g_offset[15]}}, active_g_offset}) <<< FRAC_BITS;
    wire signed [ACC_BITS-1:0] b_offset_ext =
        $signed({{(ACC_BITS-16){active_b_offset[15]}}, active_b_offset}) <<< FRAC_BITS;

    wire signed [ACC_BITS-1:0] r_passthrough_q =
        $signed({{(ACC_BITS-PIXEL_BITS){1'b0}}, in_r}) <<< FRAC_BITS;
    wire signed [ACC_BITS-1:0] g_passthrough_q =
        $signed({{(ACC_BITS-PIXEL_BITS){1'b0}}, in_g}) <<< FRAC_BITS;
    wire signed [ACC_BITS-1:0] b_passthrough_q =
        $signed({{(ACC_BITS-PIXEL_BITS){1'b0}}, in_b}) <<< FRAC_BITS;

    // Commit timing uses the polarity-adjusted vsync; the datapath delay of
    // out_vsync is taken from the raw in_vsync and keeps the input polarity.
    wire vsync_commit_level = (VSYNC_ACTIVE_HIGH != 0) ? in_vsync : ~in_vsync;

    wire vsync_filtered = vsync_filter_s0 & vsync_filter_s1;
    wire vsync_rise = vsync_filtered & ~vsync_filtered_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shadow_enable        <= 1'b0;
            shadow_offset_enable <= 1'b0;
            shadow_r_gain        <= UNITY_GAIN;
            shadow_g_gain        <= UNITY_GAIN;
            shadow_b_gain        <= UNITY_GAIN;
            shadow_r_offset      <= 16'sd0;
            shadow_g_offset      <= 16'sd0;
            shadow_b_offset      <= 16'sd0;

            active_enable        <= 1'b0;
            active_offset_enable <= 1'b0;
            active_r_gain        <= UNITY_GAIN;
            active_g_gain        <= UNITY_GAIN;
            active_b_gain        <= UNITY_GAIN;
            active_r_offset      <= 16'sd0;
            active_g_offset      <= 16'sd0;
            active_b_offset      <= 16'sd0;
            commit_pending       <= 1'b0;
            commit_consumed      <= 1'b0;
            vsync_filter_s0      <= 1'b0;
            vsync_filter_s1      <= 1'b0;
            vsync_filtered_d     <= 1'b0;
        end else begin
            vsync_filter_s0  <= vsync_commit_level;
            vsync_filter_s1  <= vsync_filter_s0;
            vsync_filtered_d <= vsync_filtered;

            if (commit_pending && vsync_rise) begin
                active_enable        <= shadow_enable;
                active_offset_enable <= shadow_offset_enable;
                active_r_gain        <= shadow_r_gain;
                active_g_gain        <= shadow_g_gain;
                active_b_gain        <= shadow_b_gain;
                active_r_offset      <= shadow_r_offset;
                active_g_offset      <= shadow_g_offset;
                active_b_offset      <= shadow_b_offset;
                commit_pending       <= 1'b0;
                commit_consumed      <= 1'b1;
            end

            if (cfg_wr_en) begin
                case (cfg_addr)
                    8'h00: begin
                        shadow_enable        <= cfg_wdata[0];
                        shadow_offset_enable <= cfg_wdata[1];
                    end
                    8'h01: shadow_r_gain   <= cfg_wdata[COEFF_BITS-1:0];
                    8'h02: shadow_g_gain   <= cfg_wdata[COEFF_BITS-1:0];
                    8'h03: shadow_b_gain   <= cfg_wdata[COEFF_BITS-1:0];
                    8'h04: shadow_r_offset <= cfg_wdata;
                    8'h05: shadow_g_offset <= cfg_wdata;
                    8'h06: shadow_b_offset <= cfg_wdata;

                    8'h7e: begin
                        if (cfg_wdata == 16'hCA1B) begin
                            commit_pending  <= 1'b1;
                            commit_consumed <= 1'b0;
                        end else if (cfg_wdata == 16'hC0FF) begin
                            // Cancel an armed commit; shadow and active
                            // registers are left untouched.
                            commit_pending  <= 1'b0;
                            commit_consumed <= 1'b0;
                        end
                    end

                    8'h7f: begin
                        if (cfg_wdata == 16'hD65D) begin
                            shadow_enable        <= 1'b0;
                            shadow_offset_enable <= 1'b0;
                            shadow_r_gain        <= UNITY_GAIN;
                            shadow_g_gain        <= UNITY_GAIN;
                            shadow_b_gain        <= UNITY_GAIN;
                            shadow_r_offset      <= 16'sd0;
                            shadow_g_offset      <= 16'sd0;
                            shadow_b_offset      <= 16'sd0;

                            active_enable        <= 1'b0;
                            active_offset_enable <= 1'b0;
                            active_r_gain        <= UNITY_GAIN;
                            active_g_gain        <= UNITY_GAIN;
                            active_b_gain        <= UNITY_GAIN;
                            active_r_offset      <= 16'sd0;
                            active_g_offset      <= 16'sd0;
                            active_b_offset      <= 16'sd0;
                            commit_pending       <= 1'b0;
                            commit_consumed      <= 1'b0;
                        end
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

    always @(*) begin
        case (cfg_addr)
            8'h00: cfg_rdata = {14'd0, shadow_offset_enable, shadow_enable};
            8'h01: cfg_rdata = shadow_r_gain;
            8'h02: cfg_rdata = shadow_g_gain;
            8'h03: cfg_rdata = shadow_b_gain;
            8'h04: cfg_rdata = shadow_r_offset;
            8'h05: cfg_rdata = shadow_g_offset;
            8'h06: cfg_rdata = shadow_b_offset;

            8'h20: cfg_rdata = {14'd0, active_offset_enable, active_enable};
            8'h21: cfg_rdata = active_r_gain;
            8'h22: cfg_rdata = active_g_gain;
            8'h23: cfg_rdata = active_b_gain;
            8'h24: cfg_rdata = active_r_offset;
            8'h25: cfg_rdata = active_g_offset;
            8'h26: cfg_rdata = active_b_offset;

            8'h70: cfg_rdata = WP_ADJUST_ID;
            8'h71: cfg_rdata = WP_ADJUST_VERSION;
            8'h72: cfg_rdata = {FRAC_BITS_BYTE, 4'd0, active_offset_enable,
                                active_enable, commit_consumed, commit_pending};

            default: cfg_rdata = 16'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_scaled_s1 <= {ACC_BITS{1'b0}};
            g_scaled_s1 <= {ACC_BITS{1'b0}};
            b_scaled_s1 <= {ACC_BITS{1'b0}};
            r_offset_s1 <= {ACC_BITS{1'b0}};
            g_offset_s1 <= {ACC_BITS{1'b0}};
            b_offset_s1 <= {ACC_BITS{1'b0}};
            de_s1       <= 1'b0;
            hsync_s1    <= 1'b0;
            vsync_s1    <= 1'b0;
            out_r       <= {PIXEL_BITS{1'b0}};
            out_g       <= {PIXEL_BITS{1'b0}};
            out_b       <= {PIXEL_BITS{1'b0}};
            out_de      <= 1'b0;
            out_hsync   <= 1'b0;
            out_vsync   <= 1'b0;
        end else begin
            de_s1    <= in_de;
            hsync_s1 <= in_hsync;
            vsync_s1 <= in_vsync;

            if (active_enable) begin
                r_scaled_s1 <= $signed({1'b0, in_r}) * $signed({1'b0, active_r_gain});
                g_scaled_s1 <= $signed({1'b0, in_g}) * $signed({1'b0, active_g_gain});
                b_scaled_s1 <= $signed({1'b0, in_b}) * $signed({1'b0, active_b_gain});
            end else begin
                r_scaled_s1 <= r_passthrough_q;
                g_scaled_s1 <= g_passthrough_q;
                b_scaled_s1 <= b_passthrough_q;
            end

            if (active_enable && active_offset_enable) begin
                r_offset_s1 <= r_offset_ext;
                g_offset_s1 <= g_offset_ext;
                b_offset_s1 <= b_offset_ext;
            end else begin
                r_offset_s1 <= {ACC_BITS{1'b0}};
                g_offset_s1 <= {ACC_BITS{1'b0}};
                b_offset_s1 <= {ACC_BITS{1'b0}};
            end

            if (GATE_BLANKING != 0 && !de_s1) begin
                out_r <= {PIXEL_BITS{1'b0}};
                out_g <= {PIXEL_BITS{1'b0}};
                out_b <= {PIXEL_BITS{1'b0}};
            end else begin
                out_r <= sat_round_to_pixel(r_scaled_s1 + r_offset_s1);
                out_g <= sat_round_to_pixel(g_scaled_s1 + g_offset_s1);
                out_b <= sat_round_to_pixel(b_scaled_s1 + b_offset_s1);
            end
            out_de    <= de_s1;
            out_hsync <= hsync_s1;
            out_vsync <= vsync_s1;
        end
    end

endmodule
