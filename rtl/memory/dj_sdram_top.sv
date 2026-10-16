// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami DJ Main: everything the board keeps in SDRAM, on sdram.sv's three
// fixed-priority ports (port 0 preempts 1, 1 preempts 2). The controller,
// arbiter, download and client ports are Arcade-KonamiGX_MiSTer's
// (rtl/memory/sdram/PROVENANCE.md); the map and the clients are this board's.
//
//   port 0  tiles (two clients) and sprites: the line-time deadlines
//   port 1  the two K054539s' sample and reverb reads, their reverb writes
//   port 2  the CPU: its ROM cache, its data reads (sound DRAM, the ROM
//           readback windows), its sound DRAM writes; the ROM download
//
// Image (byte addresses), loaded from the .mra's index 0 stream:
//   0x0000000  program ROM, 1 MB, 68000 order (even byte first)
//   0x0100000  sprite ROM, 2 MB, each 128-byte tile re-ordered on the way in
//              so a 16-pixel row is one granule: MAME byte o of a tile
//              (rows 0-7 left half at 0-31, right half at 32-63, rows 8-15
//              at 64-127) goes to { row, half, byte } = { o[6], o[4:2],
//              o[5], o[1:0] }
//   0x0300000  tile ROM, 2 MB, MAME's region as it is (4 bytes a row)
// Written at runtime:
//   0x0500000  the K054539s' own RAM (reverb), 32 KB each
//   0x1000000  the 16 MB sound DRAM
//
// Clocks: clk_mem (96 MHz) for the controller and arbiters, clk (48 MHz) for
// the clients, crossed in gx_rom_port and dj_wr_port.

