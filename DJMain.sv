// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami DJ Main (Bemani) for MiSTer: the top. The board is rtl/dj_main.sv
// (CPU and map), rtl/video/dj_video.sv, rtl/sound/dj_sound.sv and the hard
// disk rtl/dj_ata.sv; this file is the MiSTer side -- clocks, the SDRAM image
// and its download, the disk image, the controls, the OSD and the outputs.
//
// Clocks (rtl/pll, Arcade-KonamiGX_MiSTer's PLL unchanged): clk_sys 96 MHz
// for the SDRAM, hps_io and the disk; clk_vid 48 MHz for the board (16 MHz
// dots, a dot every third clock); clk_cpu 24 MHz for the 68EC020's kernel.
//
// The game needs its hard disk: the CHD converted once to a raw image
// (chdman extracthd) and mounted from the OSD. The board is held in reset
// until an image is mounted, and reset again when another one is.
//
// Two builds from this source: DJMain (the board's 24 kHz picture on both
// analog and HDMI) and DJMainSD, the DJMainSD revision with CRT_480I defined
// (rtl/video/crt_480i.sv: the analog output is 15 kHz 480i only, for a
// standard-definition CRT; HDMI keeps the native picture through NATIVE_*).

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] aud_l, aud_r;
assign AUDIO_S   = 1;
assign AUDIO_L   = aud_l;
assign AUDIO_R   = aud_r;
assign AUDIO_MIX = status[7:6];

