// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami DJ Main sprites (the 001642): djmain.cpp draw_sprites() as a line
// renderer. New for this core; the method -- a list snapshot, then a line
// buffer pair rendered a line ahead -- is the one KonamiGX's sprite path uses.
//
// THE LIST (MAME's sortedlist). At the start of vblank (copy_start) sprite
// RAM is copied raw into a shadow (512 clocks, ahead of the game's vblank
// handler, which rewrites the list), and its 128 entries are walked in order; each one with bit 15 (active) set and
// bit 31 (skip) clear claims the slot its bits 6-0 name, a later entry
// taking the slot from an earlier one. Its record goes into that slot with
// everything the line renderer would otherwise divide for:
//   xscale = 0x400000 / zoomX, yscale = 0x400000 / zoomY   (16.16, 1.0 = 0x10000)
//   ox -= (size * xscale) >> 13, oy likewise               (the position is the centre)
//   a tile's drawn width zw is xscale >> 12 or one more, and drawgfxzoom's
//   source step for each, 0x100000 / zw, is kept for both (dxa, dxb); dya,
//   dyb the same for heights
// A zoom of 0 keeps the slot but is never drawn (MAME's `continue`).
//
// THE LINE. Slots are drawn from 127 down to 0, a later one over an earlier
// one, as MAME draws them, so slot 0 is on top. For each tile row ty and
// column tx (size 1, 2, 4 or 8 tiles square of 16 x 16):
//   sy = oy + ((ty * yscale + 0x800) >> 12), its height the next row's sy - sy
//   sx = ox + ((tx * xscale + 0x800) >> 12), its width likewise
//   tile code = code + xoff[x] + yoff[y], x and y counted from the far end
//   when flipped; the source pixel is drawgfxzoom_core's:
//   (i * dx) >> 16 for destination pixel i, ((w - 1) * dx - i * dx) >> 16
//   flipped, dx = 0x100000 / w
// The 1:1 case (MAME's transpen) is the same arithmetic with w = 16.
//
// Pixel = K055555 PALBASE_SUB2 * 0x400 + colour * 16 + pen; pen 0 is not drawn.
//
// THE BUFFERS. Two lines of 512 { drawn, index[12:0] }: line_start flips
// them, the renderer writes the new one while the display reads the other
// and clears each pixel after reading it. A line that runs out of time is
// cut short by the next line_start.
//
// The sprite ROM is re-ordered at load (rtl/memory/dj_sdram_top.sv) so a
// tile row is one granule: { code, row } -> 8 bytes, pixel 2k in the low
// nibble of byte k.

module dj_sprites (
    input             clk,
    input             rst,

    // sprite RAM, 128 x 4 dwords: read port, data the clock after the address
    output reg  [8:0] or_addr,
    input      [31:0] or_q,

    input             copy_start,       // take the list (late in vblank)
    input             line_start,       // flip the buffers
    input             line_render,      // and draw line_y into the new one
    input       [8:0] line_y,
    input       [7:0] palbase,          // K055555 PALBASE_SUB2

    output reg        rom_cs,
    output reg [17:0] rom_addr,         // { code, row }
    input             rom_ok,
    input      [63:0] rom_data,

    // display: rd_en with rd_x reads the shown line's pixel (rd_pix two
    // clocks later) and clears it
    input             rd_en,
    input       [8:0] rd_x,
    output     [13:0] rd_pix,
    output reg        overrun           // a line was cut short
);

// ------------------------------------------------------------ the records
localparam RW = 189;
// { nd, code14, fx, fy, size2, col4, ox18, oy18, xs23, ys23, dxa21, dxb21, dya21, dyb21 }
reg  [RW-1:0] rec_d;
reg  [6:0]    rec_wa, rec_ra;
reg           rec_we;
wire [RW-1:0] rec_q;
gx_sdpram #(.AW(7), .DW(RW)) u_rec ( .clk, .we(rec_we), .wa(rec_wa), .d(rec_d), .ra(rec_ra), .q(rec_q) );
reg  [127:0]  valid;

