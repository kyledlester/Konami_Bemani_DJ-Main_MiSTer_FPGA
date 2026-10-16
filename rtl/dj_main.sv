// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami DJ Main (GQ753): the 68EC020, MAME's djmainj memory map, work RAM,
// sprite RAM and registers, the interrupts, and the ports to the video,
// sound, SDRAM and hard disk. Reference: djmain.cpp (MAME 0.289); each block
// names the handler it follows. docs/RESEARCH.md has the map as a table.
//
// ---- CPU and bus
// TG68KdotC_Kernel directly, with the generics and the ready handshake of
// Arcade-KonamiGX_MiSTer's gx_main.sv (proved there against MAME's boot
// trace): the kernel on its own 24 MHz clk_cpu, `ready` held until it takes
// the access on a clock-enabled cycle, cpu_cen marking the 48 MHz cycles
// that end at a kernel edge. The 68EC020 here runs at 16 MHz (32 MHz / 2):
// `thr` enables the kernel two clk_cpu cycles in three (cpu_fast: all).
//
// One access unit takes the CPU's accesses one at a time. Internal RAMs
// answer two clocks after the address; the ROM through gx_romcache; the
// sound DRAM and the ROM readback windows through an SDRAM data port; the
// two K054539s, and the IDE registers (dj_ata, on clk_sys), each through a
// handshake.
//
// An interrupt acknowledge (FC = 111) is answered at once; TG68K
// auto-vectors and runs the cycle at 0xFFFFFFF0 | level << 1, which is how
// HOLD_LINE interrupts are cleared here.
//
// ---- interrupts (djmain.cpp)
//   level 4  vblank (vb_interrupt): at the start of vblank if v_ctrl
//            (0x5d4000) bit 15 is set, else held pending and raised when a
//            v_ctrl write sets bit 15 (v_ctrl_w). HOLD_LINE.
//   level 1  the IDE's INTRQ (ide_interrupt): raised on its rising edge,
//            held until acknowledged or until INTRQ falls.

module dj_main (
    input             rst,
    input             clk,                  // 48 MHz
    input             clk_cpu,              // 24 MHz, clk / 2, phase 0
    input             pause,
    input             cpu_fast,             // 1: no 16 MHz throttle
    input       [1:0] map_v,                // the set's map: 0 djmainj, 1 djmainu, 2 djmaina

    // program ROM: a granule (gx_romcache's port)
    output            rom_cs,
    output     [16:0] rom_addr,
    input             rom_ok,
    input      [63:0] rom_data,

    // SDRAM data reads (absolute granule) and sound DRAM writes
    output reg        cd_cs,
    output reg [23:0] cd_addr,
    input             cd_ok,
    input      [63:0] cd_data,
    output reg        cw_req,
    output reg [26:0] cw_addr,
    output reg [15:0] cw_data,
    output reg  [1:0] cw_be,
    input             cw_busy,

    // video
    output reg        tm_reg_we,
    output reg  [4:0] tm_reg_addr,
    output reg [15:0] tm_reg_din,
    output reg  [1:0] tm_reg_be,
    input      [15:0] tm_regs [32],
    output reg        vram_we,
    output            vram_rd,
    output     [15:0] vram_addr,
    output reg [15:0] vram_din,
    output reg  [1:0] vram_be,
    input      [15:0] vram_dout,
    output reg        k55_we,
    output reg  [5:0] k55_addr,
    output reg  [7:0] k55_din,
    output reg        pal_we,
    output     [12:0] pal_addr,
    output reg  [2:0] pal_be,
    output reg [23:0] pal_din,
    input      [23:0] pal_dout,
    input       [8:0] or_addr,              // sprite RAM, the video's read port
    output     [31:0] or_q,
    input             vblank_irq,

    // sound
    output reg        snd_cs0,
    output reg        snd_cs1,
    output reg        snd_we,
    output reg [10:0] snd_addr,
    output reg [15:0] snd_din,
    input      [15:0] snd_dout,
    input             snd_ack,

    // IDE (dj_ata, clk_sys)
    output reg        a_req_t = 1'b0,
    output reg        a_cs1,
    output reg  [2:0] a_reg,
    output reg        a_we,
    output reg [15:0] a_wdata,
    input             a_ack_t,
    input      [15:0] a_rdata,
    input             ata_intrq,

    // inputs, active low as MAME's ports
    input       [7:0] in_dsw1,
    input       [7:0] in_dsw2,
    input       [7:0] in_dsw3,
    input       [7:0] in_btn1,
    input       [7:0] in_btn2,
    input       [7:0] in_btn3,
    input      [15:0] tt_pos0,              // turntables: MAME's m_turntable_pos
    input      [15:0] tt_pos1,

    output reg  [7:0] pcb_leds,
    output reg [15:0] lamps1,
    output reg [15:0] lamps2
);