`default_nettype none

module dj_sdram_top (
    input  wire        clk,
    input  wire        clk_mem,
    input  wire        reset,         // reset & ~ioctl_download
    input  wire        init,          // ~pll_locked

    output wire [12:0] SDRAM_A,
    inout  wire [15:0] SDRAM_DQ,
    output wire        SDRAM_DQML,
    output wire        SDRAM_DQMH,
    output wire  [1:0] SDRAM_BA,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nWE,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_CKE,

    // hps_io download (clk_mem)
    input  wire        ioctl_download,
    input  wire [15:0] ioctl_index,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    output wire        ioctl_wait,

    // CPU ROM cache: a granule of the program ROM
    input  wire        cpu_cs,
    input  wire [16:0] cpu_addr,
    output wire        cpu_ok,
    output wire [63:0] cpu_data,

    // CPU data reads: an absolute granule (sound DRAM, ROM readback)
    input  wire        cd_cs,
    input  wire [23:0] cd_addr,
    output wire        cd_ok,
    output wire [63:0] cd_data,
    // CPU writes: a word of the sound DRAM (absolute byte address)
    input  wire        cw_req,
    input  wire [26:0] cw_addr,
    input  wire [15:0] cw_data,       // SDRAM lanes
    input  wire  [1:0] cw_be,
    output wire        cw_busy,

    // tiles: row index (code * 8 + y), its four bytes in [31:0]
    input  wire        tile_cs,
    input  wire [18:0] tile_addr,
    output wire        tile_ok,
    output wire [31:0] tile_data,
    input  wire        tile2_cs,
    input  wire [18:0] tile2_addr,
    output wire        tile2_ok,
    output wire [31:0] tile2_data,

    // sprites: { code[13:0], row[3:0] }, the row's 8 bytes (byte k at [8k +: 8])
    input  wire        obj_cs,
    input  wire [17:0] obj_addr,
    output wire        obj_ok,
    output wire [63:0] obj_data,

    // the K054539s' reads: a granule of their space (gx_k054539 p_addr: the
    // samples, then each chip's RAM from 0x200000)
    input  wire        pcm0_cs,
    input  wire [21:0] pcm0_addr,
    output wire        pcm0_ok,
    output wire [63:0] pcm0_data,
    input  wire        pcm1_cs,
    input  wire [21:0] pcm1_addr,
    output wire        pcm1_ok,
    output wire [63:0] pcm1_data,
    input  wire        pcm_inval,     // a write landed: drop held granules
    // their reverb writes: a word of a chip's RAM
    input  wire        rw_req,
    input  wire [26:0] rw_addr,
    input  wire [15:0] rw_data,
    output wire        rw_busy
);

localparam [26:0] BASE_PROG = 27'h000_0000;
localparam [26:0] BASE_OBJ  = 27'h010_0000;
localparam [26:0] BASE_TILE = 27'h030_0000;

// ------------------------------------------------------------ download
logic [26:0] io_addr_q;
logic        io_wr_q, io_dl_q;
logic [15:0] io_index_q;
logic  [7:0] io_dout_q;
always_ff @(posedge clk_mem) begin
    io_addr_q  <= ioctl_addr;
    io_wr_q    <= ioctl_wr;
    io_dl_q    <= ioctl_download;
    io_index_q <= ioctl_index;
    io_dout_q  <= ioctl_dout;
end
wire [26:0] s      = io_addr_q;
wire        in_obj = s >= BASE_OBJ && s < BASE_TILE;
wire [26:0] o      = s - BASE_OBJ;
wire [26:0] dl_addr_c = in_obj ? BASE_OBJ + { o[26:7], o[6], o[4:2], o[5], o[1:0] } : s;

logic [26:0] dl_addr_q;
logic        dl_wr_q, dl_dl_q;
logic [15:0] dl_index_q;
logic  [7:0] dl_dout_q;
always_ff @(posedge clk_mem) begin
    dl_addr_q  <= dl_addr_c;
    dl_wr_q    <= io_wr_q && s < 27'h050_0000;
    dl_dl_q    <= io_dl_q;
    dl_index_q <= io_index_q;
    dl_dout_q  <= io_dout_q;
end

wire        dl_req, dl_we16, dl_busy2, dl_wait;
wire [26:0] dl_addr;
wire [15:0] dl_data;
assign ioctl_wait = dl_wait | ioctl_wr | io_wr_q | dl_wr_q;

sdram_download u_dl (
    .clk(clk_mem), .reset(reset),
    .ioctl_download(dl_dl_q), .ioctl_index(dl_index_q),
    .ioctl_wr(dl_wr_q), .ioctl_addr(dl_addr_q), .ioctl_dout(dl_dout_q),
    .ioctl_wait(dl_wait),
    .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
    .dl_we16(dl_we16), .dl_busy(dl_busy2)
);

// ------------------------------------------------------------ the chip
logic [26:1] p_addr [0:2];
logic        p_wrl  [0:2], p_wrh [0:2], p_req [0:2];
logic [15:0] p_din  [0:2];
wire  [63:0] p_dout [0:2];
wire         p_ack  [0:2];
wire  [63:0] p_dout0b;

sdram u_sdram (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CLK(), .SDRAM_CKE(SDRAM_CKE),
    .init(init), .clk(clk_mem),
    .addr0(p_addr[0]), .wrl0(p_wrl[0]), .wrh0(p_wrh[0]), .din0(p_din[0]),
    .dout0(p_dout[0]), .req0(p_req[0]), .ack0(p_ack[0]), .dbl0(1'b0), .dout0b(p_dout0b),
    .addr1(p_addr[1]), .wrl1(p_wrl[1]), .wrh1(p_wrh[1]), .din1(p_din[1]),
    .dout1(p_dout[1]), .req1(p_req[1]), .ack1(p_ack[1]),
    .addr2(p_addr[2]), .wrl2(p_wrl[2]), .wrh2(p_wrh[2]), .din2(p_din[2]),
    .dout2(p_dout[2]), .req2(p_req[2]), .ack2(p_ack[2])
);

// ------------------------------------------------------------ port 0: video
wire [2:0]    a0_req, a0_valid;
wire [80:0]   a0_addr;
wire [63:0]   a0_rdata;
wire [63:0]   tile_g, tile2_g;

sdram_arbiter #(.N(3), .HI(0)) u_arb0 (
    .clk(clk_mem), .reset(reset),
    .port_addr(p_addr[0]), .port_wrl(p_wrl[0]), .port_wrh(p_wrh[0]),
    .port_din(p_din[0]), .port_dout(p_dout[0]),
    .port_req(p_req[0]), .port_ack(p_ack[0]),
    .c_req(a0_req), .c_addr(a0_addr), .c_valid(a0_valid), .c_rdata(a0_rdata),
    .c_dbl(3'b000), .c_rdata2(), .port_dout2(64'd0), .port_dbl(),
    .dl_req(1'b0), .dl_addr(27'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
);

gx_rom_port #(.AW(19)) u_tile (
    .clk, .clk_mem, .rst(reset),
    .cs(tile_cs), .addr(tile_addr), .ok(tile_ok), .data(tile_g),
    .hint_cs(1'b0), .hint_addr(19'd0), .halfsel(1'b1), .inval(1'b0),
    .base(BASE_TILE),
    .c_req(a0_req[0]), .c_addr(a0_addr[26:0]), .c_valid(a0_valid[0]), .c_rdata(a0_rdata), .c_dbl(), .c_rdata2(64'd0)
);
gx_rom_port #(.AW(19)) u_tile2 (
    .clk, .clk_mem, .rst(reset),
    .cs(tile2_cs), .addr(tile2_addr), .ok(tile2_ok), .data(tile2_g),
    .hint_cs(1'b0), .hint_addr(19'd0), .halfsel(1'b1), .inval(1'b0),
    .base(BASE_TILE),
    .c_req(a0_req[1]), .c_addr(a0_addr[53:27]), .c_valid(a0_valid[1]), .c_rdata(a0_rdata), .c_dbl(), .c_rdata2(64'd0)
);
assign tile_data  = tile_g[31:0];
assign tile2_data = tile2_g[31:0];

gx_rom_port #(.AW(18)) u_obj (
    .clk, .clk_mem, .rst(reset),
    .cs(obj_cs), .addr(obj_addr), .ok(obj_ok), .data(obj_data),
    .hint_cs(1'b0), .hint_addr(18'd0), .halfsel(1'b0), .inval(1'b0),
    .base(BASE_OBJ),
    .c_req(a0_req[2]), .c_addr(a0_addr[80:54]), .c_valid(a0_valid[2]), .c_rdata(a0_rdata), .c_dbl(), .c_rdata2(64'd0)
);

// ------------------------------------------------------------ port 1: sound
wire [1:0]    a1_req, a1_valid;
wire [53:0]   a1_addr;
wire [63:0]   a1_rdata;
wire          rw_dl_req, rw_dl_we16, rw_dl_busy;
wire [26:0]   rw_dl_addr;
wire [15:0]   rw_dl_data;

sdram_arbiter #(.N(2), .HI(0)) u_arb1 (
    .clk(clk_mem), .reset(reset),
    .port_addr(p_addr[1]), .port_wrl(p_wrl[1]), .port_wrh(p_wrh[1]),
    .port_din(p_din[1]), .port_dout(p_dout[1]),
    .port_req(p_req[1]), .port_ack(p_ack[1]),
    .c_req(a1_req), .c_addr(a1_addr), .c_valid(a1_valid), .c_rdata(a1_rdata),
    .c_dbl(2'b00), .c_rdata2(), .port_dout2(64'd0), .port_dbl(),
    .dl_req(rw_dl_req), .dl_addr(rw_dl_addr), .dl_data(rw_dl_data), .dl_we16(rw_dl_we16), .dl_busy(rw_dl_busy)
);

// a granule of the chips' space to an absolute one: samples at 0x1000000,
// the chips' RAM (from granule 0x200000) at 0x500000
function automatic [23:0] pcm_g( input [21:0] g );
    pcm_g = g[21] ? 24'h0A_0000 + 24'(g[20:0] - 21'h0) : 24'h20_0000 + 24'(g[20:0]);
endfunction

gx_rom_port #(.AW(24), .NS(1)) u_pcm0 (
    .clk, .clk_mem, .rst(reset),
    .cs(pcm0_cs), .addr(pcm_g(pcm0_addr)), .ok(pcm0_ok), .data(pcm0_data),
    .hint_cs(1'b0), .hint_addr(24'd0), .halfsel(1'b0), .inval(pcm_inval),
    .base(27'd0),
    .c_req(a1_req[0]), .c_addr(a1_addr[26:0]), .c_valid(a1_valid[0]), .c_rdata(a1_rdata), .c_dbl(), .c_rdata2(64'd0)
);
gx_rom_port #(.AW(24), .NS(1)) u_pcm1 (
    .clk, .clk_mem, .rst(reset),
    .cs(pcm1_cs), .addr(pcm_g(pcm1_addr)), .ok(pcm1_ok), .data(pcm1_data),
    .hint_cs(1'b0), .hint_addr(24'd0), .halfsel(1'b0), .inval(pcm_inval),
    .base(27'd0),
    .c_req(a1_req[1]), .c_addr(a1_addr[53:27]), .c_valid(a1_valid[1]), .c_rdata(a1_rdata), .c_dbl(), .c_rdata2(64'd0)
);

dj_wr_port u_rw (
    .clk, .clk_mem, .rst(reset),
    .req(rw_req), .addr(rw_addr), .data(rw_data), .be(2'b11), .busy(rw_busy),
    .dl_req(rw_dl_req), .dl_addr(rw_dl_addr), .dl_data(rw_dl_data), .dl_we16(rw_dl_we16), .dl_busy(rw_dl_busy)
);

// ------------------------------------------------------------ port 2: CPU
wire [1:0]    a2_req, a2_valid;
wire [53:0]   a2_addr;
wire [63:0]   a2_rdata;
wire          cw_dl_req, cw_dl_we16, a2_dl_busy;
wire [26:0]   cw_dl_addr;
wire [15:0]   cw_dl_data;

// the write path: the download while it runs, the CPU's writes after
wire          a2_dl_req  = dl_dl_q ? dl_req  : cw_dl_req;
wire [26:0]   a2_dl_addr = dl_dl_q ? dl_addr : cw_dl_addr;
wire [15:0]   a2_dl_data = dl_dl_q ? dl_data : cw_dl_data;
wire          a2_dl_we16 = dl_dl_q ? dl_we16 : cw_dl_we16;
assign dl_busy2 = a2_dl_busy;

sdram_arbiter #(.N(2), .HI(1)) u_arb2 (
    .clk(clk_mem), .reset(reset),
    .port_addr(p_addr[2]), .port_wrl(p_wrl[2]), .port_wrh(p_wrh[2]),
    .port_din(p_din[2]), .port_dout(p_dout[2]),
    .port_req(p_req[2]), .port_ack(p_ack[2]),
    .c_req(a2_req), .c_addr(a2_addr), .c_valid(a2_valid), .c_rdata(a2_rdata),
    .c_dbl(2'b00), .c_rdata2(), .port_dout2(64'd0), .port_dbl(),
    .dl_req(a2_dl_req), .dl_addr(a2_dl_addr), .dl_data(a2_dl_data), .dl_we16(a2_dl_we16), .dl_busy(a2_dl_busy)
);

gx_rom_port #(.AW(17)) u_cpu (
    .clk, .clk_mem, .rst(reset),
    .cs(cpu_cs), .addr(cpu_addr), .ok(cpu_ok), .data(cpu_data),
    .hint_cs(1'b0), .hint_addr(17'd0), .halfsel(1'b0), .inval(1'b0),
    .base(BASE_PROG),
    .c_req(a2_req[0]), .c_addr(a2_addr[26:0]), .c_valid(a2_valid[0]), .c_rdata(a2_rdata), .c_dbl(), .c_rdata2(64'd0)
);
gx_rom_port #(.AW(24), .NS(1)) u_cd (
    .clk, .clk_mem, .rst(reset),
    .cs(cd_cs), .addr(cd_addr), .ok(cd_ok), .data(cd_data),
    .hint_cs(1'b0), .hint_addr(24'd0), .halfsel(1'b0), .inval(cw_req),
    .base(27'd0),
    .c_req(a2_req[1]), .c_addr(a2_addr[53:27]), .c_valid(a2_valid[1]), .c_rdata(a2_rdata), .c_dbl(), .c_rdata2(64'd0)
);

dj_wr_port u_cw (
    .clk, .clk_mem, .rst(reset),
    .req(cw_req), .addr(cw_addr), .data(cw_data), .be(cw_be), .busy(cw_busy),
    .dl_req(cw_dl_req), .dl_addr(cw_dl_addr), .dl_data(cw_dl_data), .dl_we16(cw_dl_we16), .dl_busy(a2_dl_busy)
);

endmodule

`default_nettype wire
