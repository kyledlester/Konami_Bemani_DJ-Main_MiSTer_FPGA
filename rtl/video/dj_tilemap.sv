// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami DJ Main tilemaps: the K056832 (with the 058143) as a line renderer.
//
// DERIVED FROM gx_tilemap.sv of Arcade-KonamiGX_MiSTer (ppriest, GPL-3.0),
// which renders the same chip family for System GX. What changed for DJ Main
// (k054156_k054157_k056832.cpp, tilemap_draw_dj, set_config(BPP_4dj, 1, 1)):
//
//   * two layers (A, B), not four: djmain.cpp draws only layers 0 and 1
//   * 512 visible columns at 16 MHz dots (line buffers of 1024, 512 used)
//   * 4 bpp "dj" tiles: 32 bytes a tile, 4 a row; the planes, most
//     significant first, are bytes 3, 1, 2, 0 of the row (charlayout4dj),
//     MSB of each byte is the left pixel. The row comes from the SDRAM port
//     as a half granule: byte 0 in rom_data[7:0]
//   * 16-bit tile codes with no GX tile banks (2 MB of tiles = 64K codes)
//   * line scroll is always taken at the map row (tilemap_draw_dj walks the
//     scroll table by map row for every layer height; GX's one-page-tall
//     special case is tilemap_draw_common's)
//   * two tile rows in flight on two ROM clients, always (GX's Type 3/4
//     form): 2 x 65 tiles in a 1980-clock line
//
// NOT HANDLED: screen flip (m_regs[0] bits 4, 5; DJ Main does not set them)
// and djmain_hack's layer-to-page association, which only matters when two
// layers claim the same page.
//
// OUTPUT, per layer per pixel: { colour[5:0], pixel[7:0] } (pixel 0-15).
// Palette index = colour * 16 + pixel; pixel 0 is transparent.
//
// ONE LINE BUFFER PAIR: line_start renders into one half and flips which half
// rd_x reads, so the previous line is readable while the next renders.

module dj_tilemap (
    input               clk,
    input               rst,

    // K056832 registers, 0x580000-0x58003f: word_w, big-endian byte enables
    input               reg_we,
    input        [4:0]  reg_addr,
    input       [15:0]  reg_din,
    input        [1:0]  reg_be,          // [1] = bits 15:8, [0] = bits 7:0
    output      [15:0]  reg_rd [32],     // word_r: the register file as written

    // VRAM, by word: { page[3:0], word[11:0] }. Word 2t of a page is tile
    // t's attribute, word 2t+1 its code. A read is a vram_rd strobe; the
    // word is on vram_dout two clock edges later and stays there.
    input               vram_we,
    input               vram_rd,
    input       [15:0]  vram_addr,
    input       [15:0]  vram_din,
    input        [1:0]  vram_be,
    output reg  [15:0]  vram_dout,

    // K056832 set_layer_offs(layer, x, y)
    input  signed [7:0] offs_x [2],
    input  signed [7:0] offs_y [2],

    // render
    input               line_start,      // every line: flip the buffers
    input               line_render,     // and render line_y into the new one
    input        [9:0]  line_y,
    output              busy,
    output reg          unsupported,
    input               blank_skip,      // answer a repeat of the last transparent row without the ROM

    // tile ROM, one pixel row per address: row = code * 8 + y; the row's four
    // bytes in rom_data[31:0], byte 0 in [7:0]. Two clients, rows taken in turn.
    output reg  [23:0]  rom_addr,
    output reg          rom_cs,
    input               rom_ok,
    input       [31:0]  rom_data,
    output reg  [23:0]  rom2_addr,
    output reg          rom2_cs,
    input               rom2_ok,
    input       [31:0]  rom2_data,

    // the visible window's first map column and width (0 and 512)
    input        [9:0]  vis_x0,
    input        [9:0]  vis_w,

    // line buffer read: column vis_x0 + rd_x, one cycle latency
    input        [9:0]  rd_x,
    output      [13:0]  rd_pix [2]
);

wire [9:0] VIS_X0 = vis_x0;
wire [9:0] VIS_W  = vis_w;
localparam LB = 10;

// ------------------------------------------------------------ registers ---
reg [15:0] regs [32];
initial for (int i = 0; i < 32; i++) regs[i] = 16'd0;      // m_regs, cleared
// register 0x08's tile mode bits as word_w keeps them: 1 from power-on, and a
// bit changes only when a write changes that bit of the register
reg  [3:0] r_tmode = 4'hf;

