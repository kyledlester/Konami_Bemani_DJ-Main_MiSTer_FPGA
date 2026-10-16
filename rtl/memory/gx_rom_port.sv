// SPDX-License-Identifier: GPL-3.0-or-later
//
// One graphics-ROM client of the SDRAM arbiter, with the clock crossing.
//
// The client side is what the video benches' ROM models give the RTL
// (sim/gx_tilemap_tb, sim/gx_obj_tb): cs is a level and addr is held; ok
// pulses for one clk with data; while cs stays high a new addr starts a new
// fetch, and an addr that changes during a fetch is fetched again with no ok
// for the old one; cs dropped and raised asks again at the same addr.
// jtframe_draw keeps cs high across the two halves of a sprite row and
// gx_tilemap drops it after each row, and both are served by this.
//
// NS granules are kept here, so an address asked for again is answered in a
// clock: the regions are read-only once downloaded, so a held granule can
// never be stale. Two of them are filled ahead of the client:
//
//   the pair      the other granule of the row just served (PAIR=1): the
//                 drawer asks for a row's second half eight pixels after the
//                 first, which is less than one SDRAM fetch.
//   the hint      an address the client says it will ask for soon
//                 (hint_cs/hint_addr). The sprite scan knows the next tile
//                 of a sprite while the drawer is still on this one, and
//                 without it every row pays a whole fetch before its first
//                 pixel -- what runs the scan out of line time on the board.
//
// Speculation only uses the port while the client is not waiting, so it
// cannot delay a fetch the client is asking for.
//
// clk is 48 MHz and clk_mem 96 MHz from the same PLL at phase 0, so every
// clk edge is a clk_mem edge and the crossings are ordinary timed paths: a
// request toggle goes over, the arbiter is held until c_valid, the granule
// is registered here in clk_mem and a done toggle comes back. Nothing is
// pulsed across, because a one-clk_mem pulse is missed by clk half the time.

module gx_rom_port #(
    parameter AW = 21,              // granule (8-byte) address bits from the client
    parameter PAIR = 0,             // 1: fetch a row's other half, and take hints
    parameter NS = 4,               // granules held
    // 1: a fetch outside halfsel asks the arbiter for the granule and its
    // pair (addr ^ 1) in one double read, and both are kept: a 5, 6 or 8 bpp
    // sprite row is two granules, and one SDRAM access for both costs four
    // clk_mem more than one, where two cost two round trips
    parameter DBL = 0
) (
    input             clk,          // the client's, 48 MHz
    input             clk_mem,      // the arbiter's, 96 MHz
    input             rst,

    input             cs,
    input  [AW-1:0]   addr,         // granule address within the region
    output reg        ok,
    output reg [63:0] data,

    input             hint_cs,      // PAIR=1: a granule the client will want
    input  [AW-1:0]   hint_addr,
    // drop every held granule: for a client that also writes the memory it
    // reads (the K054539s' RAM), since held granules are otherwise trusted
    // never to go stale
    input             inval,
    // 1: the client's address is a half-granule (four bytes); the granule
    // holding it is fetched and its half returned in data[31:0] (K055673
    // RNG sprites: two 4-byte half-rows a granule)
    input             halfsel,

    input  [26:0]     base,         // the region's byte address in SDRAM
    output reg        c_req,        // arbiter client (clk_mem)
    output reg [26:0] c_addr,
    output reg        c_dbl,        // DBL: this request is a double read
    input             c_valid,
    input  [63:0]     c_rdata,
    input  [63:0]     c_rdata2      // DBL: the pair's odd granule
);

localparam VW = NS == 1 ? 1 : $clog2(NS);

// ------------------------------------------------------------ clk
reg  [AW-1:0] s_addr [0:NS-1];
reg  [63:0]   s_data [0:NS-1];
reg  [NS-1:0] s_val;
reg  [VW-1:0] vic;              // round-robin replacement

integer i;
reg           hit_v;
reg  [VW-1:0] hit_i;
always @* begin
    hit_v = 1'b0;
    hit_i = {VW{1'b0}};
    for( i=0; i<NS; i=i+1 )
        if( !hit_v && s_val[i] && s_addr[i]==addr ) begin
            hit_v = 1'b1;
            hit_i = VW'(i);
        end
end

function automatic held( input [AW-1:0] a );
    integer j;
    begin
        held = 1'b0;
        for( j=0; j<NS; j=j+1 ) if( s_val[j] && s_addr[j]==a ) held = 1'b1;
    end
endfunction

reg           busy;
reg  [AW-1:0] a_l;              // the fetch in flight
reg           ansd;             // ok was pulsed for ans_addr, cs still high
reg  [AW-1:0] ans_addr;
reg  [63:0]   data_m;
reg  [63:0]   data_f;           // halfsel: the whole granule; DBL: the pair's other granule
wire [VW-1:0] vic2 = vic==VW'(NS-1) ? {VW{1'b0}} : vic + 1'd1;
reg           req_t = 0, done_t = 0, done_s = 0;
wire          done   = done_t != done_s;