// ------------------------------------------------------------ clocks
reg  cpu_t = 0, cpu_t_d = 0;
always @(posedge clk_cpu) cpu_t <= ~cpu_t;
always @(posedge clk)     cpu_t_d <= cpu_t;
wire cpu_cen = cpu_t == cpu_t_d;
// 16 MHz: the kernel enabled two clk_cpu cycles in three
reg  [1:0] thr_c = 2'd0;
always @(posedge clk_cpu) thr_c <= thr_c == 2'd2 ? 2'd0 : thr_c + 2'd1;
wire thr = cpu_fast || thr_c != 2'd2;

// ------------------------------------------------------------ CPU
wire [31:0] a32;
wire [15:0] cpu_dout;
wire [ 1:0] busstate;
wire        nWr, nUDS, nLDS;
wire [ 2:0] fc;
reg  [15:0] cpu_din;
reg  [15:0] u_din;
reg         ready;
reg  [ 2:0] ipl_n = 3'b111;
wire        mem_needed = busstate != 2'b01;
wire        fast_rdy;
wire        cpu_clkena = (!mem_needed || ready || fast_rdy) && !pause && thr;
wire        cpu_take   = cpu_cen && !pause && thr;

TG68KdotC_Kernel #(
    .SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2),
    .MUL_Mode(2), .DIV_Mode(2), .BitField(2),
    .BarrelShifter(0), .MUL_Hardware(1), .DIVL_Wait(75)
) u_cpu (
    .clk(clk_cpu), .nReset(~rst), .clkena_in(cpu_clkena),
    .data_in(fast_rdy ? u_din : cpu_din), .IPL(ipl_n), .IPL_autovector(1'b1), .berr(1'b0),
    .CPU(2'b11),
    .addr_out(a32), .data_write(cpu_dout),
    .nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
    .busstate(busstate), .longword(), .nResetOut(), .FC(fc),
    .clr_berr(), .skipFetch(), .regin_out(), .CACR_out(), .VBR_out(), .FlagsSR_out(),
    .stop_out()
);

// ------------------------------------------------------------ registers
reg [15:0] v_ctrl = 16'd0;
reg        vb_pend = 1'b0, irq4 = 1'b0, irq1 = 1'b0;
reg  [4:0] snd_bank = 5'd0;
reg        tt_sel = 1'b0;
reg [15:0] obj_regs [80];                   // 0x803000-0x80309f, as words

// ------------------------------------------------------------ the unit
typedef enum logic [3:0] { U_IDLE, U_RAM, U_REG, U_VR1, U_VR2, U_ROM, U_CDW, U_CD, U_CW, U_SND, U_ATA, U_ACK } ust_t;
ust_t ust;
typedef enum logic [1:0] { C_IDLE, C_BUSY, C_READY } cst_t;
cst_t cst;
reg         u_ack;
reg  [23:1] ua_r;
reg  [ 1:0] ube_r;
reg         uwe_r;
reg  [15:0] ud_r;
reg  [ 3:0] usrc;
localparam [3:0] S_WRAM=0, S_PAL=1, S_OBJ=2, S_ZERO=3;

wire        cpu_req_now = cst == C_IDLE && mem_needed && !ready;
wire        take        = ust == U_IDLE && cpu_req_now;
wire [23:1] ua  = ust != U_IDLE ? ua_r  : a32[23:1];
wire [ 1:0] ube = ust != U_IDLE ? ube_r : { ~nUDS, ~nLDS };
wire        uwe = ust != U_IDLE ? uwe_r : busstate == 2'b11;
wire [15:0] ud  = ust != U_IDLE ? ud_r  : cpu_dout;
wire [23:0] ub  = { ua, 1'b0 };
wire        iack = fc == 3'b111;

// regions (djmain.cpp base_map + main_map_j)
wire r_rom   = ub < 24'h100000;
wire r_wram  = ub[23:16] == 8'h40;
wire r_pal   = ub >= 24'h480000 && ub < 24'h484440;
wire r_snd   = ub >= 24'h500000 && ub < 24'h580000;
wire r_k32   = ub >= 24'h580000 && ub < 24'h580040;
wire r_k55   = ub >= 24'h5a0000 && ub < 24'h5a0060;
wire r_539   = ub >= 24'h5b0000 && ub < 24'h5b0500;
wire r_in    = ub[23:16] == 8'h5c && ub[14:2] == 13'd0;
wire r_lt1   = ub == 24'h5d0000;
wire r_lt2   = ub == 24'h5d2000;
wire r_vctl  = ub == 24'h5d4000;
wire r_pcb   = ub == 24'h5d6000;
wire r_tt    = ub[23:2] == 22'(24'h5e0000 >> 2);
wire r_vrom  = ub >= 24'h600000 && ub < 24'h602000;
wire r_obj   = ub >= 24'h801000 && ub < 24'h801800;
wire r_objc  = ub >= 24'h803000 && ub < 24'h8030a0;
wire r_orom  = ub >= 24'h803800 && ub < 24'h804000;
// the three boards differ only in where the VRAM window and the IDE are
// (main_map_j, main_map_u, main_map_a)
wire [3:0] vram_hi = map_v == 2'd1 ? 4'he : map_v == 2'd2 ? 4'hf : 4'hc;
wire [3:0] ata_hi  = map_v == 2'd1 ? 4'hd : map_v == 2'd2 ? 4'hc : 4'hf;
wire r_vram  = ub[23:20] == vram_hi && ub[19:13] == 7'd0;
wire r_ata0  = ub[23:4] == { ata_hi, 16'h0000 };
wire r_ata1  = ub[23:4] == { ata_hi, 16'h4000 };

// ---- work RAM, 64 KB
wire        wram_we = take && !iack && uwe && r_wram;
wire [ 7:0] wr_qh, wr_ql;
gx_tdpram #(.AW(15), .DW(8)) u_wrh ( .clk, .we_a(wram_we && ube[1]), .a(ua[15:1]), .d(ud[15:8]), .qa(wr_qh), .b(15'd0), .qb() );
gx_tdpram #(.AW(15), .DW(8)) u_wrl ( .clk, .we_a(wram_we && ube[0]), .a(ua[15:1]), .d(ud[ 7:0]), .qa(wr_ql), .b(15'd0), .qb() );

// ---- sprite RAM, 0x801000: 512 dwords as four byte lanes (lane 3 = bits 31-24)
wire        obj_we = take && !iack && uwe && r_obj;
wire [ 7:0] ob_qa [4];
wire [ 7:0] ob_qb [4];
genvar ol;
generate for (ol = 0; ol < 4; ol++) begin : g_obj
    // lanes 3, 2: the dword's upper word (ua[1] = 0); 1, 0 the lower
    wire lw = (ol >= 2) ? !ua[1] : ua[1];
    wire bw = (ol % 2) ? ube[1] : ube[0];
    gx_tdpram #(.AW(9), .DW(8)) u_ob (
        .clk, .we_a(obj_we && lw && bw), .a(ua[10:2]), .d((ol % 2) ? ud[15:8] : ud[7:0]), .qa(ob_qa[ol]),
        .b(or_addr), .qb(ob_qb[ol])
    );
end endgenerate
assign or_q = { ob_qb[3], ob_qb[2], ob_qb[1], ob_qb[0] };

// ---- palette (in dj_video): the dword's index
assign pal_addr = 13'((ub - 24'h480000) >> 2);

