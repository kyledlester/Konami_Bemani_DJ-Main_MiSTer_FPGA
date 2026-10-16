// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami DJ Main sound: the 058141, two K054539s (gx_k054539 from
// Arcade-KonamiGX_MiSTer, address widened), clocked from 18.432 MHz in the
// board and so at 48 kHz here: a sample every 1000 clocks of 48 MHz.
//
// Both chips read the one 16 MB sound DRAM (djmain.cpp k054539_map) through
// their sample pointers; each has its own 32 KB RAM for the reverb, kept in
// SDRAM after the samples' space (dj_sdram_top). That RAM is zeroed after
// each reset, before the chips run: SDRAM powers up with anything in it.
//
// The CPU reaches the chips at 0x5b0000-0x5b04ff: chip 0 on the even bytes,
// chip 1 on the odd (umask 0xff00ff00 / 0x00ff00ff), register = offset / 2.
// The chips' 0x22d port (ROM/RAM readback) answers 0: the DJ Main has no
// sample ROM and its programs do not use it.
//
// Output: both chips summed at 1.0 each (MAME's routes), saturated to 16 bits.

module dj_sound (
    input             clk,              // 48 MHz
    input             rst,

    // CPU
    input             cs0,              // chip 0 (even byte)
    input             cs1,              // chip 1 (odd byte)
    input             we,
    input      [10:0] addr,
    input      [15:0] din,              // chip 0 in [15:8], chip 1 in [7:0]
    output     [15:0] dout,
    output            ack,              // both selected chips have answered

    // SDRAM: sample/RAM reads, RAM writes
    output            p0_cs,
    output     [21:0] p0_addr,
    input             p0_ok,
    input      [63:0] p0_data,
    output            p1_cs,
    output     [21:0] p1_addr,
    input             p1_ok,
    input      [63:0] p1_data,
    output            inval,            // a reverb write landed
    output reg        w_req,
    output reg [26:0] w_addr,
    output reg [15:0] w_data,
    input             w_busy,

    output reg signed [15:0] aud_l,
    output reg signed [15:0] aud_r
);

localparam [26:0] RAM_BASE = 27'h050_0000;

// ------------------------------------------------------------ the clear
// clr is held from reset until the 32K words of both chips' RAM are written
// (by the writer below), the chips held in reset meanwhile
reg        clr = 1'b1;
reg [14:0] clr_a;
wire chips_rst = rst | clr;