wire [AW-1:0] pair_a = { ans_addr[AW-1:1], ~ans_addr[0] };
wire          want   = cs && !(ansd && addr==ans_addr);
wire          pf_pair = PAIR==1 && ansd    && !held(pair_a)   && !(busy && a_l==pair_a);
wire          pf_hint = PAIR==1 && hint_cs && !held(hint_addr) && !(busy && a_l==hint_addr);

always @(posedge clk) begin
    ok     <= 0;
    done_s <= done_t;
    if( rst ) begin
        busy <= 0; s_val <= {NS{1'b0}}; vic <= 0; ansd <= 0;
    end else begin
        if( !cs ) ansd <= 0;
        if( inval ) s_val <= {NS{1'b0}};
        if( busy ) begin
            if( done ) begin
                busy         <= 0;
                s_addr[vic]  <= a_l;
                s_data[vic]  <= data_m;
                s_val[vic]   <= 1'b1;
                vic          <= vic==VW'(NS-1) ? {VW{1'b0}} : vic + 1'd1;
                // halfsel: the granule is both halves of a row, and both are
                // kept -- the other half would otherwise be fetched again
                if( halfsel && NS > 1 ) begin
                    s_addr[vic2] <= { a_l[AW-1:1], ~a_l[0] };
                    s_data[vic2] <= a_l[0] ? { 32'd0, data_f[31:0] } : { 32'd0, data_f[63:32] };
                    s_val[vic2]  <= 1'b1;
                    vic          <= vic2==VW'(NS-1) ? {VW{1'b0}} : vic2 + 1'd1;
                end else if( DBL && NS > 1 ) begin
                    s_addr[vic2] <= { a_l[AW-1:1], ~a_l[0] };
                    s_data[vic2] <= data_f;
                    s_val[vic2]  <= 1'b1;
                    vic          <= vic2==VW'(NS-1) ? {VW{1'b0}} : vic2 + 1'd1;
                end
                if( want && addr==a_l ) begin
                    ok <= 1; data <= data_m; ansd <= 1; ans_addr <= addr;
                end else if( want && hit_v ) begin
                    ok <= 1; data <= s_data[hit_i]; ansd <= 1; ans_addr <= addr;
                end
            end else if( want && hit_v ) begin
                // a held granule is answered while a prefetch is in flight:
                // with two pixels a clock a half-row draws in four clocks,
                // and waiting out the next row's fetch cost more than that
                ok <= 1; data <= s_data[hit_i]; ansd <= 1; ans_addr <= addr;
            end
        end else if( want && hit_v ) begin
            ok <= 1; data <= s_data[hit_i]; ansd <= 1; ans_addr <= addr;
        end else if( want ) begin
            busy <= 1; a_l <= addr;      req_t <= ~req_t;
        end else if( pf_pair ) begin
            busy <= 1; a_l <= pair_a;    req_t <= ~req_t;
        end else if( pf_hint ) begin
            busy <= 1; a_l <= hint_addr; req_t <= ~req_t;
        end
    end
end

// ------------------------------------------------------------ clk_mem
reg  req_s = 0;
wire start = req_t != req_s;

// The answer comes back only on a clk_mem edge midway between two clk
// edges. clk's tree arrives ~1 ns after clk_mem's, and a done_t that
// changed on an edge the two share could reach done_s in the same edge
// when the fitter put them side by side (a 0.6 ns hop; four builds failed
// hold there, on u_snd and u_tile): the fetch was then never seen done.
// Changing only midway gives done_s half a clk period of setup and of
// hold; KonamiGX.sdc false-paths the hold check, which cannot know it.
// tv toggles on every clk edge and tv_m follows it on clk_mem, so they
// differ just before each midway edge (tv -> tv_m is launched by the later
// clock: safe for hold). data_m and data_f are taken with the answer and
// are read only once done is seen, a clk later.
reg  tv = 0, tv_m = 0, got = 0;
always @(posedge clk)     tv   <= ~tv;
always @(posedge clk_mem) tv_m <= tv;
wire midway = tv != tv_m;

always @(posedge clk_mem) begin
    req_s <= req_t;
    if( rst ) begin
        c_req <= 0; got <= 0;
    end else begin
        if( got && midway ) begin
            done_t <= ~done_t;
            got    <= 0;
        end
        if( start ) begin
            c_req  <= 1;
            c_dbl  <= DBL && !halfsel;
            c_addr <= base + ( halfsel ? 27'({ a_l[AW-1:1], 3'b000 })          // the row's granule
                             : DBL     ? 27'({ a_l[AW-1:1], 1'b0, 3'b000 })    // the pair's even one
                                       : 27'({ a_l, 3'b000 }) );
        end
        if( c_req && c_valid ) begin
            c_req  <= 0;
            data_m <= halfsel ? ( a_l[0] ? { 32'd0, c_rdata[63:32] } : { 32'd0, c_rdata[31:0] } ) :
                      DBL     ? ( a_l[0] ? c_rdata2 : c_rdata ) : c_rdata;
            data_f <= halfsel ? c_rdata : a_l[0] ? c_rdata : c_rdata2;
            if( midway ) done_t <= ~done_t;     // on this edge, or the next midway one
            else         got    <= 1;
        end
    end
end

endmodule