// ---- VRAM window (k056832 ram_word_r/w): the page register 0x19
wire [15:0] r19     = tm_regs[25];
wire [ 3:0] vpage   = { r19[4:3], r19[1:0] };
wire        ext_ls  = tm_regs[0][1];            // the extra page: not kept
assign vram_addr = { vpage, ua[12:1] };
assign vram_rd   = take && !iack && !uwe && r_vram;

// ---- the ROM cache
reg         cr_cs;
wire        cr_ok;
wire [15:0] cr_data;
wire [19:0] cr_paddr;
gx_romcache u_cache (
    .clk, .rst,
    .a_pre(ua[22:1]), .cs(cr_cs), .addr(ua_r[22:1]), .ok(cr_ok), .data(cr_data),
    .p_cs(rom_cs), .p_addr(cr_paddr), .p_ok(rom_ok), .p_data(rom_data),
    .dbg_hits(), .dbg_misses(), .dbg_addr(), .dbg_data(), .peek_t(1'b0), .peek_addr(20'd0)
);
assign rom_addr = cr_paddr[16:0];

// ---- the SDRAM byte a data read is after
// sound DRAM: 0x1000000 + bank * 0x80000 + offset
wire [26:0] snd_byte  = 27'h100_0000 + { 3'd0, snd_bank, ub[18:0] };
// tile ROM readback (v_rom_r): bank * 0x2000 + (v_ctrl bit 5 ? 0x1000) + 2 * dword (+1 unless bits 31-24)
wire [20:0] vr_off    = { tm_regs[26][7:0], 13'd0 } + (v_ctrl[5] ? 21'h1000 : 21'h0) + { 9'd0, ub[12:2], 1'b0 } + { 20'd0, !ube_r[1] };
wire [26:0] vr_byte   = 27'h030_0000 + { 6'd0, vr_off };
// sprite ROM readback (obj_rom_r): ((bank * 0x200 + dword) * 4) + (bits 15-0 ? 2) + (a high byte ? 1),
// then the load's re-ordering of the tile (dj_sdram_top)
wire [20:0] or_off    = { obj_regs[20][9:0], 11'd0 } + { 10'd0, ub[10:2], 2'b00 } + { 19'd0, ua_r[1], ube_r[1] };
wire [26:0] or_byte   = 27'h010_0000 + { 6'd0, or_off[20:7], or_off[6], or_off[4:2], or_off[5], or_off[1:0] };
reg  [26:0] cd_byte;
reg  [ 1:0] cd_kind;                         // 0 sound DRAM word, 1 tile byte, 2 sprite byte
function [15:0] gr_word( input [63:0] gr, input [2:0] b );
    gr_word = { gr[8*b +: 8], gr[8*(b+1) +: 8] };
