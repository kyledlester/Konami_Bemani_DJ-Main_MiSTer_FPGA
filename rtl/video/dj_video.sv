// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami DJ Main video: the raster, the two tilemap layers (dj_tilemap), the
// sprites (dj_sprites), the K055555's choice between them, and the palette.
//
// Raster (djmain.cpp set_raw(32 MHz / 2, 660, 0, 512, 418, 0, 384)): 16 MHz
// dots from the 48 MHz clock, a dot every third clock; 512 x 384 visible,
// 24.24 kHz lines, 57.997 Hz frames. Sync positions are not in MAME and are
// this core's: hsync dots 536-595, vsync lines 388-391.
//
// Each line, at its last dot, the line buffers flip and the line after the
// next one is rendered (dj_tilemap and dj_sprites take line_start on every
// line and render when line_render). At the start of vblank (line 384) the
// sprite list is taken.
//
// MIXING, as djmain_state::screen_update: three inputs -- layer A
// (K55 PRIINP_0, register 7), layer B (PRIINP_3, 10), sprites (PRIINP_10,
// "sub 2", 17) -- each gated by K55_INPUT_ENABLES (45) bits 0, 1, 6, put in
// order by MAME's own three-element exchange sort (ascending; its tie
// behaviour copied, not a stable sort) and drawn in that order, the last on
// top; pen 0 of each is transparent and the background is palette pen 0.
// Tile pixels are colour * 16 + pen (no palette base: the driver's tile
// callback is empty); sprite pixels come with their base.
//
// Palette: 0x1110 entries of xBGR_888 at 0x480000 (R in bits 7-0). The x
// byte is not kept (the board has three 8-bit SRAMs).

module dj_video (
    input             clk,              // 48 MHz
    input             rst,

    // CPU: the K056832 (through dj_tilemap)
    input             tm_reg_we,
    input       [4:0] tm_reg_addr,
    input      [15:0] tm_reg_din,
    input       [1:0] tm_reg_be,
    output     [15:0] tm_regs [32],
    input             vram_we,
    input             vram_rd,
    input      [15:0] vram_addr,
    input      [15:0] vram_din,
    input       [1:0] vram_be,
    output     [15:0] vram_dout,

    // CPU: the K055555 (write only)
    input             k55_we,
    input       [5:0] k55_addr,
    input       [7:0] k55_din,

    // CPU: the palette, a 24-bit entry with byte enables { B, G, R }
    input             pal_we,
    input      [12:0] pal_addr,
    input       [2:0] pal_be,
    input      [23:0] pal_din,
    output     [23:0] pal_dout,

    // sprite RAM read port
    output      [8:0] or_addr,
    input      [31:0] or_q,

    // SDRAM
    output     [18:0] tile_addr,
    output            tile_cs,
    input             tile_ok,
    input      [31:0] tile_data,
    output     [18:0] tile2_addr,
    output            tile2_cs,
    input             tile2_ok,
    input      [31:0] tile2_data,
    output     [17:0] obj_addr,
    output            obj_cs,
    input             obj_ok,
    input      [63:0] obj_data,

    // out
    output reg        ce_pix,
    output reg [23:0] rgb,              // { R, G, B }
    output reg        hblank,
    output reg        vblank,
    output reg        hsync,
    output reg        vsync,
    output reg        vb_next,          // the vertical blank of the next line (CRT Adjust)
    output reg        vblank_irq,       // a clock at the start of vblank
    output     [ 2:0] dbg               // { sprite overrun, tile unsupported, tile busy at flip }
);

localparam [9:0] HTOTAL = 10'd660, HVIS = 10'd512, HS0 = 10'd536, HS1 = 10'd596;
localparam [8:0] VTOTAL = 9'd418,  VVIS = 9'd384,  VS0 = 9'd388, VS1 = 9'd392;
// The sprite list is taken at the start of vblank, where MAME draws it: the
// game's vblank handler rewrites the whole list from line 384 on (measured,
// scripts/mame/obj_timing.lua: lines 384-415, on busy frames into the next
// frame's first lines), so a later snapshot catches it half written --
// sprites flashing and torn on the board. dj_sprites copies sprite RAM raw
// first (512 clocks), well before the handler's first write.
localparam [8:0] COPY_LINE = 9'd384;

