`timescale 1ns/1ps

// CDC helper for the wp_adjust logical register interface.
//
// This bridge accepts one 8-bit-address/16-bit-data transaction at a time from
// a board-local control clock and presents it to wp_adjust in the pixel clock
// domain. It is intentionally not an I2C/SPI/AXI-Lite slave; those outer
// transports remain board-specific and should adapt to this small request/ack
// interface.
//
// Contract:
//   - bus_req is accepted on its rising edge when bus_busy is low.
//   - bus_ack pulses for one bus_clk cycle when the transaction completes.
//   - bus_rdata is valid with bus_ack for reads.
//   - cfg_* outputs are synchronous to pix_clk and may connect directly to
//     wp_adjust.
//   - Assert bus_rst_n and pix_rst_n together at initialization, and hold the
//     bridge in reset until both clocks are running. Do not reset only one
//     clock domain while a transaction may be in flight.
//
// CDC method:
//   Request and acknowledge toggles cross through two-flop synchronizers. The
//   multi-bit request and response payloads are held stable until the matching
//   toggle returns, so the destination domain samples stable values only.

module wp_adjust_cdc_bridge (
    input  wire        bus_clk,
    input  wire        bus_rst_n,
    input  wire        pix_clk,
    input  wire        pix_rst_n,

    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [15:0] bus_wdata,
    output wire        bus_busy,
    output reg         bus_ack,
    output reg  [15:0] bus_rdata,

    output reg         cfg_wr_en,
    output reg  [7:0]  cfg_addr,
    output reg  [15:0] cfg_wdata,
    input  wire [15:0] cfg_rdata
);

    localparam PIX_IDLE = 1'b0;
    localparam PIX_DONE = 1'b1;

    reg        req_toggle_bus;
    reg        bus_req_d;
    reg        ack_toggle_bus_meta;
    reg        ack_toggle_bus_sync;
    reg        ack_toggle_bus_seen;
    reg        req_we_hold;
    reg [7:0]  req_addr_hold;
    reg [15:0] req_wdata_hold;

    reg        req_toggle_pix_meta;
    reg        req_toggle_pix_sync;
    reg        req_toggle_pix_seen;
    reg        ack_toggle_pix;
    reg        pix_state;
    reg [15:0] pix_rdata_hold;

    wire bus_req_rise = bus_req && !bus_req_d;

    assign bus_busy =
        (req_toggle_bus != ack_toggle_bus_sync) ||
        (ack_toggle_bus_sync != ack_toggle_bus_seen);

    always @(posedge bus_clk or negedge bus_rst_n) begin
        if (!bus_rst_n) begin
            req_toggle_bus      <= 1'b0;
            bus_req_d           <= 1'b0;
            ack_toggle_bus_meta <= 1'b0;
            ack_toggle_bus_sync <= 1'b0;
            ack_toggle_bus_seen <= 1'b0;
            req_we_hold         <= 1'b0;
            req_addr_hold       <= 8'h00;
            req_wdata_hold      <= 16'h0000;
            bus_ack             <= 1'b0;
            bus_rdata           <= 16'h0000;
        end else begin
            bus_req_d           <= bus_req;
            ack_toggle_bus_meta <= ack_toggle_pix;
            ack_toggle_bus_sync <= ack_toggle_bus_meta;
            bus_ack             <= 1'b0;

            if (ack_toggle_bus_sync != ack_toggle_bus_seen) begin
                ack_toggle_bus_seen <= ack_toggle_bus_sync;
                bus_rdata           <= pix_rdata_hold;
                bus_ack             <= 1'b1;
            end

            if (bus_req_rise && !bus_busy) begin
                req_we_hold    <= bus_we;
                req_addr_hold  <= bus_addr;
                req_wdata_hold <= bus_wdata;
                req_toggle_bus <= ~req_toggle_bus;
            end
        end
    end

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            req_toggle_pix_meta <= 1'b0;
            req_toggle_pix_sync <= 1'b0;
            req_toggle_pix_seen <= 1'b0;
            ack_toggle_pix      <= 1'b0;
            pix_state           <= PIX_IDLE;
            pix_rdata_hold      <= 16'h0000;
            cfg_wr_en           <= 1'b0;
            cfg_addr            <= 8'h00;
            cfg_wdata           <= 16'h0000;
        end else begin
            req_toggle_pix_meta <= req_toggle_bus;
            req_toggle_pix_sync <= req_toggle_pix_meta;

            case (pix_state)
                PIX_IDLE: begin
                    cfg_wr_en <= 1'b0;

                    if (req_toggle_pix_sync != req_toggle_pix_seen) begin
                        cfg_addr  <= req_addr_hold;
                        cfg_wdata <= req_wdata_hold;
                        cfg_wr_en <= req_we_hold;
                        pix_state <= PIX_DONE;
                    end
                end

                PIX_DONE: begin
                    cfg_wr_en           <= 1'b0;
                    pix_rdata_hold      <= cfg_rdata;
                    req_toggle_pix_seen <= req_toggle_pix_sync;
                    ack_toggle_pix      <= ~ack_toggle_pix;
                    pix_state           <= PIX_IDLE;
                end
            endcase
        end
    end

endmodule