endfunction

// ---- the IDE handshake
reg  [1:0] a_ack_s = 2'b00;
always @(posedge clk) a_ack_s <= { a_ack_s[0], a_ack_t };
wire a_done = a_ack_s[1] == a_req_t;

// ---- register reads
reg  [15:0] reg_q;
always @* begin
    reg_q = 16'h0000;
    if (r_k32)  reg_q = tm_regs[ua[5:1]];
    if (r_objc) reg_q = obj_regs[7'(ua[7:1])];
    if (r_in) begin
        case ({ ub[15], ub[1] })
            2'b00: reg_q = { in_dsw3, in_btn3 };
            2'b01: reg_q = { in_btn2, in_btn1 };
            2'b10: reg_q = { in_dsw1, in_dsw2 };
            default: reg_q = 16'hffff;
        endcase
    end
    if (r_tt && ub[1]) reg_q = { tt_sel ? tt_pos1[15:8] : tt_pos0[15:8], 8'h00 };
end

reg ata_irq_s1, ata_irq_s2, ata_irq_d;

always @(posedge clk) begin
    u_ack     <= 1'b0;
    tm_reg_we <= 1'b0;
    vram_we   <= 1'b0;
    k55_we    <= 1'b0;
    pal_we    <= 1'b0;
    cw_req    <= 1'b0;

    // interrupts
    ata_irq_s1 <= ata_intrq; ata_irq_s2 <= ata_irq_s1; ata_irq_d <= ata_irq_s2;
    if (ata_irq_s2 && !ata_irq_d) irq1 <= 1'b1;
    if (!ata_irq_s2) irq1 <= 1'b0;
    if (vblank_irq) begin
        if (v_ctrl[15]) begin irq4 <= 1'b1; vb_pend <= 1'b0; end
        else vb_pend <= 1'b1;
    end
    ipl_n <= irq4 ? ~3'd4 : irq1 ? ~3'd1 : 3'b111;

    if (rst) begin
        ust <= U_IDLE; cr_cs <= 1'b0; cd_cs <= 1'b0; snd_cs0 <= 1'b0; snd_cs1 <= 1'b0;
        v_ctrl <= 16'd0; vb_pend <= 1'b0; irq4 <= 1'b0; irq1 <= 1'b0; snd_bank <= 5'd0; tt_sel <= 1'b0;
    end else case (ust)
    U_IDLE: if (take) begin
        ua_r <= a32[23:1]; ube_r <= { ~nUDS, ~nLDS }; uwe_r <= busstate == 2'b11; ud_r <= cpu_dout;
        if (iack) begin
            // the acknowledge: clear the level being taken (HOLD_LINE)
            if (a32[3:1] == 3'd4) irq4 <= 1'b0;
            if (a32[3:1] == 3'd1) irq1 <= 1'b0;
            u_din <= 16'hffff; ust <= U_ACK;
        end else if (r_rom) begin
            if (uwe) ust <= U_ACK; else begin cr_cs <= 1'b1; ust <= U_ROM; end
        end else if (r_wram) begin usrc <= S_WRAM; ust <= U_RAM; end
        else if (r_obj) begin usrc <= S_OBJ; ust <= U_RAM; end
        else if (r_pal) begin
            usrc <= S_PAL; ust <= U_RAM;
            if (uwe) begin
                // xBGR_888: the upper word is x (not kept) and B, the lower G and R
                pal_we  <= 1'b1;
                pal_be  <= ua[1] ? { 1'b0, ube[1], ube[0] } : { ube[0], 2'b00 };
                pal_din <= ua[1] ? { 8'd0, ud } : { ud[7:0], 16'd0 };
            end
        end
        else if (r_vram) begin
            if (uwe) begin
                vram_we  <= !ext_ls; vram_din <= ud; vram_be <= ube;
                ust <= U_ACK;
            end else ust <= U_VR1;
        end
        else if (r_snd || ((r_vrom || r_orom) && !uwe)) begin
            cd_kind <= r_snd ? 2'd0 : r_vrom ? 2'd1 : 2'd2;
            ust     <= r_snd && uwe ? U_CW : U_CDW;
        end
        else if (r_539) begin
            snd_cs0 <= ube[1]; snd_cs1 <= ube[0]; snd_we <= uwe;
            snd_addr <= 11'(ub[10:1]); snd_din <= ud;
            ust <= U_SND;
        end
        else if (r_ata0 || r_ata1) begin
            a_cs1 <= r_ata1; a_reg <= ua[3:1]; a_we <= uwe; a_wdata <= ud;
            a_req_t <= ~a_req_t;
            ust <= U_ATA;
        end
        else begin
            // registers and write-only ports
            if (uwe) begin
                if (r_k32) begin
                    tm_reg_we <= 1'b1; tm_reg_addr <= ua[5:1]; tm_reg_din <= ud; tm_reg_be <= ube;
                end
                if (r_k55 && ube[1]) begin
                    // K055555_long_w: reg 2n from bits 31-24, 2n+1 from bits 15-8
                    k55_we <= 1'b1; k55_addr <= 6'(ua[6:1]); k55_din <= ud[15:8];
                end
                if (r_lt1) begin
                    if (ube[1]) lamps1[15:8] <= ud[15:8];
                    if (ube[0]) lamps1[ 7:0] <= ud[ 7:0];
                end
                if (r_lt2) begin
                    if (ube[1]) lamps2[15:8] <= ud[15:8];
                    if (ube[0]) lamps2[ 7:0] <= ud[ 7:0];
                end
                if (r_vctl) begin
                    if (ube[1]) v_ctrl[15:8] <= ud[15:8];
                    if (ube[0]) v_ctrl[ 7:0] <= ud[ 7:0];
                    // v_ctrl_w: a vblank that came while disabled is delivered now
                    if ((ube[1] ? ud[15] : v_ctrl[15]) && vb_pend) begin irq4 <= 1'b1; vb_pend <= 1'b0; end
                end
                if (r_pcb) begin
                    if (ube[1]) pcb_leds <= ud[15:8];
                    if (ube[0]) snd_bank <= ud[4:0];
                end
                if (r_tt && !ub[1] && ube[0]) tt_sel <= ud[3];   // turntable_select_w: bit 19
                if (r_objc) begin
                    if (ube[1]) obj_regs[7'(ua[7:1])][15:8] <= ud[15:8];
                    if (ube[0]) obj_regs[7'(ua[7:1])][ 7:0] <= ud[ 7:0];
                end
                ust <= U_ACK;
            end else ust <= U_REG;
        end
    end
    // internal RAMs: the data is out of the RAM a clock after the address
    U_RAM: begin
        u_din <= usrc == S_WRAM ? { wr_qh, wr_ql } :
                 usrc == S_OBJ  ? (ua_r[1] ? { ob_qa[1], ob_qa[0] } : { ob_qa[3], ob_qa[2] }) :
                 ua_r[1] ? pal_dout[15:0] : { 8'h00, pal_dout[23:16] };
        u_ack <= 1'b1; ust <= U_IDLE;
    end
    U_REG: begin u_din <= reg_q; u_ack <= 1'b1; ust <= U_IDLE; end
    U_VR1: ust <= U_VR2;
    U_VR2: begin u_din <= ext_ls ? 16'h0000 : vram_dout; u_ack <= 1'b1; ust <= U_IDLE; end
    U_ROM: if (cr_ok) begin cr_cs <= 1'b0; u_din <= cr_data; u_ack <= 1'b1; ust <= U_IDLE; end
    // an SDRAM data read, once the CPU's last write has landed
    U_CDW: if (!cw_busy) begin
        cd_byte <= cd_kind == 2'd0 ? snd_byte : cd_kind == 2'd1 ? vr_byte : or_byte;
        cd_addr <= cd_kind == 2'd0 ? snd_byte[26:3] : cd_kind == 2'd1 ? vr_byte[26:3] : or_byte[26:3];
        cd_cs   <= 1'b1;
        ust     <= U_CD;
    end
    U_CD: if (cd_ok) begin
        cd_cs <= 1'b0;
        case (cd_kind)
            2'd0: u_din <= gr_word(cd_data, { cd_byte[2:1], 1'b0 });
            // the tile byte in bits 31-24 and 23-16 of the dword: the upper word; the lower reads 0
            2'd1: u_din <= ua_r[1] ? 16'h0000 : {2{cd_data[8*cd_byte[2:0] +: 8]}};
            default: u_din <= {2{cd_data[8*cd_byte[2:0] +: 8]}};
        endcase
        u_ack <= 1'b1; ust <= U_IDLE;
    end
    // a sound DRAM write, posted: answered as soon as the port takes it
    U_CW: if (!cw_busy) begin
        cw_req  <= 1'b1;
        cw_addr <= snd_byte;
        cw_data <= { ud_r[7:0], ud_r[15:8] };       // the even byte in the low lane
        cw_be   <= { ube_r[0], ube_r[1] };
        u_ack   <= 1'b1; ust <= U_IDLE;
    end
    U_SND: if (snd_ack) begin
        snd_cs0 <= 1'b0; snd_cs1 <= 1'b0;
        u_din   <= snd_dout; u_ack <= 1'b1; ust <= U_IDLE;
    end
    U_ATA: if (a_done) begin u_din <= a_rdata; u_ack <= 1'b1; ust <= U_IDLE; end
    U_ACK: begin u_ack <= 1'b1; ust <= U_IDLE; end
    default: ust <= U_IDLE;
    endcase
end

// ------------------------------------------------------------ the CPU side
assign fast_rdy = cst == C_BUSY && u_ack;

always @(posedge clk) begin
    if (rst) begin
        cst <= C_IDLE; ready <= 1'b0;
    end else case (cst)
        C_IDLE: if (take) cst <= C_BUSY;
        C_BUSY: if (u_ack) begin
            cpu_din <= u_din;
            if (cpu_take) cst <= C_IDLE;        // taken this clock (fast_rdy)
            else begin ready <= 1'b1; cst <= C_READY; end
        end
        // held until a clk cycle that ends at a kernel edge the kernel is enabled on
        C_READY: if (cpu_take) begin ready <= 1'b0; cst <= C_IDLE; end
        default: cst <= C_IDLE;
    endcase
end

endmodule