// ------------------------------------------------------------ the chips
reg  [9:0] smp_cnt;
reg        smp;
always @(posedge clk) begin
    smp <= 1'b0;
    if (chips_rst) smp_cnt <= 10'd0;
    else if (smp_cnt == 10'd999) begin smp_cnt <= 10'd0; smp <= 1'b1; end
    else smp_cnt <= smp_cnt + 10'd1;
end

wire [7:0]  k_dout [2];
wire        k_ack  [2];
wire        k_mreq [2];
wire        r_req  [2];
wire [12:0] r_word [2];
wire [15:0] r_data [2];
reg         r_ack  [2];
wire signed [25:0] k_l [2], k_r [2];
wire        k_v [2];

// the CPU's access: each selected chip once, held until it answers
reg  [1:0] pend, done;
reg  [7:0] q0, q1;
wire       go = (cs0 || cs1) && pend == 2'b00 && done == 2'b00;
always @(posedge clk) begin
    if (chips_rst || !(cs0 || cs1)) begin pend <= 2'b00; done <= 2'b00; end
    else begin
        if (go) pend <= { cs1, cs0 };
        if (k_ack[0]) begin pend[0] <= 1'b0; done[0] <= 1'b1; q0 <= k_dout[0]; end
        if (k_ack[1]) begin pend[1] <= 1'b0; done[1] <= 1'b1; q1 <= k_dout[1]; end
    end
end
assign ack  = (cs0 || cs1) && done == { cs1, cs0 };
assign dout = { q0, q1 };

// a chip's request for 0x22d's byte is answered at once
reg m_ack [2];
always @(posedge clk) begin m_ack[0] <= k_mreq[0] && !m_ack[0]; m_ack[1] <= k_mreq[1] && !m_ack[1]; end

gx_k054539 #(.CHIP(0)) u_k0 (
    .clk, .rst(chips_rst),
    .cs(pend[0]), .we, .addr, .din(din[15:8]), .dout(k_dout[0]), .ack(k_ack[0]),
    .timer_out(),
    .m_req(k_mreq[0]), .m_we(), .m_ram(), .m_addr(), .m_wdata(), .m_ack(m_ack[0]), .m_rdata(8'd0),
    .smp, .pcm_mask(24'hff_ffff), .p_cs(p0_cs), .p_addr(p0_addr), .p_ok(p0_ok), .p_data(p0_data),
    .out_l(k_l[0]), .out_r(k_r[0]), .out_v(k_v[0]), .ovr(),
    .r_req(r_req[0]), .r_word(r_word[0]), .r_data(r_data[0]), .r_ack(r_ack[0]),
    .ss_freeze(1'b0), .ss_step(1'b0), .ss_sel(1'b0), .ss_addr(12'd0), .ss_we(1'b0), .ss_wd(16'd0), .ss_rd()
);
gx_k054539 #(.CHIP(1)) u_k1 (
    .clk, .rst(chips_rst),
    .cs(pend[1]), .we, .addr, .din(din[7:0]), .dout(k_dout[1]), .ack(k_ack[1]),
    .timer_out(),
    .m_req(k_mreq[1]), .m_we(), .m_ram(), .m_addr(), .m_wdata(), .m_ack(m_ack[1]), .m_rdata(8'd0),
    .smp, .pcm_mask(24'hff_ffff), .p_cs(p1_cs), .p_addr(p1_addr), .p_ok(p1_ok), .p_data(p1_data),
    .out_l(k_l[1]), .out_r(k_r[1]), .out_v(k_v[1]), .ovr(),
    .r_req(r_req[1]), .r_word(r_word[1]), .r_data(r_data[1]), .r_ack(r_ack[1]),
    .ss_freeze(1'b0), .ss_step(1'b0), .ss_sel(1'b0), .ss_addr(12'd0), .ss_we(1'b0), .ss_wd(16'd0), .ss_rd()
);

// ------------------------------------------------------------ RAM writes
// the clear, or a chip's reverb word (its r_req is a pulse; it waits for
// r_ack). One at a time through the SDRAM write port.
reg        rq_v [2];
reg [12:0] rq_w [2];
reg [15:0] rq_d [2];
reg        wsel, wact;
reg        inval_r;
assign inval = inval_r;
always @(posedge clk) begin
    w_req   <= 1'b0;
    inval_r <= 1'b0;
    r_ack[0] <= 1'b0; r_ack[1] <= 1'b0;
    if (r_req[0]) begin rq_v[0] <= 1'b1; rq_w[0] <= r_word[0]; rq_d[0] <= r_data[0]; end
    if (r_req[1]) begin rq_v[1] <= 1'b1; rq_w[1] <= r_word[1]; rq_d[1] <= r_data[1]; end
    if (rst) begin
        clr <= 1'b1; clr_a <= 15'd0;
        rq_v[0] <= 1'b0; rq_v[1] <= 1'b0; wact <= 1'b0;
    end else if (clr) begin
        if (!w_busy && !w_req) begin
            w_req  <= 1'b1; w_addr <= RAM_BASE + { 11'd0, clr_a, 1'b0 }; w_data <= 16'd0;
            clr_a  <= clr_a + 15'd1;
            if (&clr_a) clr <= 1'b0;
        end
        rq_v[0] <= 1'b0; rq_v[1] <= 1'b0;
    end else if (!wact && !w_busy && !w_req) begin
        if (rq_v[0]) begin
            wact <= 1'b1; wsel <= 1'b0; w_req <= 1'b1;
            w_addr <= RAM_BASE + { 12'd0, rq_w[0], 1'b0 }; w_data <= rq_d[0];
        end else if (rq_v[1]) begin
            wact <= 1'b1; wsel <= 1'b1; w_req <= 1'b1;
            w_addr <= RAM_BASE + 27'h8000 + { 12'd0, rq_w[1], 1'b0 }; w_data <= rq_d[1];
        end
    end else if (wact && !w_busy && !w_req) begin
        wact <= 1'b0;
        rq_v[wsel] <= 1'b0;
        r_ack[wsel] <= 1'b1;
        inval_r <= 1'b1;
    end
end

// ------------------------------------------------------------ the mix
reg signed [25:0] kl0, kr0, kl1, kr1;
wire signed [27:0] mix_l = 28'(kl0) + 28'(kl1);
wire signed [27:0] mix_r = 28'(kr0) + 28'(kr1);
function signed [15:0] sat16( input signed [27:0] v );     // v with 8 bits of fraction
    sat16 = (v >>> 8) > 28'sd32767 ? 16'sh7fff : (v >>> 8) < -28'sd32768 ? 16'sh8000 : 16'(v >>> 8);
endfunction
always @(posedge clk) begin
    if (chips_rst) begin
        kl0 <= 26'sd0; kr0 <= 26'sd0; kl1 <= 26'sd0; kr1 <= 26'sd0;
        aud_l <= 16'sd0; aud_r <= 16'sd0;
    end else begin
        if (k_v[0]) begin kl0 <= k_l[0]; kr0 <= k_r[0]; end
        if (k_v[1]) begin kl1 <= k_l[1]; kr1 <= k_r[1]; end
        if (smp_cnt == 10'd999) begin
            aud_l <= sat16(mix_l);
            aud_r <= sat16(mix_r);
        end
    end
end

endmodule