always @(posedge clk) begin
    if (reg_we) begin
        if (reg_be[1]) regs[reg_addr][15:8] <= reg_din[15:8];
        if (reg_be[0]) regs[reg_addr][ 7:0] <= reg_din[ 7:0];
        if (reg_addr == 5'd4 && reg_be[0])
            r_tmode <= (r_tmode & ~(regs[4][3:0] ^ reg_din[3:0])) | (reg_din[3:0] & (regs[4][3:0] ^ reg_din[3:0]));
    end
end
genvar ri;
generate for (ri = 0; ri < 32; ri++) begin : g_rr
    assign reg_rd[ri] = regs[ri];
end endgenerate

// -------------------------------------------------------------- render ---
// Per layer: SETUP..PREP work out where the line starts in the layer's map,
// then RUN keeps two things going at once -- a fetcher reading one tile at a
// time (VRAM entry, then its pixel row from ROM) into two slots, and an
// emitter writing one pixel a cycle from the tile before it.
typedef enum logic [3:0] { IDLE, SETUP, MOD_Y, FIX_Y, LS_RD, LS_Q, PREP, RUN } state_t;
typedef enum logic [2:0] { F_IDLE, F_VWAIT, F_VDATA } fstate_t;
state_t  st;
fstate_t fst;

wire [15:0] r_ctrl   = regs[0];
// 0x08: a layer's tile mode, 1 = 8x8 tiles, 0 = 512x1 line map. MAME draws a
// line-map page only when linemap_enable() was called, which djmain.cpp never
// does: tilemap_draw_dj skips it (update_linemap returns 1). beatmania puts a
// layer in line mode to hide it while it loads the next background-movie
// frame into its pages; drawn, the half-loaded frame flashes over the play.
// (r_tmode, declared with the register file)
wire [15:0] r_flipen = regs[1];
wire [15:0] r_attr   = regs[3];
wire [15:0] r_scroll = regs[5];           // 0x0a: two bits a layer
wire [15:0] r_lsbank = regs[24];          // 0x30: the line-scroll VRAM page

reg         layer;
reg  [ 9:0] y;
reg  [11:0] height;          // rowspan * 256
reg  [11:0] ly;              // the map row this line draws (my, before PREP)
reg  [11:0] width;           // colspan * 512

// Line scroll (tilemap_draw_dj): register 0x0a gives each layer a mode --
// 0 per line, 2 per eight lines, else none -- and the words live in the page
// register 0x30 selects, 0x400 words per layer, two words a map row with the
// scroll in the second (dx = w0 << 16 | w1, of which only the low bits count).
wire [ 1:0] ls_mode  = r_scroll[{1'b0, layer, 1'b0} +: 2];
wire        ls_on    = ls_mode == 2'd0 || ls_mode == 2'd2;
wire [ 3:0] ls_page  = { r_lsbank[4:3], r_lsbank[1:0] };
reg  [15:0] ls_x;                         // this line's scroll, when ls_on
reg  [ 1:0] rowstart, colstart;
reg  [19:0] modv;            // |dy - offs_y|, reduced in place
reg         modneg;
reg  [ 2:0] modk;
reg  [11:0] ay, my;
reg  [31:0] scan_q;          // the tile's VRAM entry, captured in F_VWAIT

wire [15:0] l_ysc  = regs[{4'b1000, layer}];
wire [15:0] l_xsc  = regs[{4'b1010, layer}];
wire [15:0] l_rows = regs[{4'b0100, layer}];
wire [15:0] l_cols = regs[{4'b0110, layer}];

// Attribute decode, selected by m_regs[3] bits 6-7: where the two flip bits
// sit and how the six colour bits are assembled.
reg  [3:0] flips;
reg  [5:0] palm1, palm2;
reg  [1:0] pals2;
always @* begin
    case (r_attr[7:6])
        2'd0:    begin flips = 4'd6; palm1 = 6'h3f; pals2 = 2'd0; palm2 = 6'h00; end
        2'd1:    begin flips = 4'd4; palm1 = 6'h0f; pals2 = 2'd2; palm2 = 6'h30; end
        2'd2:    begin flips = 4'd2; palm1 = 6'h03; pals2 = 2'd2; palm2 = 6'h3c; end
        default: begin flips = 4'd0; palm1 = 6'h00; pals2 = 2'd2; palm2 = 6'h3f; end
    endcase
end

wire [15:0] attr    = scan_q[31:16];
wire [15:0] code    = scan_q[15:0];
wire [15:0] attr_sh = attr >> pals2;
wire [ 1:0] t_flip  = attr[flips +: 2] & r_flipen[{1'b0, layer, 1'b0} +: 2];
wire [ 5:0] t_col   = (attr[5:0] & palm1) | (attr_sh[5:0] & palm2);
wire [ 2:0] t_y     = t_flip[1] ? ~my[2:0] : my[2:0];

// MAME: ay = (dy - offs_y) % height with dy = (int16_t)m_regs[0x10+layer],
// and sx = (dx - offs_x) & (width - 1)
wire signed [16:0] ydiff = $signed({l_ysc[15], l_ysc}) - $signed({{9{offs_y[layer][7]}}, offs_y[layer]});
wire        [15:0] xdiff = (ls_on ? ls_x : l_xsc) - {{8{offs_x[layer][7]}}, offs_x[layer]};
wire        [11:0] sx    = xdiff[11:0] & (width - 12'd1);
wire        [11:0] ysum  = {2'd0, y} + ay;
wire        [11:0] xsum  = {2'd0, VIS_X0} + sx;
wire        [11:0] mx0   = xsum >= width ? xsum - width : xsum;

// fetcher
reg  [11:0] fmx;             // map column of the tile being fetched
reg  [ 6:0] fleft;           // tiles still to fetch on this layer (65 at 512 wide)
wire [11:0] fnext = {fmx[11:3], 3'd0} + 12'd8;

// Two tile rows in flight on two ROM clients, into two slots taken in turn;
// the emitter is given them in the order they were read.
reg  [ 1:0] s_busy, s_done;
reg  [18:0] s_key  [2];
reg  [31:0] s_row  [2];
reg  [ 5:0] s_col  [2];
reg  [ 1:0] s_flip [2];
reg  [ 2:0] s_tx   [2];
reg         s_iss, s_ret;            // the slot filled next, the slot retired next

// one-tile buffer between fetcher and emitter
reg         nb_valid;
reg  [31:0] nb_row;
reg  [ 5:0] nb_col;
reg  [ 1:0] nb_flip;
reg  [ 2:0] nb_tx;

// emitter
reg         e_valid;
reg  [ 9:0] px;
reg  [ 2:0] tx;
reg  [ 1:0] flip;
reg  [ 5:0] colour;
reg  [31:0] row;

// charlayout4dj { 8*3, 8*1, 8*2, 8*0 }: planes msb first are bytes 3, 1, 2, 0
wire [2:0] bitsel = flip[0] ? tx : ~tx;
wire [7:0] b0 = row[7:0], b1 = row[15:8], b2 = row[23:16], b3 = row[31:24];
wire [7:0] pixel = { 4'd0, b3[bitsel], b1[bitsel], b2[bitsel], b0[bitsel] };

wire last_px  = e_valid && px == VIS_W - 10'd1;
wire tile_end = e_valid && tx == 3'd7 && !last_px;
wire nb_take  = nb_valid && (!e_valid || tile_end);
wire nb_free  = !nb_valid || nb_take;

// ------------------------------------------------------ VRAM, line buffers ---
// VRAM: 16 pages x 2048 tiles x { attr, code }, 1 Mbit, as four byte-lane
// RAMs of 32K x 8. One write port (CPU) and ONE read port, shared: a CPU
// read takes it for a cycle and the fetcher waits.
// entry = page * 2048 + tile, page = ((rowstart + my / 256) & 3) * 4
//                                   + ((colstart + mx / 512) & 3)
wire [14:0] tile_addr = { 2'(rowstart + my[9:8]), 2'(colstart + fmx[10:9]), my[7:3], fmx[8:3] };
wire        scan_rd   = st == RUN && fst == F_IDLE && fleft != 7'd0 && !vram_rd && !s_busy[s_iss];
// the line's scroll pair: page, then layer * 0x200 + the map row (mode 2
// takes the row's group of eight), wrapping at 512 rows as MAME's mask does
wire [11:0] ls_row    = ysum >= height ? ysum - height : ysum;   // this line's map row
wire [ 8:0] ls_line   = ls_row[8:0];
wire [14:0] ls_addr   = { ls_page, 1'b0, layer, ls_mode == 2'd2 ? { ls_line[8:3], 3'd0 } : ls_line };
wire        ls_rd     = st == LS_RD && !vram_rd;
wire [14:0] rd_addr   = vram_rd    ? vram_addr[15:1] :
                        ls_rd      ? ls_addr         : tile_addr;
wire [ 3:0] vram_be4  = vram_addr[0] ? {2'b00, vram_be} : {vram_be, 2'b00};
wire [31:0] ram_q;
reg         cpu_rd_l, cpu_half;

genvar b;
generate for (b = 0; b < 4; b++) begin : g_vram
    gx_sdpram #(.AW(15), .DW(8)) u_lane (
        .clk ( clk ),
        .we  ( vram_we && vram_be4[b] ),
        .wa  ( vram_addr[15:1] ),
        .d   ( (b % 2) ? vram_din[15:8] : vram_din[7:0] ),
        .ra  ( rd_addr ),
        .q   ( ram_q[b*8 +: 8] )
    );
end endgenerate

always @(posedge clk) begin
    cpu_rd_l <= vram_rd;
    cpu_half <= vram_addr[0];
    if (cpu_rd_l) vram_dout <= cpu_half ? ram_q[15:0] : ram_q[31:16];
end

// Line buffers: one RAM per layer, two lines of 512
reg        wr_half;
reg        lb_we;
reg        lb_layer;
reg [ 9:0] lb_px;
reg [13:0] lb_din;

// a layer not drawn on a line (line mode): its half of the buffer reads as
// transparent, without spending the line writing it
reg  [1:0] off_h [2];                     // [half][layer]
initial begin off_h[0] = 2'b00; off_h[1] = 2'b00; end
reg  [1:0] off_q;
always @(posedge clk) off_q <= off_h[~wr_half];
wire [13:0] lb_q [2];

genvar l;
generate for (l = 0; l < 2; l++) begin : g_lbuf
    gx_sdpram #(.AW(LB+1), .DW(14)) u_lbuf (
        .clk ( clk ),
        .we  ( lb_we && lb_layer == l ),
        .wa  ( {wr_half, lb_px[LB-1:0]} ),
        .d   ( lb_din ),
        .ra  ( {~wr_half, rd_x[LB-1:0]} ),
        .q   ( lb_q[l] )
    );
    assign rd_pix[l] = off_q[l] ? 14'd0 : lb_q[l];
end endgenerate

assign busy = st != IDLE;

// Blank rows: each layer keeps the ROM address of the last row it fetched
// that came back transparent, and a tile whose row has that address skips
// the ROM: fewer requests on the graphics port the sprites share.
wire [18:0] f_key     = { code, t_y };
reg  [18:0] blank_key [2];
reg  [ 1:0] blank_kv;
wire        f_skip    = blank_skip && blank_kv[layer] && blank_key[layer] == f_key;

always @(posedge clk) begin
    lb_we  <= 1'b0;
    if (rst) begin
        blank_kv    <= 2'd0;
        st          <= IDLE;
        fst         <= F_IDLE;
        wr_half     <= 1'b0;
        rom_cs      <= 1'b0;
        rom2_cs     <= 1'b0;
        nb_valid    <= 1'b0;
        e_valid     <= 1'b0;
        fleft       <= 7'd0;
        unsupported <= 1'b0;
        s_busy      <= 2'b00;
        s_done      <= 2'b00;
        s_iss       <= 1'b0;
        s_ret       <= 1'b0;
    end else if (line_start) begin
        // a line not finished is cut short here: the buffers must flip every line
        wr_half  <= ~wr_half;
        y        <= line_y;
        layer    <= 1'b0;
        st       <= line_render ? SETUP : IDLE;
        fst      <= F_IDLE;
        rom_cs   <= 1'b0;
        rom2_cs  <= 1'b0;
        nb_valid <= 1'b0;
        e_valid  <= 1'b0;
        fleft    <= 7'd0;
        s_busy   <= 2'b00;
        s_done   <= 2'b00;
        s_iss    <= 1'b0;
        s_ret    <= 1'b0;
        if (r_ctrl[5:4] != 2'd0) unsupported <= 1'b1;
    end else case (st)
        IDLE: ;
        SETUP: if (!r_tmode[layer]) begin
            // line mode: not drawn
            off_h[wr_half][layer] <= 1'b1;
            layer <= 1'b1;
            st    <= layer ? IDLE : SETUP;
        end else begin
            off_h[wr_half][layer] <= 1'b0;
            rowstart <= l_rows[4:3];
            colstart <= l_cols[4:3];
            height   <= { 1'b0, {1'b0, l_rows[1:0]} + 3'd1, 8'd0 };
            width    <= { {1'b0, l_cols[1:0]} + 3'd1, 9'd0 };
            modneg   <= ydiff < 0;
            modv     <= ydiff < 0 ? 20'(-ydiff) : 20'(ydiff);
            modk     <= 3'd7;
            st       <= MOD_Y;
        end
        // |dy - offs_y| mod height by restoring subtraction of height << 7..0
        MOD_Y: begin
            if (modv >= (20'(height) << modk)) modv <= modv - (20'(height) << modk);
            modk <= modk - 3'd1;
            if (modk == 3'd0) st <= FIX_Y;
        end
        FIX_Y: begin
            ay <= (modneg && modv != 0) ? height - modv[11:0] : modv[11:0];
            st <= LS_RD;
        end
        // the line's scroll word, for a layer that has one
        LS_RD: begin
            ly <= ls_row;
            if (!ls_on) st <= PREP;
            else if (ls_rd) st <= LS_Q;
        end
        LS_Q: begin
            ls_x <= ram_q[15:0];
            st   <= PREP;
        end
        PREP: begin
            my    <= ly;
            fmx   <= mx0;
            fleft <= 7'((11'(mx0[2:0]) + 11'(VIS_W) + 11'd7) >> 3);   // tiles the VIS_W pixels touch
            px    <= 10'd0;
            st    <= RUN;
        end
        RUN: begin
            // ---- fetcher: VRAM, then the row into the next slot (a ROM client of its own)
            case (fst)
                F_IDLE: if (scan_rd) fst <= F_VWAIT;
                F_VWAIT: begin
                    scan_q <= ram_q;
                    fst    <= F_VDATA;
                end
                F_VDATA: begin
                    s_busy[s_iss] <= 1'b1;
                    s_key[s_iss]  <= f_key;
                    s_col[s_iss]  <= t_col;
                    s_flip[s_iss] <= t_flip;
                    s_tx[s_iss]   <= fmx[2:0];
                    fmx      <= fnext == width ? 12'd0 : fnext;
                    fleft    <= fleft - 7'd1;
                    if (f_skip) begin
                        s_row[s_iss]  <= 32'd0;
                        s_done[s_iss] <= 1'b1;
                    end else if (!s_iss) begin
                        rom_addr <= 24'(f_key); rom_cs <= 1'b1;
                    end else begin
                        rom2_addr <= 24'(f_key); rom2_cs <= 1'b1;
                    end
                    s_iss <= ~s_iss;
                    fst   <= F_IDLE;
                end
                default: fst <= F_IDLE;
            endcase
            if (rom_cs && rom_ok) begin
                rom_cs <= 1'b0; s_row[0] <= rom_data; s_done[0] <= 1'b1;
                if (rom_data == 32'd0) begin blank_key[layer] <= s_key[0]; blank_kv[layer] <= 1'b1; end
            end
            if (rom2_cs && rom2_ok) begin
                rom2_cs <= 1'b0; s_row[1] <= rom2_data; s_done[1] <= 1'b1;
                if (rom2_data == 32'd0) begin blank_key[layer] <= s_key[1]; blank_kv[layer] <= 1'b1; end
            end

            // ---- buffer: the slots in the order they were filled
            if (s_done[s_ret] && nb_free) begin
                nb_valid <= 1'b1;
                nb_row   <= s_row[s_ret];
                nb_col   <= s_col[s_ret];
                nb_flip  <= s_flip[s_ret];
                nb_tx    <= s_tx[s_ret];
                s_busy[s_ret] <= 1'b0;
                s_done[s_ret] <= 1'b0;
                s_ret    <= ~s_ret;
            end else if (nb_take) nb_valid <= 1'b0;

            // ---- emitter
            if (e_valid) begin
                lb_we    <= 1'b1;
                lb_layer <= layer;
                lb_px    <= px;
                lb_din   <= { colour, pixel };
                px       <= px + 10'd1;
                tx       <= tx + 3'd1;
            end
            if (nb_take) begin
                e_valid <= 1'b1;
                row     <= nb_row;
                colour  <= nb_col;
                flip    <= nb_flip;
                tx      <= nb_tx;
            end else if (tile_end) e_valid <= 1'b0;

            if (last_px) begin
                e_valid <= 1'b0;
                layer   <= 1'b1;
                st      <= layer ? IDLE : SETUP;
            end
        end
        default: st <= IDLE;
    endcase
end

`ifdef SIMULATION
always @(posedge clk) if (st == RUN && last_px && (fleft != 0 || nb_valid || fst != F_IDLE || s_busy != 0))
    $error("dj_tilemap: layer %0d ended with fetches outstanding", layer);
`endif

endmodule
