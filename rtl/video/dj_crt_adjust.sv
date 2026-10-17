// SPDX-License-Identifier: GPL-3.0-or-later
//
// DJ Main: CRT Adjust for the native 24 kHz analog picture (the DJMain build).
//
// The owner's Namco NB-1 glue (Namco_NB1_Mister rtl/nb1/nb1_crt_adjust.sv,
// hardware-confirmed) on this board's raster, around the UNMODIFIED upstream
// rtl/vendor/crt_adjust.sv (MiSTer-CRT-Adjust, Umberto Parisi / rmonic79,
// GPL-3.0-or-later) -- unmodified but for one thing: its line buffer's width is
// a parameter, set here to hold the 660-dot line (see AW there). Same OSD controls, status bits, encodings, ranges and
// defaults as the owner's other cores:
//   [96]      CRT Adjust Off / On (0 = Off = default = TRUE bypass: the native
//             stream, zero latency)
//   [116:112] H-Size OSD index -> -12..+10, one step = 1 % (index 0 = 0,
//             1..10 = +1..+10, 11..22 = -12..-1, 23..31 = 0); + = WIDER
//   [104:101] H-Position signed -8..+7, one step = 6 pixels (+ = left)
//   [108:105] V-Shift    signed -8..+7, one step = 1 line
//
// Presentation only, and for the analog output only: DJMain.sv feeds HDMI the
// native picture (NATIVE_*), so HDMI never sees the adjust. Nothing upstream
// (the raster, the CPU's vblank, the sprite snapshot, sound) sees it either.
//
// The raster (rtl/video/dj_video.sv): 660 dots x 418 lines at 16 MHz (a dot
// every third 48 MHz clock), active 0..511 x 0..383, HSync dots 536..595,
// VSync lines 388..391. As NB-1, the blanking is short (148 dots) with HSync
// right after the picture, so this is NB-1's safe engine, not NA's:
//   - HPOS_CONTENTSHIFT (1): HSync out is the native HSync (SYNC_LAG dots
//     later) in every setting; the line and frame periods never change;
//   - the module gets HSync/VSync SYNC_LAG = 72 dots late (its content 72
//     early) and the content offset + 72, so the offsets it sees are never
//     negative (upstream zero-extends a negative CONTENTSHIFT offset). The
//     whole output is 72 dots (4.5 us) later than the native raster, which a
//     CRT cannot see;
//   - H-Size scales about the picture centre, and the total content offset
//     (centring + H-Position) is clamped to the blanking: the picture never
//     overlaps the HSync pulse or runs past the next one (past the limit it
//     stops moving);
//   - the module's line window runs HSync to HSync, so it is given the blank
//     of the line it writes (vb_next), and the blank sent on is that of the
//     line it reads: all 384 lines are shown;
//   - V-Shift is clamped to -3..+7 so VSync (line 388) never lands on a
//     picture line (the content is one line late through the buffer: native
//     lines 1..384).
//   - read CE: the real pixel CE while H-Size is 0 (byte-exact), else an exact
//     rational NCO, READ_INC = PIXEL_HZ - hsize * STEP, STEP = PIXEL_HZ / 100
//     = 160,000 (exactly 1 %).
// The controls are taken once per frame (frame_event, in vertical blanking),
// so every frame is internally consistent.
module dj_crt_adjust #(
    parameter integer SYS_HZ  = 48_000_000,
    parameter integer PIX_DIV = 3,
    parameter integer HTOTAL  = 660,
    parameter integer VTOTAL  = 418
) (
    input  wire        clk,
    input  wire        ce_pix,
    input  wire        frame_event,     // one pulse per frame, inside vertical blanking
    // OSD
    input  wire        osd_on,          // status[96]
    input  wire [4:0]  osd_hsize,       // status[116:112]
    input  wire [3:0]  osd_hpos,        // status[104:101]
    input  wire [3:0]  osd_vshift,      // status[108:105]
    input  wire        vb_next,         // the vertical blank of the NEXT native line (see above)
    // native stream
    input  wire [23:0] rgb_in,
    input  wire        hblank_in,
    input  wire        vblank_in,
    input  wire        hsync_in,
    input  wire        vsync_in,
    // to the analog output's arcade_video
    output wire        ce_out,
    output wire [23:0] rgb_out,
    output wire        hblank_out,
    output wire        vblank_out,
    output wire        hsync_out,
    output wire        vsync_out,
    // state (bench)
    output wire        active,
    output reg  signed [4:0] hsize_s = 5'sd0,
    output reg  signed [3:0] hpos_s  = 4'sd0,
    output reg  signed [3:0] vsh_s   = 4'sd0
);
    reg crt_on = 1'b0;
    always @(posedge clk) if (frame_event) begin
        crt_on  <= osd_on;
        hsize_s <= (osd_hsize <= 5'd10) ? $signed(osd_hsize)
                 : (osd_hsize <= 5'd22) ? $signed(osd_hsize - 5'd23)
                 : 5'sd0;
        hpos_s  <= $signed(osd_hpos);
        vsh_s   <= $signed(osd_vshift);
    end
    assign active = crt_on;    // no scandoubler on this core (24 kHz is never doubled)

    // content offset (module: > 0 = content right) = centring for H-Size - 6 * H-Position, clamped to
    // [lo, hi]: lo = first pixel right after the HSync pulse, hi = last pixel before the next HSync
    // (in read ticks: hc = round(380 f) - 380, lo = ceil(60 f) - 124, hi = floor(660 f) - 639 with
    // f = 1 - hsize / 100; active window 124..635 of the HSync-to-HSync line, centre 380)
    reg signed [8:0] hc, lo, hi;
    always_comb begin
        case (hsize_s)
            -5'sd12: begin hc = 46; lo = -56; hi = 100; end
            -5'sd11: begin hc = 42; lo = -57; hi = 93; end
            -5'sd10: begin hc = 38; lo = -58; hi = 87; end
            -5'sd9: begin hc = 34; lo = -58; hi = 80; end
            -5'sd8: begin hc = 30; lo = -59; hi = 73; end
            -5'sd7: begin hc = 27; lo = -59; hi = 67; end
            -5'sd6: begin hc = 23; lo = -60; hi = 60; end
            -5'sd5: begin hc = 19; lo = -61; hi = 54; end
            -5'sd4: begin hc = 15; lo = -61; hi = 47; end
            -5'sd3: begin hc = 11; lo = -62; hi = 40; end
            -5'sd2: begin hc = 8; lo = -62; hi = 34; end
            -5'sd1: begin hc = 4; lo = -63; hi = 27; end
            5'sd0: begin hc = 0; lo = -64; hi = 21; end
            5'sd1: begin hc = -4; lo = -64; hi = 14; end
            5'sd2: begin hc = -8; lo = -65; hi = 7; end
            5'sd3: begin hc = -11; lo = -65; hi = 1; end
            5'sd4: begin hc = -15; lo = -66; hi = -6; end
            5'sd5: begin hc = -19; lo = -67; hi = -12; end
            5'sd6: begin hc = -23; lo = -67; hi = -19; end
            5'sd7: begin hc = -27; lo = -68; hi = -26; end
            5'sd8: begin hc = -30; lo = -68; hi = -32; end
            5'sd9: begin hc = -34; lo = -69; hi = -39; end
            5'sd10: begin hc = -38; lo = -70; hi = -45; end
            default: begin hc = 0; lo = -64; hi = 21; end
        endcase
    end
    reg signed [8:0] hoff_q = 9'sd0;
    // sign-extended explicitly (a bare size cast of a signed value evaluates unsigned)
    wire signed [9:0] hoff_raw = $signed({hc[8], hc}) - ($signed({{6{hpos_s[3]}}, hpos_s}) * 10'sd6);
    always @(posedge clk)
        hoff_q <= (hoff_raw < $signed({lo[8], lo})) ? lo : (hoff_raw > $signed({hi[8], hi})) ? hi : hoff_raw[8:0];
    localparam integer SYNC_LAG = 72;
    wire signed [8:0] hoffset = active ? (hoff_q + 9'sd72) : 9'sd0;
    wire signed [3:0] vsh_c   = (vsh_s < -4'sd3) ? -4'sd3 : vsh_s;
    wire signed [5:0] voffset = active ? $signed({{2{vsh_c[3]}}, vsh_c}) : 6'sd0;

    localparam integer PIXEL_HZ = SYS_HZ / PIX_DIV;
    localparam integer STEP     = (PIXEL_HZ + 50) / 100;
    wire hs_ref;
    reg  hs_ref_d = 1'b0;
    always @(posedge clk) hs_ref_d <= hs_ref;
    wire hs_ref_rise = hs_ref && !hs_ref_d;
    // registered: hsize_s changes only at a frame event, so one clock late is exact
    reg  signed [31:0] read_inc = PIXEL_HZ;
    always @(posedge clk) read_inc <= PIXEL_HZ - (hsize_s * STEP);
    reg  [26:0] phase = 27'd0;
    wire [27:0] phase_sum = {1'b0, phase} + read_inc[26:0];
    wire rd_tick = (phase_sum >= SYS_HZ);
    always @(posedge clk) begin
        if (hs_ref_rise)  phase <= 27'd0;
        else if (rd_tick) phase <= phase_sum - SYS_HZ;
        else              phase <= phase_sum[26:0];
    end
    reg use_nco = 1'b0;
    always @(posedge clk) use_nco <= active && (hsize_s != 5'sd0);
    wire rd_ce = use_nco ? rd_tick : ce_pix;

    // vertical blank of the line being written in the module's HSync-to-HSync window: after the
    // (lagged) HSync that window holds the NEXT line; sampled by the module at the HSync rise
    wire vb_wr = vb_next;
    // HSync / VSync, SYNC_LAG dots late (native pixel CE)
    reg [SYNC_LAG-1:0] hs_dl = '0, vs_dl = '0;
    always @(posedge clk) if (ce_pix) begin
        hs_dl <= {hs_dl[SYNC_LAG-2:0], hsync_in};
        vs_dl <= {vs_dl[SYNC_LAG-2:0], vsync_in};
    end
    wire hs_lag = hs_dl[SYNC_LAG-1];
    wire vs_lag = vs_dl[SYNC_LAG-1];
    // ... and of the line being read (the module's vb_line / vb_active pair, same edge)
    reg hs_in_d = 1'b0, vb_l1 = 1'b0, vb_rd = 1'b0;
    always @(posedge clk) if (ce_pix) begin
        hs_in_d <= hs_lag;
        if (hs_lag && !hs_in_d) begin vb_l1 <= vb_wr; vb_rd <= vb_l1; end
    end
    wire [23:0] a_rgb;
    wire a_hs, a_vs, a_hb, a_vb;
    // AW 11: 1024 samples a bank, room for the 660-dot line (upstream's 512 would wrap)
    crt_adjust #(.VTOTAL(VTOTAL), .HTOTAL(HTOTAL), .HPOS_MODE(1), .AW(11)) crt_adjust (
        .clk(clk), .pxl_cen(ce_pix), .pxl2_cen(rd_ce),
        .active(active),
        .hsize(hsize_s), .hoffset(hoffset), .voffset(voffset),
        .r_in(rgb_in[23:16]), .g_in(rgb_in[15:8]), .b_in(rgb_in[7:0]),
        .hs_in(hs_lag), .vs_in(vs_lag), .hb_in(hblank_in), .vb_in(vb_wr),
        .r_out(a_rgb[23:16]), .g_out(a_rgb[15:8]), .b_out(a_rgb[7:0]),
        .hs_out(a_hs), .vs_out(a_vs), .hb_out(a_hb), .vb_out(a_vb),
        .hs_ref_out(hs_ref));

    // TRUE bypass when Off: the native stream, zero added latency
    assign ce_out     = active ? rd_ce : ce_pix;
    assign rgb_out    = active ? a_rgb : rgb_in;
    assign hblank_out = active ? a_hb  : hblank_in;
    assign vblank_out = active ? vb_rd : vblank_in;
    assign hsync_out  = active ? a_hs  : hsync_in;
    assign vsync_out  = active ? a_vs  : vsync_in;
endmodule
