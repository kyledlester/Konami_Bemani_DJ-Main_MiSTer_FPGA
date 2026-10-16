// SPDX-License-Identifier: GPL-3.0-or-later
//
// The main CPU's ROM cache: the 68EC020's on-chip instruction cache, sized
// up, and serving data reads too. Direct-mapped, one 8-byte SDRAM granule a
// line, 2^LINES_LOG lines (11: 16 KB, 16 M10K).
//
// A hit costs what the main-board bench's ROM model costs, one wait state
// (docs/ROADMAP.md, Phase 0's budget): the tag and data RAMs are read every
// clock at the access unit's NEXT address (a_pre, gx_main's ua), so when the
// unit registers a ROM request the line is already on the RAMs' outputs,
// and ok is registered on the clock after cs. A miss fetches the granule
// through the SDRAM port and answers when it arrives.
//
// The CPU's 8 MB ROM window is sparse -- BIOS at 0, program and data from
// 0x200000 -- and the SDRAM image is packed: granule addresses from 0x200000
// up are moved down by 0x1e0000 (rtl/memory/gx_sdram_top.sv, BASE_MAINCPU).
// The tags are the CPU's addresses.
//
// Words are 68000 big-endian; the granule is SDRAM little-endian words with
// byte k at bits [8k +: 8].

module gx_romcache #(
    parameter LINES_LOG = 11
) (
    input             clk,
    input             rst,          // also invalidates every line (a sweep)

    input  [22:1]     a_pre,        // the unit's next address, for the speculative read
    input             cs,
    input  [22:1]     addr,
    output reg        ok,
    output reg [15:0] data,

    output reg        p_cs,         // the SDRAM port: a granule of the packed image
    output reg [19:0] p_addr,
    input             p_ok,
    input  [63:0]     p_data,

    output reg [15:0] dbg_hits,
    output reg [15:0] dbg_misses,
    output reg [19:0] dbg_addr,    // the last granule fetched from SDRAM
    output reg [63:0] dbg_data,
    // JTAG peek: a toggle asks for one granule, read back on dbg_addr/dbg_data
    // (the board's own memory dump; the CPU is usually halted when it is used)
    input             peek_t,
    input      [19:0] peek_addr
);

localparam TW = 20 - LINES_LOG;     // tag bits of the 20-bit granule address

wire [LINES_LOG-1:0] idx_pre = a_pre[3 +: LINES_LOG];
wire [LINES_LOG-1:0] idx     = addr[3 +: LINES_LOG];
wire [TW-1:0]        tag     = addr[22 -: TW];
wire [19:0]          g       = addr[22:3];
wire [19:0]          pk_g  = g - (addr[22:21] != 2'b00 ? 20'h3c000 : 20'h0);   // 0x1e0000 >> 3

reg                  t_we, d_we;
reg  [LINES_LOG-1:0] wa;
reg  [TW:0]          t_wd;
wire [TW:0]          t_q;
wire [63:0]          d_q;

gx_sdpram #(.AW(LINES_LOG), .DW(TW+1)) u_tag ( .clk, .we(t_we), .wa, .d(t_wd), .ra(idx_pre), .q(t_q) );
gx_sdpram #(.AW(LINES_LOG), .DW(64))   u_dat ( .clk, .we(d_we), .wa, .d(p_data), .ra(idx_pre), .q(d_q) );

wire hit = t_q[TW] && t_q[TW-1:0] == tag;

function [15:0] word( input [63:0] gr, input [1:0] w );
    word = { gr[16*w +: 8], gr[16*w+8 +: 8] };      // even byte high
endfunction

reg                  served, busy, sweeping;
// peek_t crosses from the probe's clock: two flops before it is believed,
// so peek_addr has settled by the time it is sampled (gx_main says more)
reg                  peek_t1, peek_t2;
always @(posedge clk) begin peek_t1 <= peek_t; peek_t2 <= peek_t1; end

reg                  peek_s, peek_busy;
reg  [LINES_LOG-1:0] sw_cnt;

always @(posedge clk) begin
    ok   <= 0;
    t_we <= 0; d_we <= 0;
    if( rst ) begin
        served <= 0; busy <= 0; p_cs <= 0;
        sweeping <= 1; sw_cnt <= 0;
        peek_busy <= 0; peek_s <= peek_t2;
        dbg_hits <= 0; dbg_misses <= 0;
    end else if( sweeping ) begin
        t_we <= 1; wa <= sw_cnt; t_wd <= 0;
        sw_cnt <= sw_cnt + 1'd1;
        if( &sw_cnt ) sweeping <= 0;
    end else begin
        if( !cs ) served <= 0;
        if( peek_busy ) begin
            if( p_ok ) begin
                peek_busy <= 0; p_cs <= 0;
                dbg_addr <= p_addr; dbg_data <= p_data;
            end
        end else if( peek_s != peek_t2 && !busy && !cs ) begin
            peek_busy <= 1; p_cs <= 1; p_addr <= peek_addr; peek_s <= peek_t2;
        end else if( busy ) begin
            if( p_ok ) begin
                p_cs <= 0; busy <= 0;
                t_we <= 1; d_we <= 1; wa <= idx; t_wd <= { 1'b1, tag };
                ok <= 1; data <= word( p_data, addr[2:1] ); served <= 1;
                dbg_addr <= p_addr; dbg_data <= p_data;
            end
        end else if( cs && !served ) begin
            if( hit ) begin
                ok <= 1; data <= word( d_q, addr[2:1] ); served <= 1;
                dbg_hits <= dbg_hits + 1'd1;
            end else begin
                busy <= 1; p_cs <= 1; p_addr <= pk_g;
                dbg_misses <= dbg_misses + 1'd1;
            end
        end
    end
end

endmodule