// ------------------------------------------------------------ the raster
reg  [1:0] div = 2'd0;
reg  [9:0] hcnt = 10'd0;
reg  [8:0] vcnt = 9'd0;
wire       ce = div == 2'd0;
wire [8:0] vnext = vcnt == VTOTAL - 9'd1 ? 9'd0 : vcnt + 9'd1;
wire [8:0] vtgt  = vnext == VTOTAL - 9'd1 ? 9'd0 : vnext + 9'd1;   // the line after the next
reg        line_start, line_render, copy_start;
reg  [8:0] line_y;

always @(posedge clk) begin
    div        <= div == 2'd2 ? 2'd0 : div + 2'd1;
    line_start <= 1'b0;
    copy_start <= 1'b0;
    vblank_irq <= 1'b0;
    if (ce) begin
        if (hcnt == HTOTAL - 10'd1) begin
            hcnt        <= 10'd0;
            vcnt        <= vnext;
            line_start  <= 1'b1;
            line_render <= vtgt < VVIS;
            line_y      <= vtgt;
            if (vnext == VVIS)      vblank_irq <= 1'b1;
            if (vnext == COPY_LINE) copy_start <= 1'b1;
        end else hcnt <= hcnt + 10'd1;
    end
end

// ------------------------------------------------------------ K055555
reg [7:0] k55 [64];
always @(posedge clk) if (k55_we) k55[k55_addr] <= k55_din;
wire [7:0] k55_en   = k55[45];
wire [7:0] k55_pa   = k55[7];
wire [7:0] k55_pb   = k55[10];
wire [7:0] k55_ps   = k55[17];
wire [7:0] k55_sbase = k55[29];

// MAME's exchange sort of three: for i < j, swap when pri[order[i]] > pri[order[j]]
reg [1:0] o0, o1, o2;
always @(posedge clk) begin : sort3
    reg [1:0] a, b, c, t;
    reg [7:0] p [3];
    p[0] = k55_pa; p[1] = k55_pb; p[2] = k55_ps;
    a = 2'd0; b = 2'd1; c = 2'd2;
    if (p[a] > p[b]) begin t = a; a = b; b = t; end
    if (p[a] > p[c]) begin t = a; a = c; c = t; end
    if (p[b] > p[c]) begin t = b; b = c; c = t; end
    o0 <= a; o1 <= b; o2 <= c;
end

// ------------------------------------------------------------ the layers
wire [13:0] tm_pix [2];
wire        tm_busy, tm_unsup;
wire signed [7:0] offs_x [2];
wire signed [7:0] offs_y [2];
// djmain_state::video_start: set_layer_offs(0, -92, -27), (1, -88, -27)
assign offs_x[0] = -8'sd92; assign offs_y[0] = -8'sd27;
assign offs_x[1] = -8'sd88; assign offs_y[1] = -8'sd27;
wire [23:0] tm_ra, tm_ra2;
assign tile_addr  = tm_ra[18:0];
assign tile2_addr = tm_ra2[18:0];
reg  tm_late = 1'b0;
reg  [9:0] tm_rdx;                              // the dot's column, held for the read
always @(posedge clk) if (ce) tm_rdx <= hcnt;

dj_tilemap u_tm (
    .clk, .rst,
    .reg_we(tm_reg_we), .reg_addr(tm_reg_addr), .reg_din(tm_reg_din), .reg_be(tm_reg_be), .reg_rd(tm_regs),
    .vram_we, .vram_rd, .vram_addr, .vram_din, .vram_be, .vram_dout,
    .offs_x, .offs_y,
    .line_start, .line_render, .line_y({ 1'b0, line_y }), .busy(tm_busy), .unsupported(tm_unsup),
    .blank_skip(1'b1),
    .rom_addr(tm_ra), .rom_cs(tile_cs), .rom_ok(tile_ok), .rom_data(tile_data),
    .rom2_addr(tm_ra2), .rom2_cs(tile2_cs), .rom2_ok(tile2_ok), .rom2_data(tile2_data),
    .vis_x0(10'd0), .vis_w(10'd512),
    .rd_x(tm_rdx), .rd_pix(tm_pix)
);
always @(posedge clk) if (line_start && tm_busy) tm_late <= 1'b1;

wire [13:0] sp_pix;
wire        sp_over;
dj_sprites u_sp (
    .clk, .rst,
    .or_addr, .or_q,
    .copy_start, .line_start, .line_render, .line_y, .palbase(k55_sbase),
    .rom_cs(obj_cs), .rom_addr(obj_addr), .rom_ok(obj_ok), .rom_data(obj_data),
    .rd_en(ce && hcnt < HVIS && vcnt < VVIS), .rd_x(hcnt[8:0]), .rd_pix(sp_pix),
    .overrun(sp_over)
);
assign dbg = { sp_over, tm_unsup, tm_late };

// ------------------------------------------------------------ palette
wire [23:0] pal_q;
reg  [12:0] pal_ra;
genvar pb;
generate for (pb = 0; pb < 3; pb++) begin : g_pal
    gx_tdpram #(.AW(13), .DW(8)) u_pal (
        .clk, .we_a(pal_we && pal_be[pb]), .a(pal_addr), .d(pal_din[8*pb +: 8]), .qa(pal_dout[8*pb +: 8]),
        .b(pal_ra), .qb(pal_q[8*pb +: 8])
    );
end endgenerate

// ------------------------------------------------------------ the pixel
// ce (dot x, cycle 0): the line buffers are addressed; cycle 2: both
// answers are in, the mix picks one and addresses the palette; the next
// dot's cycle 1: the colour is registered. It goes out with the ce after
// that, two dots after x, so the syncs and blanks are delayed two dots.
reg  [2:0] ph;                                   // clocks since ce
always @(posedge clk) ph <= ce ? 3'd1 : ph + 3'd1;

wire [13:0] lA = tm_pix[0], lB = tm_pix[1];
wire        opA = k55_en[0] && lA[3:0] != 4'd0;
wire        opB = k55_en[1] && lB[3:0] != 4'd0;
wire        opS = k55_en[6] && sp_pix[13];
wire [12:0] ixA = { 3'd0, lA[13:8], lA[3:0] };
wire [12:0] ixB = { 3'd0, lB[13:8], lB[3:0] };
wire [12:0] ixS = sp_pix[12:0];
wire [2:0]  op = { opS, opB, opA };
wire [12:0] ix [3];
assign ix[0] = ixA; assign ix[1] = ixB; assign ix[2] = ixS;

reg vis_l, vis_m;
always @(posedge clk) begin
    if (ce) vis_l <= hcnt < HVIS && vcnt < VVIS;
    if (ph == 3'd2) begin
        vis_m  <= vis_l;
        pal_ra <= !vis_l  ? 13'd0 :
                  op[o2] ? ix[o2] :
                  op[o1] ? ix[o1] :
                  op[o0] ? ix[o0] : 13'd0;
    end
    if (ph == 3'd1) rgb <= vis_m ? { pal_q[7:0], pal_q[15:8], pal_q[23:16] } : 24'd0;
end

// syncs and blanks, two dots late
reg [1:0] hb_d, vb_d, hs_d, vs_d, vn_d;
always @(posedge clk) begin
    ce_pix <= ce;
    if (ce) begin
        hb_d <= { hb_d[0], hcnt >= HVIS };
        vb_d <= { vb_d[0], vcnt >= VVIS };
        hs_d <= { hs_d[0], hcnt >= HS0 && hcnt < HS1 };
        vs_d <= { vs_d[0], vcnt >= VS0 && vcnt < VS1 };
        vn_d <= { vn_d[0], vnext >= VVIS };
        hblank <= hb_d[1];
        vblank <= vb_d[1];
        hsync  <= hs_d[1];
        vsync  <= vs_d[1];
        vb_next <= vn_d[1];
    end
end

endmodule