// ------------------------------------------------------------ dividers
reg         dv_go;
reg  [23:0] dvx_n, dvy_n;
reg  [15:0] dvx_d, dvy_d;
wire [23:0] dvx_q, dvy_q;
wire        dvx_b, dvy_b;
dj_div #(.NW(24), .DW(16)) u_dvx ( .clk, .start(dv_go), .n(dvx_n), .d(dvx_d), .q(dvx_q), .busy(dvx_b) );
dj_div #(.NW(24), .DW(16)) u_dvy ( .clk, .start(dv_go), .n(dvy_n), .d(dvy_d), .q(dvy_q), .busy(dvy_b) );
wire dv_busy = dvx_b | dvy_b | dv_go;

// ------------------------------------------------------------ the copy
typedef enum logic [3:0] { C_IDLE, C_SNAP, C_A1, C_A2, C_A3, C_A4, C_A5, C_CHK, C_D1, C_D2, C_D3, C_WR } cst_t;
cst_t cst;
reg  [6:0]  ci;
reg  [31:0] w0, w1, w2, w3;
reg  [22:0] c_xs, c_ys;
reg  [20:0] c_dxa, c_dxb, c_dya, c_dyb;
wire [10:0] c_zwlo = c_xs[22:12];
wire [10:0] c_zhlo = c_ys[22:12];
wire [1:0]  c_size = w0[9:8];
// (size * scale) >> 13 with size = 1 << c_size
wire [25:0] c_xspan = { 3'd0, c_xs } << c_size;
wire [25:0] c_yspan = { 3'd0, c_ys } << c_size;
wire signed [17:0] c_ox = $signed({ {2{w1[15]}}, w1[15:0] })  - $signed({ 5'd0, c_xspan[25:13] });
wire signed [17:0] c_oy = $signed({ {2{w1[31]}}, w1[31:16] }) - $signed({ 5'd0, c_yspan[25:13] });
wire        c_nd  = w2[31:16] == 16'd0 || w2[15:0] == 16'd0;

// the snapshot of sprite RAM the walk reads: sprite RAM's read port is read
// out in order (data a clock after the address) and written here
reg  [9:0]  sn_n;                       // dwords asked for so far
reg  [8:0]  sn_wa;
reg         sn_we;
reg  [8:0]  sh_ra;
wire [31:0] sh_q;
always @(posedge clk) begin
    sn_we <= cst == C_SNAP && sn_n < 10'd512;
    sn_wa <= or_addr;
end
gx_sdpram #(.AW(9), .DW(32)) u_shadow ( .clk, .we(sn_we), .wa(sn_wa), .d(or_q), .ra(sh_ra), .q(sh_q) );

always @(posedge clk) begin
    rec_we <= 1'b0;
    dv_go  <= 1'b0;
    if (rst) cst <= C_IDLE;
    else case (cst)
        // the raw snapshot first: 512 dwords a clock each, done long before
        // the vblank handler that rewrites the list gets going
        C_IDLE: if (copy_start) begin or_addr <= 9'd0; sn_n <= 10'd0; cst <= C_SNAP; end
        C_SNAP: begin
            or_addr <= or_addr + 9'd1;
            sn_n    <= sn_n + 10'd1;
            if (sn_n == 10'd512) begin valid <= 128'd0; ci <= 7'd0; sh_ra <= 9'd0; cst <= C_A1; end
        end
        C_A1: begin sh_ra <= { ci, 2'd1 }; cst <= C_A2; end
        C_A2: begin w0 <= sh_q; sh_ra <= { ci, 2'd2 }; cst <= C_A3; end
        C_A3: begin w1 <= sh_q; sh_ra <= { ci, 2'd3 }; cst <= C_A4; end
        C_A4: begin w2 <= sh_q; cst <= C_A5; end
        C_A5: begin w3 <= sh_q; cst <= C_CHK; end
        C_CHK: begin
            if (w0[15] && !w0[31]) begin
                dvx_n <= 24'h40_0000; dvx_d <= c_nd ? 16'd1 : w2[31:16];
                dvy_n <= 24'h40_0000; dvy_d <= c_nd ? 16'd1 : w2[15:0];
                dv_go <= 1'b1;
                cst   <= C_D1;
            end else begin
                ci <= ci + 7'd1; sh_ra <= { ci + 7'd1, 2'd0 };
                cst <= ci == 7'd127 ? C_IDLE : C_A1;
            end
        end
        C_D1: if (!dv_busy) begin
            c_xs  <= dvx_q[22:0]; c_ys <= dvy_q[22:0];
            dvx_n <= 24'h10_0000; dvx_d <= { 5'd0, dvx_q[22:12] == 11'd0 ? 11'd1 : dvx_q[22:12] };
            dvy_n <= 24'h10_0000; dvy_d <= { 5'd0, dvy_q[22:12] == 11'd0 ? 11'd1 : dvy_q[22:12] };
            dv_go <= 1'b1;
            cst   <= C_D2;
        end
        C_D2: if (!dv_busy) begin
            c_dxa <= dvx_q[20:0]; c_dya <= dvy_q[20:0];
            dvx_n <= 24'h10_0000; dvx_d <= { 5'd0, c_zwlo + 11'd1 };
            dvy_n <= 24'h10_0000; dvy_d <= { 5'd0, c_zhlo + 11'd1 };
            dv_go <= 1'b1;
            cst   <= C_D3;
        end
        C_D3: if (!dv_busy) begin
            c_dxb <= dvx_q[20:0]; c_dyb <= dvy_q[20:0];
            cst   <= C_WR;
        end
        C_WR: begin
            rec_we <= 1'b1;
            rec_wa <= w0[6:0];
            rec_d  <= { c_nd, w0[29:16], w0[10], w0[11], w0[9:8], w3[19:16],
                        c_ox, c_oy, c_xs, c_ys, c_dxa, c_dxb, c_dya, c_dyb };
            valid[w0[6:0]] <= 1'b1;
            ci <= ci + 7'd1; sh_ra <= { ci + 7'd1, 2'd0 };
            cst <= ci == 7'd127 ? C_IDLE : C_A1;
        end
        default: cst <= C_IDLE;
    endcase
end

// ------------------------------------------------------------ the line
// the record being drawn
reg         r_nd, r_fx, r_fy;
reg  [13:0] r_code;
reg  [1:0]  r_size;
reg  [3:0]  r_col;
reg  signed [17:0] r_ox, r_oy;
reg  [22:0] r_xs, r_ys;
reg  [20:0] r_dxa, r_dxb, r_dya, r_dyb;

wire [3:0]  r_n    = 4'd1 << r_size;                  // tiles a side
function automatic [5:0] xoff( input [2:0] i );
    xoff = { 1'b0, i[2], 1'b0, i[1], 1'b0, i[0] };    // 0,1,4,5,16,17,20,21
endfunction
function automatic [5:0] yoff( input [2:0] i );
    yoff = { i[2], 1'b0, i[1], 1'b0, i[0], 1'b0 };    // 0,2,8,10,32,34,40,42
endfunction

typedef enum logic [3:0] { R_IDLE, R_SLOT, R_REC, R_LD, R_VY, R_VM, R_VM2, R_TX, R_TX2, R_ROM, R_PUSH, R_NEXT } rst_t;
rst_t rs;
reg         wr_half;
reg  [8:0]  ly;
reg  [6:0]  slot;
reg  [2:0]  ty, tx;
reg  [25:0] yacc, xacc;                               // ty * yscale, tx * xscale
reg  signed [19:0] syA, syB, sxA, sxB;
reg  [10:0] zh, ry, zw;
reg  [20:0] rdy, rdx;
reg  [3:0]  srcy;
reg  [5:0]  yrow;                                     // yoff of the row
reg  [10:0] mul_a;
reg  [20:0] mul_b;
wire [31:0] mul_p = mul_a * mul_b;
reg  [63:0] rom_data_l;
always @(posedge clk) if (rom_cs && rom_ok) rom_data_l <= rom_data;
reg  [9:0]  j_x0;
reg  [9:0]  j_n;

// one job between the fetch and the drawer: a tile row on this line
reg         jb_v;
reg  [63:0] jb_row;
reg  [9:0]  jb_x, jb_n;
reg  [31:0] jb_acc;
reg  [20:0] jb_dx;
reg         jb_neg;
reg  [12:0] jb_base;                                  // palbase * 0x400 + colour * 16
reg         jb_half;

reg         jt_v;                                     // the job being drawn
reg  [63:0] jt_row;
reg  [9:0]  jt_x, jt_n;
reg  [31:0] jt_acc;
reg  [20:0] jt_dx;
reg         jt_neg;
reg  [12:0] jt_base;
reg         jt_half;

wire [3:0]  jt_sx  = jt_acc[19:16];
wire [3:0]  jt_pen = jt_row[4 * jt_sx +: 4];
wire        jb_take = jb_v && !jt_v;

// line buffer, port A: the drawer
reg         la_we;
reg  [9:0]  la_a;
reg  [13:0] la_d;
// port B: the display, read then clear
reg         lb_we;
reg  [9:0]  lb_a;
wire [13:0] lb_q;
dj_tdpram2 #(.AW(10), .DW(14)) u_lb (
    .clk, .we_a(la_we), .a(la_a), .da(la_d), .qa(),
    .we_b(lb_we), .b(lb_a), .db(14'd0), .qb(lb_q)
);
reg  rd_en1;
always @(posedge clk) begin
    rd_en1 <= rd_en;
    lb_we  <= 1'b0;
    if (rd_en) lb_a <= { ~wr_half, rd_x };
    if (rd_en1) lb_we <= 1'b1;                        // the clock after the read: clear it
end
assign rd_pix = lb_q;

wire signed [19:0] Ls = $signed({ 11'd0, ly });

always @(posedge clk) begin
    la_we <= 1'b0;
    if (rst) begin
        rs <= R_IDLE; rom_cs <= 1'b0; jb_v <= 1'b0; jt_v <= 1'b0; wr_half <= 1'b0; overrun <= 1'b0;
    end else begin
        // ---- the drawer: a pixel a clock
        if (jt_v) begin
            if (jt_pen != 4'd0 && !jt_x[9]) begin
                la_we <= 1'b1;
                la_a  <= { jt_half, jt_x[8:0] };
                la_d  <= { 1'b1, jt_base[12:4], jt_pen };
            end
            jt_x   <= jt_x + 10'd1;
            jt_acc <= jt_neg ? jt_acc - 32'(jt_dx) : jt_acc + 32'(jt_dx);
            jt_n   <= jt_n - 10'd1;
            if (jt_n == 10'd1) jt_v <= 1'b0;
        end
        if (jb_take) begin
            jt_v <= 1'b1; jt_row <= jb_row; jt_x <= jb_x; jt_n <= jb_n; jt_acc <= jb_acc;
            jt_dx <= jb_dx; jt_neg <= jb_neg; jt_base <= jb_base; jt_half <= jb_half;
            jb_v <= 1'b0;
        end

        // ---- the walk
        if (line_start) begin
            if (rs != R_IDLE) overrun <= 1'b1;
            wr_half <= ~wr_half;
            ly      <= line_y;
            slot    <= 7'd127;
            rom_cs  <= 1'b0;
            jb_v    <= 1'b0;
            jt_v    <= 1'b0;
            rs      <= line_render ? R_SLOT : R_IDLE;
        end else case (rs)
            R_IDLE: ;
            R_SLOT: begin
                if (valid[slot]) begin rec_ra <= slot; rs <= R_REC; end
                else if (slot == 7'd0) rs <= R_IDLE;
                else slot <= slot - 7'd1;
            end
            R_REC: rs <= R_LD;                        // the record's read
            R_LD: begin
                { r_nd, r_code, r_fx, r_fy, r_size, r_col, r_ox, r_oy, r_xs, r_ys, r_dxa, r_dxb, r_dya, r_dyb } <= rec_q;
                ty   <= 3'd0;
                yacc <= 26'd0;
                rs   <= rec_q[RW-1] ? R_NEXT : R_VY;  // not drawn: on to the next slot
            end
            // the tile row this line falls in
            R_VY: begin
                syA <= 20'(r_oy) + 20'((yacc + 26'h800) >> 12);
                syB <= 20'(r_oy) + 20'((yacc + 26'(r_ys) + 26'h800) >> 12);
                rs  <= R_VM;
            end
            R_VM: begin
                if (Ls >= syA && Ls < syB) begin
                    zh    <= 11'(syB - syA);
                    ry    <= 11'(Ls - syA);
                    yrow  <= yoff(r_fy ? 3'(r_n - 4'd1) - ty : ty);
                    rs    <= R_VM2;
                end else if (4'(ty) == r_n - 4'd1 || Ls < syA) begin
                    rs <= R_NEXT;                     // not on this line
                end else begin
                    ty   <= ty + 3'd1;
                    yacc <= yacc + 26'(r_ys);
                    rs   <= R_VY;
                end
            end
            R_VM2: begin
                // the source row: (m * dy) >> 16, m counted from the far end when flipped
                rdy   <= zh == r_ys[22:12] ? r_dya : r_dyb;
                mul_a <= r_fy ? zh - 11'd1 - ry : ry;
                mul_b <= zh == r_ys[22:12] ? r_dya : r_dyb;
                tx    <= 3'd0;
                xacc  <= 26'd0;
                rs    <= R_TX;
            end
            // a tile of the row
            R_TX: begin
                if (tx == 3'd0) srcy <= mul_p[19:16];
                sxA <= 20'(r_ox) + 20'((xacc + 26'h800) >> 12);
                sxB <= 20'(r_ox) + 20'((xacc + 26'(r_xs) + 26'h800) >> 12);
                rs  <= R_ROM;
            end
            R_ROM: begin
                // visible: fetch its row and work out the run
                if (sxB > sxA && sxB > 20'sd0 && sxA < 20'sd512) begin
                    zw       <= 11'(sxB - sxA);
                    rdx      <= 11'(sxB - sxA) == r_xs[22:12] ? r_dxa : r_dxb;
                    j_x0     <= sxA < 0 ? 10'd0 : 10'(sxA);
                    j_n      <= 10'((sxB > 20'sd512 ? 20'sd512 : sxB) - (sxA < 0 ? 20'sd0 : sxA));
                    // m for the first pixel: i0 = x0 - sxA, from the far end when flipped
                    mul_a    <= r_fx ? 11'(sxB - 20'sd1 - (sxA < 0 ? 20'sd0 : sxA)) : 11'((sxA < 0 ? 20'sd0 : sxA) - sxA);
                    mul_b    <= 11'(sxB - sxA) == r_xs[22:12] ? r_dxa : r_dxb;
                    rom_addr <= { 14'(r_code + 14'(xoff(r_fx ? 3'(r_n - 4'd1) - tx : tx)) + 14'(yrow)), srcy };
                    rom_cs   <= 1'b1;
                    rs       <= R_PUSH;
                end else rs <= R_TX2;
            end
            R_PUSH: if (rom_cs && rom_ok) rom_cs <= 1'b0;
                    else if (!rom_cs && !jb_v) begin
                jb_v    <= 1'b1;
                jb_row  <= rom_data_l;
                jb_x    <= j_x0;
                jb_n    <= j_n;
                jb_acc  <= mul_p;
                jb_dx   <= rdx;
                jb_neg  <= r_fx;
                jb_base <= { palbase[2:0], 10'd0 } + { 5'd0, r_col, 4'd0 };
                jb_half <= wr_half;
                rs      <= R_TX2;
            end
            // the next tile, or the next slot
            R_NEXT: begin
                if (slot == 7'd0) rs <= R_IDLE;
                else begin slot <= slot - 7'd1; rs <= R_SLOT; end
            end
            R_TX2: begin
                if (4'(tx) == r_n - 4'd1) rs <= R_NEXT;
                else begin
                    tx   <= tx + 3'd1;
                    xacc <= xacc + 26'(r_xs);
                    rs   <= R_TX;
                end
            end
            default: rs <= R_IDLE;
        endcase
    end
end


endmodule