wire ata_active;
assign LED_DISK  = { 1'b0, ata_active };
assign LED_POWER = 0;
assign BUTTONS   = 0;

wire [1:0] ar = status[2:1];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
`ifdef CRT_480I
	"DJMainSD;;",
`else
	"DJMain;;",
`endif
	"-;",
	"S0,HDDIMG,Mount HDD;",
	"-;",
	"O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[7:6],Audio mix,Stereo,25%,50%,Mono;",
	"-;",
	"P1,Controls;",
	"P1-;",
	// the turntables (turntable_r): every source adds to the same counter
	"P1O[9:8],Turntable stick,Left stick,Right stick,Off;",
	"P1O[12:10],Turntable speed,4,5,6,7,8,1,2,3;",
	"P1O[13],Turntable direction,Normal,Reversed;",
	"P1O[14],Mouse turntable,P1,P2;",
	"P1-;",
	"P1O[15],CPU speed,16 MHz (board),24 MHz;",
`ifdef CRT_480I
	"P2,CRT 480i;",
	"P2-;",
	"P2O[18:16],Deflicker,Off,Mild,Medium,Medium+,Full;",
	"P2O[21:19],Height,1:1,200,208,216,224,232,240;",
	"P2O[27:22],H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[32:28],V-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
`else
	// CRT Adjust (rtl/video/dj_crt_adjust.sv): the analog 24 kHz picture only;
	// same bits and encodings as the owner's other cores
	"P2,CRT Adjust;",
	"P2-;",
	"P2O[96],CRT Adjust,Off,On;",
	"H1P2O[116:112],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P2O[104:101],CRT H-Position,0,+6,+12,+18,+24,+30,+36,+42,-48,-42,-36,-30,-24,-18,-12,-6;",
	"H1P2O[108:105],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
`endif
	"-;",
	"DIP;",
	"-;",
	"R[0],Reset;",
	// positional: joystick bit 4 + i. These are beatmania's; each .mra's
	// <buttons> names them for its game (the input layouts, below)
	"J1,Key 1,Key 2,Key 3,Key 4,Key 5,Scratch Up,Scratch Down,Start,Coin,Effect,Test,Service,Button 13,Button 14,Button 15,Button 16;",
	"jn,Y,X,B,A,R,L,-,Start,Select,-,-,-;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [21:0] gamma_bus;
wire [31:0] joystick_0, joystick_1;
wire [15:0] joystick_l_analog_0, joystick_l_analog_1;
wire [15:0] joystick_r_analog_0, joystick_r_analog_1;
wire  [8:0] spinner_0, spinner_1;
wire [24:0] ps2_mouse;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;

wire        img_mounted, img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba;
wire  [5:0] sd_blk_cnt;
wire        sd_rd, sd_wr, sd_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout, sd_buff_din;
wire        sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(1), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
`ifdef CRT_480I
	.status_menumask(16'd0),
`else
	.status_menumask({ 14'd0, ~status[96], 1'b0 }),   // H1 = the CRT Adjust amounts, hidden while Off
`endif
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.joystick_r_analog_0(joystick_r_analog_0),
	.joystick_r_analog_1(joystick_r_analog_1),
	.spinner_0(spinner_0),
	.spinner_1(spinner_1),
	.ps2_mouse(ps2_mouse),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba('{sd_lba}),
	.sd_blk_cnt('{sd_blk_cnt}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din}),
	.sd_buff_wr(sd_buff_wr),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_sdram_shifted, clk_vid, clk_cpu, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.outclk_2(clk_vid),
	.outclk_3(clk_cpu),
	.locked(pll_locked)
);
assign SDRAM_CLK = clk_sdram_shifted;

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// the ROM: index 0 streamed in, then the board starts
reg  rom_loaded = 1'b0;
reg  dl_d = 1'b0;
wire dl_rom = ioctl_download && ioctl_index == 16'd0;
always @(posedge clk_sys) begin
	dl_d <= dl_rom;
	if (dl_d && !dl_rom) rom_loaded <= 1'b1;
end

// the disk: present once an image is mounted; a new image resets the board
reg  hdd_ready = 1'b0;
reg  [23:0] mnt_hold = 24'd0;
always @(posedge clk_sys) begin
	if (img_mounted) begin
		hdd_ready <= img_size != 0;
		mnt_hold  <= 24'hffffff;          // ~175 ms of reset
	end else if (mnt_hold != 0) mnt_hold <= mnt_hold - 24'd1;
end

wire core_reset = reset | ioctl_download | ~rom_loaded | ~hdd_ready | (mnt_hold != 0);
wire mem_reset  = reset & ~ioctl_download;

reg [3:0] rst_sr = 4'hf;
always @(posedge clk_vid) rst_sr <= { rst_sr[2:0], core_reset };
wire rst_vid = |rst_sr;

// The set: the .mra's <rom index="1">, written by scripts/build_mras.py --
//   byte 0  the map: 0 djmainj, 1 djmainu, 2 djmaina (dj_main)
//   byte 1  the inputs: 0 beatmania, 1 pop'n music, 2 pop'n stage
//   byte 2  bit 0: a master ATA password locks the disk, bit 1: a user one
//   byte 3  the disk's heads, byte 4 its sectors per track (MAME's CHD)
//   16-47   the master password, 48-79 the user password (dj_ata)
reg [7:0] cfg[5];
initial begin cfg[0] = 8'd0; cfg[1] = 8'd0; cfg[2] = 8'd0; cfg[3] = 8'd0; cfg[4] = 8'd0; end
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd1 && ioctl_addr < 27'd5) cfg[ioctl_addr[2:0]] <= ioctl_dout;
wire       pw_we = ioctl_wr && ioctl_index == 16'd1 && ioctl_addr >= 27'd16 && ioctl_addr < 27'd80;
wire [5:0] pw_a  = 6'(ioctl_addr - 27'd16);
wire [1:0] layout = cfg[1][1:0];

// DIP switches: <switches> on index 254, byte 0 DSW1 (SW1), 1 DSW2, 2 DSW3
reg [7:0] sw[3];
initial begin sw[0] = 8'hff; sw[1] = 8'hff; sw[2] = 8'hff; end
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd254 && ioctl_addr < 27'd3) sw[ioctl_addr[1:0]] <= ioctl_dout;

///////////////////////   MEMORY   ///////////////////////////////

wire        rom_cs, rom_ok;
wire [16:0] rom_addr;
wire [63:0] rom_data;
wire        cd_cs, cd_ok;
wire [23:0] cd_addr;
wire [63:0] cd_data;
wire        cw_req, cw_busy;
wire [26:0] cw_addr;
wire [15:0] cw_data;
wire  [1:0] cw_be;
wire        tile_cs, tile_ok, tile2_cs, tile2_ok, obj_cs, obj_ok;
wire [18:0] tile_addr, tile2_addr;
wire [31:0] tile_data, tile2_data;
wire [17:0] obj_addr;
wire [63:0] obj_data;
wire        p0_cs, p0_ok, p1_cs, p1_ok, snd_inval, rw_req, rw_busy;
wire [21:0] p0_addr, p1_addr;
wire [63:0] p0_data, p1_data;
wire [26:0] rw_addr;
wire [15:0] rw_data;

dj_sdram_top u_mem (
	.clk(clk_vid), .clk_mem(clk_sys), .reset(mem_reset), .init(~pll_locked),
	.SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS,
	.SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE,
	.ioctl_download, .ioctl_index, .ioctl_wr, .ioctl_addr, .ioctl_dout, .ioctl_wait,
	.cpu_cs(rom_cs), .cpu_addr(rom_addr), .cpu_ok(rom_ok), .cpu_data(rom_data),
	.cd_cs, .cd_addr, .cd_ok, .cd_data,
	.cw_req, .cw_addr, .cw_data, .cw_be, .cw_busy,
	.tile_cs, .tile_addr, .tile_ok, .tile_data,
	.tile2_cs, .tile2_addr, .tile2_ok, .tile2_data,
	.obj_cs, .obj_addr, .obj_ok, .obj_data,
	.pcm0_cs(p0_cs), .pcm0_addr(p0_addr), .pcm0_ok(p0_ok), .pcm0_data(p0_data),
	.pcm1_cs(p1_cs), .pcm1_addr(p1_addr), .pcm1_ok(p1_ok), .pcm1_data(p1_data),
	.pcm_inval(snd_inval | cw_req),
	.rw_req, .rw_addr, .rw_data, .rw_busy
);

///////////////////////   CONTROLS   /////////////////////////////
// joystick_N: right, left, down, up, then the J1 buttons from bit 4:
// Key 1-5 at 4-8, Scratch Up 9, Scratch Down 10, Start 11, Coin 12,
// Effect 13, Test 14, Service 15

wire [31:0] j0 = joystick_0, j1 = joystick_1;

// The ports, active low, in three layouts (djmain.cpp). The joystick bits
// each layout reads, from bit 4, are what its .mra's <buttons> names:
//   0 beatmania (beatmania_btn), two players: Key 1-5, Scratch Up, Scratch
//     Down, Start, Coin, Effect, Test, Service
//   1 pop'n music (popn_btn), one player: Button 1-9, Coin, Test, Service
//   2 pop'n stage (popnstage), one player: Button 1-10 (the panels), Left,
//     OK, Right (the selection buttons, START1-3), Coin, Test, Service
wire [7:0] bm_btn1 = ~{ j1[5], j1[4], 1'b0, j0[4], j0[5], j0[6], j0[7], j0[8] };
wire [7:0] bm_btn2 = ~{ j0[12] | j1[12], j0[13] | j1[13], j1[11], j0[11], 1'b0, j1[8], j1[7], j1[6] };
wire [7:0] bm_btn3 = ~{ 5'd0, j0[15] | j1[15], 1'b0, j0[14] | j1[14] };
// pop'n: BTN1 bits 4-0 Button 1-5, 6-7 Button 6-7; BTN2 bits 0-1 Button 8-9
wire [7:0] pm_btn1 = ~{ j0[10], j0[9], 1'b0, j0[4], j0[5], j0[6], j0[7], j0[8] };
wire [7:0] pm_btn2 = ~{ j0[13], 5'd0, j0[12], j0[11] };
wire [7:0] pm_btn3 = ~{ 5'd0, j0[15], 1'b0, j0[14] };
// pop'n stage: Button 10 at BTN2 bit 2, START1-3 at bits 4-6
wire [7:0] ps_btn2 = ~{ j0[17], j0[16], j0[15], j0[14], 1'b0, j0[13], j0[12], j0[11] };
wire [7:0] ps_btn3 = ~{ 5'd0, j0[19], 1'b0, j0[18] };
wire [7:0] in_btn1 = layout == 2'd0 ? bm_btn1 : pm_btn1;
wire [7:0] in_btn2 = layout == 2'd0 ? bm_btn2 : layout == 2'd1 ? pm_btn2 : ps_btn2;
wire [7:0] in_btn3 = layout == 2'd0 ? bm_btn3 : layout == 2'd1 ? pm_btn3 : ps_btn3;

// Turntables: MAME keeps a 16-bit position and adds 70 for each unit the
// dial moved (turntable_r); the game reads the high byte. MAME's dial, at
// sensitivity 30 and key delta 15, moves about 15 units a frame for a held
// key: some 1000 a frame. Here, per player:
//   Scratch Up / Down or the d-pad's up / down: speed * 256 a frame
//   the chosen analog stick's X: x * speed * 2 a frame (full = the buttons)
//   the spinner, and the mouse for one player: each count * speed * 4
// The buttons' and the stick's motion is spread over the frame, 1/418 of it
// every scanline (the position kept with 16 bits of fraction: 65536 / 418 =
// 157 a line), so a scratch moves the count within a line of the press
// rather than at the next vblank; the spinner and mouse add as they report.
wire [3:0] tt_speed = { 1'b0, status[12:10] } + 4'd4 > 4'd8 ? { 1'b0, status[12:10] } - 4'd4 : { 1'b0, status[12:10] } + 4'd4;
reg        hs_d = 1'b0, mouse_d = 1'b0;
wire       hs_pulse;
always @(posedge clk_sys) begin hs_d <= hs_pulse; mouse_d <= ps2_mouse[24]; end
wire       line_edge  = hs_pulse && !hs_d;
wire       mouse_edge = ps2_mouse[24] != mouse_d;
wire signed [17:0] spd256 = $signed({ 5'd0, tt_speed, 9'd0 }) >>> 1;   // speed * 256
wire signed [17:0] spd4   = $signed({ 12'd0, tt_speed, 2'b00 });
wire signed [17:0] spd2   = $signed({ 13'd0, tt_speed, 1'b0 });
wire signed [17:0] dms    = $signed({ {9{ps2_mouse[4]}}, ps2_mouse[4], ps2_mouse[15:8] }) * spd4;
wire [15:0] tt_pos [2];

genvar gp;
generate for (gp = 0; gp < 2; gp++) begin : g_tt
	wire [31:0] jj  = gp == 0 ? j0 : j1;
	wire  [8:0] spn = gp == 0 ? spinner_0 : spinner_1;
	wire  [7:0] sl  = gp == 0 ? joystick_l_analog_0[7:0] : joystick_l_analog_1[7:0];
	wire  [7:0] sr  = gp == 0 ? joystick_r_analog_0[7:0] : joystick_r_analog_1[7:0];
	wire  [7:0] sx8 = status[9:8] == 2'd0 ? sl : status[9:8] == 2'd1 ? sr : 8'd0;
	wire signed [17:0] dbtn = ((jj[9] | jj[3]) ? spd256 : 18'sd0) - ((jj[10] | jj[2]) ? spd256 : 18'sd0);
	wire signed [17:0] dstk = $signed({ {10{sx8[7]}}, sx8 }) * spd2;
	wire signed [17:0] dspn = $signed({ {10{spn[7]}}, spn[7:0] }) * spd4;
	reg         spin_d = 1'b0;
	reg  [31:0] pos = 32'd0;                       // 16.16
	wire signed [17:0] ev = (spn[8] != spin_d ? dspn : 18'sd0)
	                      + (mouse_edge && status[14] == gp ? dms : 18'sd0);
	// registered in stages (a few 96 MHz clocks, nothing to a scanline)
	reg  signed [17:0] rate0 = 18'sd0;
	reg  signed [31:0] rate = 32'sd0, sum = 32'sd0;
	reg                le_d = 1'b0;
	reg  signed [17:0] ev_d = 18'sd0;
	always @(posedge clk_sys) begin
		spin_d <= spn[8];
		rate0  <= dbtn + dstk;
		rate   <= 32'(rate0) * 32'sd157;
		le_d   <= line_edge;
		ev_d   <= ev;
		sum    <= (le_d ? rate : 32'sd0) + (32'(ev_d) <<< 16);
		pos    <= status[13] ? pos - 32'(sum) : pos + 32'(sum);
	end
	assign tt_pos[gp] = pos[31:16];
end endgenerate

// pause: none (the OSD's) -- the game's timing is the music's
wire pause_cpu = 1'b0;

///////////////////////   THE BOARD   ////////////////////////////

wire        tm_reg_we, vram_we, vram_rd, k55_we, pal_we;
wire  [4:0] tm_reg_addr;
wire [15:0] tm_reg_din, vram_din, vram_dout;
wire [15:0] tm_regs [32];
wire  [1:0] tm_reg_be, vram_be;
wire [15:0] vram_addr;
wire  [5:0] k55_addr;
wire  [7:0] k55_din;
wire [12:0] pal_addr;
wire  [2:0] pal_be;
wire [23:0] pal_din, pal_dout;
wire  [8:0] or_addr;
wire [31:0] or_q;
wire        vblank_irq;
wire        s_cs0, s_cs1, s_we, s_ack;
wire [10:0] s_addr;
wire [15:0] s_din, s_dout;
wire        a_req_t, a_cs1, a_we, a_ack_t, ata_intrq;
wire  [2:0] a_reg;
wire [15:0] a_wdata, a_rdata;
wire  [7:0] pcb_leds;

dj_main u_main (
	.rst(rst_vid), .clk(clk_vid), .clk_cpu, .pause(pause_cpu), .cpu_fast(status[15]), .map_v(cfg[0][1:0]),
	.rom_cs, .rom_addr, .rom_ok, .rom_data,
	.cd_cs, .cd_addr, .cd_ok, .cd_data,
	.cw_req, .cw_addr, .cw_data, .cw_be, .cw_busy,
	.tm_reg_we, .tm_reg_addr, .tm_reg_din, .tm_reg_be, .tm_regs,
	.vram_we, .vram_rd, .vram_addr, .vram_din, .vram_be, .vram_dout,
	.k55_we, .k55_addr, .k55_din,
	.pal_we, .pal_addr, .pal_be, .pal_din, .pal_dout,
	.or_addr, .or_q, .vblank_irq,
	.snd_cs0(s_cs0), .snd_cs1(s_cs1), .snd_we(s_we), .snd_addr(s_addr), .snd_din(s_din), .snd_dout(s_dout), .snd_ack(s_ack),
	.a_req_t, .a_cs1, .a_reg, .a_we, .a_wdata, .a_ack_t, .a_rdata, .ata_intrq,
	.in_dsw1(sw[0]), .in_dsw2(sw[1]), .in_dsw3({ 2'b11, sw[2][5:0] }),
	.in_btn1, .in_btn2, .in_btn3,
	.tt_pos0(tt_pos[0]), .tt_pos1(tt_pos[1]),
	.pcb_leds, .lamps1(), .lamps2()
);
assign LED_USER = ioctl_download | ~pcb_leds[0];

wire        ce_pix, hblank, vblank, hsync, vsync, vb_next;
wire [23:0] rgb;
wire  [2:0] vdbg;
dj_video u_video (
	.clk(clk_vid), .rst(rst_vid),
	.tm_reg_we, .tm_reg_addr, .tm_reg_din, .tm_reg_be, .tm_regs,
	.vram_we, .vram_rd, .vram_addr, .vram_din, .vram_be, .vram_dout,
	.k55_we, .k55_addr, .k55_din,
	.pal_we, .pal_addr, .pal_be, .pal_din, .pal_dout,
	.or_addr, .or_q,
	.tile_addr, .tile_cs, .tile_ok, .tile_data,
	.tile2_addr, .tile2_cs, .tile2_ok, .tile2_data,
	.obj_addr, .obj_cs, .obj_ok, .obj_data,
	.ce_pix, .rgb, .hblank, .vblank, .hsync, .vsync, .vb_next, .vblank_irq, .dbg(vdbg)
);
assign hs_pulse = hsync;

dj_sound u_sound (
	.clk(clk_vid), .rst(rst_vid),
	.cs0(s_cs0), .cs1(s_cs1), .we(s_we), .addr(s_addr), .din(s_din), .dout(s_dout), .ack(s_ack),
	.p0_cs, .p0_addr, .p0_ok, .p0_data,
	.p1_cs, .p1_addr, .p1_ok, .p1_data,
	.inval(snd_inval),
	.w_req(rw_req), .w_addr(rw_addr), .w_data(rw_data), .w_busy(rw_busy),
	.aud_l, .aud_r
);

dj_ata u_ata (
	.cfg_heads(cfg[3]), .cfg_spt(cfg[4]), .cfg_lock_m(cfg[2][0]), .cfg_lock_u(cfg[2][1]),
	.pw_we, .pw_a, .pw_d(ioctl_dout),
	.clk_sys, .clk(clk_vid), .rst(core_reset),
	.a_req_t, .a_cs1, .a_reg, .a_we, .a_wdata, .a_ack_t, .a_rdata, .intrq(ata_intrq), .active(ata_active),
	.img_mounted, .img_readonly, .img_size,
	.sd_lba, .sd_blk_cnt, .sd_rd, .sd_wr, .sd_ack,
	.sd_buff_addr, .sd_buff_dout, .sd_buff_din, .sd_buff_wr
);

///////////////////////   VIDEO OUT   ////////////////////////////
// The native picture: 24 kHz, never through the scandoubler (it would make
// 48 kHz). No gamma: MiSTer's gamma_corr needs 4 clocks a pixel, and the
// board's dots are 3 (48 MHz / 16 MHz); it would mix up the colours.

wire [7:0] nv_r, nv_g, nv_b;
wire       nv_ce, nv_hs, nv_vs, nv_de, nv_vid_clk;
wire [1:0] nv_sl;

arcade_video #(.WIDTH(512), .DW(24), .GAMMA(0)) arcade_video
(
	.clk_video(clk_vid),
	.ce_pix(ce_pix),
	.RGB_in(rgb),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hsync),
	.VSync(vsync),
	.CLK_VIDEO(nv_vid_clk),
	.CE_PIXEL(nv_ce),
	.VGA_R(nv_r), .VGA_G(nv_g), .VGA_B(nv_b),
	.VGA_HS(nv_hs), .VGA_VS(nv_vs),
	.VGA_DE(nv_de),
	.VGA_SL(nv_sl),
	.fx(3'd0),
	.forced_scandoubler(1'b0),
	.gamma_bus(gamma_bus)
);

assign CLK_VIDEO = nv_vid_clk;

`ifdef CRT_480I
// ---- DJMainSD: analog is 15 kHz 480i only (crt_480i), HDMI the native picture
// The module re-times the 512x384, 24.24 kHz, 57.997 Hz picture into 541
// half-lines a frame (15.69 kHz), one field per source frame, phase-locked to
// it. It stores the finished colour (packed 24-bit, LUT_EXT 0), so every
// pixel is the one HDMI shows, palette changes included. Until it has locked
// (about 5 frames after load or reset) the analog output is black with both
// syncs idle; there is no path from the native picture to VGA_*. Output
// pixels: 48 MHz / 4.5 (CLK_FRAC) = 10.67 MHz, the standard 480i rate.
// The menu bits come from hps_io on clk_sys: two flops onto clk_vid.
reg [32:16] st480_m, st480;
always @(posedge clk_vid) begin st480_m <= status[32:16]; st480 <= st480_m; end

wire       ce480, f480;
wire [7:0] r480, g480, b480;
wire       hs480, vs480, de480;

crt_480i #(.CLK_HZ(48_000_000), .CLK_DIV(4), .CLK_FRAC(1), .PW(24), .LUT_EXT(0)) crt_480i
(
	.clk      (clk_vid),
	.ce_in    (ce_pix),
	.pix_in   (rgb),
	.vs_in    (vsync), .de_in(~hblank & ~vblank),
	.hoffset  ($signed({ st480[27], st480[27:22] })),
	.voffset  ($signed({ {2{st480[32]}}, st480[32:28] })),
	.deflicker(st480[18:16]),
	.vheight  (st480[21:19]),
	.lut_addr (), .lut_rgb(24'd0),
	.ce_out   (ce480),
	.r_out    (r480), .g_out(g480), .b_out(b480),
	.hs_out   (hs480), .vs_out(vs480), .de_out(de480),
	.hb_out   (), .vb_out(),
	.field    (f480),
	.locked   ()
);

assign CE_PIXEL = ce480;
assign VGA_R    = r480;
assign VGA_G    = g480;
assign VGA_B    = b480;
assign VGA_HS   = hs480;
assign VGA_VS   = vs480;
assign VGA_DE   = de480;
assign VGA_F1   = f480;
assign VGA_SL   = 2'd0;

assign NATIVE_CE = nv_ce;
assign NATIVE_R  = nv_r;
assign NATIVE_G  = nv_g;
assign NATIVE_B  = nv_b;
assign NATIVE_HS = nv_hs;
assign NATIVE_VS = nv_vs;
assign NATIVE_DE = nv_de;
`else
// ---- DJMain: analog the native 24 kHz picture through CRT Adjust, HDMI the
// native picture untouched (NATIVE_*). With CRT Adjust Off (the default) the
// adjust is a true bypass and both outputs are the same stream.
// The menu bits come from hps_io on clk_sys: two flops onto clk_vid.
reg [116:96] sta_m, sta;
always @(posedge clk_vid) begin sta_m <= status[116:96]; sta <= sta_m; end
reg vsync_d = 1'b0;
always @(posedge clk_vid) vsync_d <= vsync;

wire        ca_ce, ca_hb, ca_vb, ca_hs, ca_vs;
wire [23:0] ca_rgb;
dj_crt_adjust crt_adjust
(
	.clk(clk_vid), .ce_pix(ce_pix),
	.frame_event(vsync && !vsync_d),          // once per frame, inside vertical blanking
	.osd_on(sta[96]), .osd_hsize(sta[116:112]), .osd_hpos(sta[104:101]), .osd_vshift(sta[108:105]),
	.vb_next(vb_next),
	.rgb_in(rgb), .hblank_in(hblank), .vblank_in(vblank), .hsync_in(hsync), .vsync_in(vsync),
	.ce_out(ca_ce), .rgb_out(ca_rgb), .hblank_out(ca_hb), .vblank_out(ca_vb),
	.hsync_out(ca_hs), .vsync_out(ca_vs),
	.active(), .hsize_s(), .hpos_s(), .vsh_s()
);

wire [7:0] av_r, av_g, av_b;
wire       av_ce, av_hs, av_vs, av_de;
wire [1:0] av_sl;
arcade_video #(.WIDTH(512), .DW(24), .GAMMA(0)) arcade_video_vga
(
	.clk_video(clk_vid),
	.ce_pix(ca_ce),
	.RGB_in(ca_rgb),
	.HBlank(ca_hb),
	.VBlank(ca_vb),
	.HSync(ca_hs),
	.VSync(ca_vs),
	.CLK_VIDEO(),
	.CE_PIXEL(av_ce),
	.VGA_R(av_r), .VGA_G(av_g), .VGA_B(av_b),
	.VGA_HS(av_hs), .VGA_VS(av_vs),
	.VGA_DE(av_de),
	.VGA_SL(av_sl),
	.fx(3'd0),
	.forced_scandoubler(1'b0),
	.gamma_bus()
);

assign CE_PIXEL = av_ce;
assign VGA_R    = av_r;
assign VGA_G    = av_g;
assign VGA_B    = av_b;
assign VGA_HS   = av_hs;
assign VGA_VS   = av_vs;
assign VGA_DE   = av_de;
assign VGA_F1   = 1'b0;
assign VGA_SL   = av_sl;

assign NATIVE_CE = nv_ce;
assign NATIVE_R  = nv_r;
assign NATIVE_G  = nv_g;
assign NATIVE_B  = nv_b;
assign NATIVE_HS = nv_hs;
assign NATIVE_VS = nv_vs;
assign NATIVE_DE = nv_de;
`endif

endmodule
