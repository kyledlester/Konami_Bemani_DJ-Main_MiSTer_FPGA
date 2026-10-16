// SPDX-License-Identifier: GPL-3.0-or-later
//
// One 16-bit write into SDRAM from the 48 MHz side, onto an sdram_arbiter's
// download write path (96 MHz). The client raises req for a clock with the
// word; busy is high from that clock until the word is in SDRAM. The answer
// comes back on the clk_mem edge midway between two clk edges, as
// gx_rom_port's does (DJMain.sdc false-paths its hold).

module dj_wr_port (
    input             clk,          // 48 MHz
    input             clk_mem,      // 96 MHz, same PLL, phase 0
    input             rst,

    input             req,          // one clk: write this word
    input      [26:0] addr,         // byte address (bit 0 picks the lane with we16 = 0)
    input      [15:0] data,         // SDRAM lanes: [7:0] the even byte
    input       [1:0] be,           // [0] even byte (low lane), [1] odd byte (high lane)
    output            busy,

    output reg        dl_req,       // the arbiter's write path (clk_mem)
    output reg [26:0] dl_addr,
    output reg [15:0] dl_data,
    output reg        dl_we16,
    input             dl_busy
);

reg        req_t = 1'b0, done_t = 1'b0, done_s = 1'b0;
reg        pend = 1'b0;
reg [26:0] a_l;
reg [15:0] d_l;
reg  [1:0] be_l;

always @(posedge clk) begin
    done_s <= done_t;
    if (rst) pend <= 1'b0;
    else if (req) begin
        pend  <= 1'b1;
        a_l   <= addr;
        d_l   <= data;
        be_l  <= be;
        req_t <= ~req_t;
    end else if (pend && done_t != done_s) pend <= 1'b0;
end
assign busy = pend || req;

// clk_mem
reg req_s = 1'b0, tv = 1'b0, tv_m = 1'b0, got = 1'b0;
reg [1:0] st = 2'd0;
always @(posedge clk)     tv   <= ~tv;
always @(posedge clk_mem) tv_m <= tv;
wire midway = tv != tv_m;

always @(posedge clk_mem) begin
    req_s <= req_t;
    if (got && midway) begin done_t <= ~done_t; got <= 1'b0; end
    case (st)
    2'd0: if (req_s != req_t) begin
        // a lone byte goes in its own lane: sdram_arbiter puts a byte write
        // on the lane addr[0] names, from dl_data[7:0]
        dl_we16 <= &be_l;
        dl_addr <= &be_l ? { a_l[26:1], 1'b0 } : { a_l[26:1], be_l[1] };
        dl_data <= &be_l ? d_l : { 8'd0, be_l[1] ? d_l[15:8] : d_l[7:0] };
        dl_req  <= 1'b1;
        st      <= 2'd1;
    end
    2'd1: if (dl_busy) begin dl_req <= 1'b0; st <= 2'd2; end
    2'd2: if (!dl_busy) begin
        if (midway) done_t <= ~done_t; else got <= 1'b1;
        st <= 2'd0;
    end
    default: st <= 2'd0;
    endcase
end

endmodule
