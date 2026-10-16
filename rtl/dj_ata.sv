// SPDX-License-Identifier: GPL-3.0-or-later
//
// The DJ Main's IDE hard disk: an ATA PIO device on MiSTer's SD block
// interface (hps_io sd_*, the image mounted from the OSD as a raw .hdd).
//
// Written from the ATA-1/ATA-3 register model and what MAME's ata_hle /
// ide_hdd do, sized to what the games use. Measured on bm1stmix in MAME
// (scripts/mame/ata_trace.lua, docs/RESEARCH.md section 8): a soft reset,
// SET FEATURES twice, SET MULTIPLE 16, then READ MULTIPLE in LBA mode, all
// polled. Implemented beyond that, for the later games and for safety:
// IDENTIFY, READ/WRITE SECTORS, WRITE MULTIPLE, VERIFY, and the no-data
// commands (INITIALIZE DEVICE PARAMETERS, RECALIBRATE, SEEK, IDLE/STANDBY,
// FLUSH, NOP-like) answered as done. Anything else aborts (ERR, ABRT).
// Not here yet: the security feature set (later games' passwords).
//
// Registers, as the board maps them (cs0 at 0xf00000 + 2n, cs1 at
// 0xf40000 + 2n, 16-bit, value in bits 7-0; the data register 16 bits):
//   cs0 0 data   1 error/features   2 sector count   3 sector/LBA 7-0
//       4 cyl lo/LBA 15-8   5 cyl hi/LBA 23-16   6 device/head   7 status/command
//   cs1 6 alternate status / device control (bit 1 nIEN, bit 2 SRST)
//
// Data words are sector[2i] | sector[2i+1] << 8, as MAME's ATA gives them.
//
// Transfers go to and from the image in blocks: one sector for READ/WRITE
// SECTORS, the multiple count for the MULTIPLE commands (at most 16, the
// 8 KB sector buffer). INTRQ is raised at each block's DRQ (reads), after
// each block (writes) and at the end of a no-data command, and cleared by
// a read of the status register, as the standard says.
//
// Everything here runs on clk_sys (hps_io's clock). The CPU's accesses come
// from the 48 MHz board through a toggle handshake (a_req_t / a_ack_t); the
// answer changes only on the clk_sys edge midway between two clk edges, as
// gx_rom_port's does.

module dj_ata (
    input             clk_sys,
    input             clk,              // the board's 48 MHz, for the midway edge
    input             rst,

    // the CPU (clk side: held while a_req_t != a_ack_t)
    input             a_req_t,
    input             a_cs1,
    input       [2:0] a_reg,
    input             a_we,
    input      [15:0] a_wdata,
    output reg        a_ack_t = 1'b0,
    output reg [15:0] a_rdata,
    output            intrq,
    output            active,           // a transfer is going on (the disk LED)

    // the set's disk (the .mra's configuration): its geometry, 0 = 16 heads
    // and 63 sectors; which ATA passwords lock it; and the passwords, master
    // at 0-31, user at 32-63, written a byte at a time
    input       [7:0] cfg_heads,
    input       [7:0] cfg_spt,
    input             cfg_lock_m,
    input             cfg_lock_u,
    input             pw_we,
    input       [5:0] pw_a,
    input       [7:0] pw_d,

    // hps_io: the image
    input             img_mounted,
    input             img_readonly,
    input      [63:0] img_size,
    output reg [31:0] sd_lba,
    output reg  [5:0] sd_blk_cnt,
    output reg        sd_rd,
    output reg        sd_wr,
    input             sd_ack,
    input      [13:0] sd_buff_addr,
    input       [7:0] sd_buff_dout,
    output      [7:0] sd_buff_din,
    input             sd_buff_wr
);

// the geometry: MAME's CHD metadata for the set, carried by the .mra
wire [7:0] HEADS = cfg_heads != 8'd0 ? cfg_heads : 8'd16;
wire [7:0] SPT   = cfg_spt   != 8'd0 ? cfg_spt   : 8'd63;
reg [15:0] hs;                   // heads * sectors, a cylinder
always @(posedge clk_sys) hs <= HEADS * SPT;

// ATA security, as MAME's ata mass storage: a drive with a master and/or user
// password starts locked and refuses reads (ERR, ABRT) until SECURITY UNLOCK
// (0xF2) is given each enabled one. The unlock's 512-byte block: byte 0 bit 0
// says which (1 master), bytes 2-33 the password. The games read once while
// locked and expect it to fail (scripts/mame/ata_trace.lua).
reg  [7:0] pw [0:63];
always @(posedge clk_sys) if (pw_we) pw[pw_a] <= pw_d;
reg        lock_m = 1'b0, lock_u = 1'b0;
wire       locked = lock_m || lock_u;
reg  [4:0] pw_k = 5'd0;          // the word of the unlock block being checked
reg        pw_master, pw_ok;

// ------------------------------------------------------------ the image
reg        present = 1'b0, ro = 1'b0;
reg [31:0] total;                // sectors
reg [15:0] cyls;                 // total / (heads * sectors), for IDENTIFY
reg [31:0] div_r;
reg        div_busy = 1'b0;

// ------------------------------------------------------------ sector buffer
// 8 KB as two byte lanes of 4K: even bytes and odd bytes of each word
reg  [12:0] w_ptr;               // the data register's word (4096 = a full 16-sector block)
wire [11:0] hb_w = sd_buff_addr[12:1];
reg  [7:0]  lane_e [0:4095];
reg  [7:0]  lane_o [0:4095];
reg  [7:0]  qe, qo;              // the CPU's word
reg  [7:0]  qh;                  // hps's byte
reg         cpu_bwe;
reg  [15:0] cpu_bw;
reg  [11:0] cpu_bwa;
always @(posedge clk_sys) begin
    if (sd_buff_wr && sd_ack) begin
        if (sd_buff_addr[0]) lane_o[hb_w] <= sd_buff_dout;
        else                 lane_e[hb_w] <= sd_buff_dout;
    end else if (cpu_bwe) begin
        lane_e[cpu_bwa] <= cpu_bw[7:0];
        lane_o[cpu_bwa] <= cpu_bw[15:8];
    end
    qe <= lane_e[w_ptr[11:0]];
    qo <= lane_o[w_ptr[11:0]];
end
always @(posedge clk_sys) qh <= sd_buff_addr[0] ? lane_o[hb_w] : lane_e[hb_w];
assign sd_buff_din = qh;

// ------------------------------------------------------------ registers
reg [7:0] feat, nsect, sect, lcyl, hcyl, devh, err;
reg       bsy, drdy, drq, errb, dsc;
reg       nien = 1'b0, srst = 1'b0;
reg       irq  = 1'b0;
reg [7:0] cmd;
reg [4:0] mult = 5'd0;           // the READ/WRITE MULTIPLE block, 0 = not set
reg [8:0] remain;                // sectors still to move
reg [4:0] blk;                   // sectors in this block
reg [12:0] words;                // words in this block
reg       ident, writing;

wire [7:0] status = { bsy, drdy && !bsy, 1'b0, dsc, drq, 1'b0, 1'b0, errb };
assign intrq  = irq && !nien;
assign active = bsy || drq;

wire        lba_mode = devh[6];
wire [27:0] lba_reg  = { devh[3:0], hcyl, lcyl, sect };
// CHS to LBA: (cyl * heads + head) * sectors + sector - 1, registered in two
// steps (the registers are written long before the command that uses them)
wire [15:0] chs_cyl  = { hcyl, lcyl };
reg  [23:0] chs_ch;
reg  [27:0] chs_lba;
always @(posedge clk_sys) begin
    chs_ch  <= chs_cyl * HEADS + 24'(devh[3:0]);
    chs_lba <= 28'(chs_ch * SPT) + 28'(sect) - 28'd1;
end
reg  [27:0] cur;                 // the next sector to move

// the registers after a block: the address of the last sector moved
task automatic set_addr( input [27:0] a );
    if (lba_mode) begin
        sect <= a[7:0]; lcyl <= a[15:8]; hcyl <= a[23:16]; devh[3:0] <= a[27:24];
    end
endtask

// IDENTIFY DEVICE: generated a word at a time
function automatic [15:0] ascii2( input [7:0] a, input [7:0] b ); ascii2 = { a, b }; endfunction
function automatic [15:0] ident_w( input [7:0] w );
    case (w)
        8'd0:  ident_w = 16'h0040;                 // fixed disk
        8'd1:  ident_w = cyls;
        8'd3:  ident_w = 16'(HEADS);
        8'd4:  ident_w = 16'(SPT) * 16'd512;
        8'd5:  ident_w = 16'd512;
        8'd6:  ident_w = 16'(SPT);
        8'd10: ident_w = ascii2("D","J");          // serial
        8'd11: ident_w = ascii2("M","A");
        8'd12: ident_w = ascii2("I","N");
        8'd13, 8'd14, 8'd15, 8'd16, 8'd17, 8'd18, 8'd19: ident_w = 16'h2020;
        8'd20: ident_w = 16'd3;                    // buffer type
        8'd21: ident_w = 16'd16;                   // buffer size (sectors)
        8'd23: ident_w = ascii2("1","."); 8'd24: ident_w = ascii2("0","0");
        8'd25, 8'd26: ident_w = 16'h2020;
        8'd27: ident_w = ascii2("M","i"); 8'd28: ident_w = ascii2("S","T");
        8'd29: ident_w = ascii2("e","r"); 8'd30: ident_w = ascii2(" ","D");
        8'd31: ident_w = ascii2("J"," "); 8'd32: ident_w = ascii2("M","a");
        8'd33: ident_w = ascii2("i","n"); 8'd34: ident_w = ascii2(" ","H");
        8'd35: ident_w = ascii2("D","D");
        8'd36, 8'd37, 8'd38, 8'd39, 8'd40, 8'd41, 8'd42, 8'd43, 8'd44, 8'd45, 8'd46: ident_w = 16'h2020;
        8'd47: ident_w = 16'h8010;                 // READ/WRITE MULTIPLE: 16
        8'd49: ident_w = 16'h0200;                 // LBA
        8'd51: ident_w = 16'h0200;
        8'd53: ident_w = 16'h0001;
        8'd54: ident_w = cyls;
        8'd55: ident_w = 16'(HEADS);
        8'd56: ident_w = 16'(SPT);
        8'd57: ident_w = total[15:0];
        8'd58: ident_w = total[31:16];
        8'd59: ident_w = mult != 0 ? { 8'h01, 3'd0, mult } : 16'h0000;
        8'd60: ident_w = total[15:0];
        8'd61: ident_w = total[31:16];
        default: ident_w = 16'h0000;
    endcase
endfunction

// ------------------------------------------------------------ the CPU side
reg  a_req_s = 1'b0;
reg  tv = 1'b0, tv_m = 1'b0;
always @(posedge clk)     tv   <= ~tv;
always @(posedge clk_sys) tv_m <= tv;
wire midway = tv != tv_m;
reg  a_pend = 1'b0;              // an access answered, waiting for the midway edge

typedef enum logic [3:0] { S_IDLE, S_RDREQ, S_RDACK, S_RDEND, S_DRQ, S_WRREQ, S_WRACK, S_WREND, S_NODATA, S_SRST,
                           S_PWREQ, S_PWA, S_PWB, S_PWC } st_t;
st_t st;
reg [7:0]  delay;
reg        sd_ack_d;

always @(posedge clk_sys) begin
    a_req_s  <= a_req_t;
    sd_ack_d <= sd_ack;
    cpu_bwe  <= 1'b0;

    // the image
    if (img_mounted) begin
        present  <= img_size != 0;
        ro       <= img_readonly;
        total    <= img_size[40:9];
        div_r    <= img_size[40:9];
        cyls     <= 16'd0;
        div_busy <= 1'b1;
        lock_m   <= cfg_lock_m;
        lock_u   <= cfg_lock_u;
    end else if (div_busy) begin
        // total / (heads * sectors) by counting cylinders: a mount is rare
        if (div_r >= 32'(hs)) begin div_r <= div_r - 32'(hs); cyls <= cyls + 16'd1; end
        else div_busy <= 1'b0;
    end

    // the answer to the CPU, on a midway edge
    if (a_pend && midway) begin a_ack_t <= ~a_ack_t; a_pend <= 1'b0; end

    if (rst) begin
        st <= S_IDLE; bsy <= 1'b0; drdy <= 1'b1; drq <= 1'b0; errb <= 1'b0; dsc <= 1'b1;
        err <= 8'h01; nsect <= 8'd1; sect <= 8'd1; lcyl <= 8'd0; hcyl <= 8'd0; devh <= 8'h00;
        irq <= 1'b0; nien <= 1'b0; srst <= 1'b0; mult <= 5'd0;
        sd_rd <= 1'b0; sd_wr <= 1'b0; a_pend <= 1'b0;
        lock_m <= cfg_lock_m; lock_u <= cfg_lock_u;
    end else begin
        // ---- a CPU access, when one is waiting and the last is answered
        if (a_req_s != a_ack_t && !a_pend) begin
            a_pend <= 1'b1;
            a_rdata <= 16'h0000;
            if (a_cs1) begin
                if (a_reg == 3'd6) begin
                    if (a_we) begin
                        nien <= a_wdata[1];
                        srst <= a_wdata[2];
                        if (srst && !a_wdata[2]) begin
                            // the end of a soft reset: signature, ready
                            st <= S_SRST; bsy <= 1'b1; drq <= 1'b0; delay <= 8'd200;
                        end else if (a_wdata[2]) begin
                            bsy <= 1'b1; drq <= 1'b0; sd_rd <= 1'b0; sd_wr <= 1'b0; st <= S_IDLE;
                        end
                    end else a_rdata <= { 8'd0, status };
                end else if (a_reg == 3'd7 && !a_we) a_rdata <= { 8'd0, 1'b0, ~devh[3:0], 2'b10 };
            end else case (a_reg)
                3'd0: begin
                    if (a_we) begin
                        if (drq && writing) begin
                            cpu_bwe <= 1'b1; cpu_bw <= a_wdata; cpu_bwa <= w_ptr[11:0];
                        end
                    end else if (drq && !writing)
                        a_rdata <= ident ? ident_w(w_ptr[7:0]) : { qo, qe };
                    if (drq) w_ptr <= w_ptr + 13'd1;
                end
                3'd1: if (a_we) feat <= a_wdata[7:0]; else a_rdata <= { 8'd0, err };
                3'd2: if (a_we) nsect <= a_wdata[7:0]; else a_rdata <= { 8'd0, nsect };
                3'd3: if (a_we) sect  <= a_wdata[7:0]; else a_rdata <= { 8'd0, sect };
                3'd4: if (a_we) lcyl  <= a_wdata[7:0]; else a_rdata <= { 8'd0, lcyl };
                3'd5: if (a_we) hcyl  <= a_wdata[7:0]; else a_rdata <= { 8'd0, hcyl };
                3'd6: if (a_we) devh  <= a_wdata[7:0]; else a_rdata <= { 8'd0, devh };
                3'd7: if (!a_we) begin
                    a_rdata <= { 8'd0, present ? status : 8'h00 };
                    irq     <= 1'b0;
                end else if (!bsy && present && !devh[4]) begin
                    // a command
                    cmd   <= a_wdata[7:0];
                    errb  <= 1'b0; err <= 8'h00;
                    irq   <= 1'b0;
                    ident <= 1'b0; writing <= 1'b0;
                    cur   <= lba_mode ? lba_reg : chs_lba;
                    remain <= nsect == 8'd0 ? 9'd256 : { 1'b0, nsect };
                    casez (a_wdata[7:0])
                        8'h20, 8'h21, 8'hc4: begin                 // READ SECTORS / MULTIPLE
                            if ((a_wdata[7:0] == 8'hc4 && mult == 5'd0) || locked) begin
                                errb <= 1'b1; err <= 8'h04; irq <= 1'b1;
                            end else begin
                                bsy <= 1'b1; st <= S_RDREQ;
                            end
                        end
                        8'h30, 8'h31, 8'hc5: begin                 // WRITE SECTORS / MULTIPLE
                            if ((a_wdata[7:0] == 8'hc5 && mult == 5'd0) || ro) begin
                                errb <= 1'b1; err <= 8'h04; irq <= 1'b1;
                            end else begin
                                writing <= 1'b1;
                                blk     <= a_wdata[7:0] == 8'hc5 ? mult : 5'd1;
                                st      <= S_WRREQ;    // first: the host's block (below)
                                bsy     <= 1'b0; drq <= 1'b1; w_ptr <= 13'd0;
                            end
                        end
                        8'hf2, 8'hf6: begin                        // SECURITY UNLOCK / DISABLE PASSWORD
                            // the host's block, then (unlock) the check
                            writing <= 1'b1; blk <= 5'd1;
                            st      <= S_PWREQ;
                            bsy     <= 1'b0; drq <= 1'b1; w_ptr <= 13'd0; irq <= 1'b1;
                        end
                        8'hec: begin                               // IDENTIFY DEVICE
                            ident <= 1'b1; drq <= 1'b1; w_ptr <= 13'd0; words <= 13'd256;
                            irq <= 1'b1; st <= S_DRQ;
                        end
                        8'hc6: begin                               // SET MULTIPLE
                            if (nsect == 8'd0 || nsect > 8'd16 || (nsect & (nsect - 8'd1)) != 8'd0) begin
                                errb <= 1'b1; err <= 8'h04;
                            end else mult <= nsect[4:0];
                            irq <= 1'b1;
                        end
                        8'h40, 8'h41, 8'h91, 8'h1?, 8'h7?, 8'hef, 8'he0, 8'he1, 8'he2, 8'he3,
                        8'he5, 8'he6, 8'he7, 8'hea, 8'h00, 8'h08, 8'h90: begin
                            // done at once (VERIFY, INIT PARAMS, RECALIBRATE, SEEK,
                            // SET FEATURES, power, FLUSH, NOP, DEVICE RESET, DIAGNOSTIC)
                            bsy <= 1'b1; st <= S_NODATA; delay <= 8'd20;
                            if (a_wdata[7:0] == 8'h90) err <= 8'h01;
                        end
                        default: begin
                            errb <= 1'b1; err <= 8'h04; irq <= 1'b1;
                        end
                    endcase
                end
                default: ;
            endcase
        end

        // ---- the transfer engine
        case (st)
        S_IDLE: ;
        S_SRST: if (delay != 0) delay <= delay - 8'd1; else begin
            bsy <= 1'b0; drdy <= 1'b1; dsc <= 1'b1; errb <= 1'b0; err <= 8'h01;
            nsect <= 8'd1; sect <= 8'd1; lcyl <= 8'd0; hcyl <= 8'd0; devh <= 8'h00;
            st <= S_IDLE;
        end
        S_NODATA: if (delay != 0) delay <= delay - 8'd1; else begin
            bsy <= 1'b0; irq <= 1'b1; st <= S_IDLE;
        end
        // reads: a block from the image, then DRQ for the host
        S_RDREQ: begin
            blk    <= cmd == 8'hc4 ? (remain < 9'(mult) ? remain[4:0] : mult) : 5'd1;
            sd_lba <= 32'(cur);
            sd_blk_cnt <= 6'((cmd == 8'hc4 ? (remain < 9'(mult) ? remain[4:0] : mult) : 5'd1) - 5'd1);
            if (cur >= total) begin
                errb <= 1'b1; err <= 8'h10; bsy <= 1'b0; irq <= 1'b1; st <= S_IDLE;   // IDNF
            end else begin
                sd_rd <= 1'b1; st <= S_RDACK;
            end
        end
        S_RDACK: if (sd_ack) begin sd_rd <= 1'b0; st <= S_RDEND; end
        S_RDEND: if (!sd_ack && sd_ack_d) begin
            bsy <= 1'b0; drq <= 1'b1; irq <= 1'b1;
            w_ptr <= 13'd0; words <= { blk, 8'd0 };
            st <= S_DRQ;
        end
        default: ;
        endcase

        // the host has read a whole block
        if (st == S_DRQ && !writing && drq && w_ptr == words && words != 13'd0) begin
            drq <= 1'b0;
            if (ident) begin
                st <= S_IDLE;
            end else begin
                set_addr(cur + 28'(blk) - 28'd1);
                cur    <= cur + 28'(blk);
                remain <= remain - 9'(blk);
                if (remain == 9'(blk)) st <= S_IDLE;
                else begin bsy <= 1'b1; st <= S_RDREQ; end
            end
        end

        // writes: the host fills a block, then it goes to the image
        if (st == S_WRREQ && drq && w_ptr == { blk, 8'd0 }) begin
            drq <= 1'b0; bsy <= 1'b1;
            sd_lba <= 32'(cur);
            sd_blk_cnt <= 6'(blk - 5'd1);
            if (cur >= total) begin
                errb <= 1'b1; err <= 8'h10; bsy <= 1'b0; irq <= 1'b1; st <= S_IDLE;
            end else begin
                sd_wr <= 1'b1; st <= S_WRACK;
            end
        end
        if (st == S_WRACK && sd_ack) begin sd_wr <= 1'b0; st <= S_WREND; end

        // SECURITY UNLOCK: the block is in; check it a word at a time (the
        // buffer reads a word two clocks after w_ptr): word 0 says master or
        // user, words 1-16 are the password, sector[2i] | sector[2i+1] << 8
        if (st == S_PWREQ && drq && w_ptr == 13'd256) begin
            drq <= 1'b0; bsy <= 1'b1;
            if (cmd == 8'hf6) begin bsy <= 1'b0; irq <= 1'b1; st <= S_IDLE; end
            else begin w_ptr <= 13'd0; pw_k <= 5'd0; pw_ok <= 1'b1; st <= S_PWA; end
        end
        if (st == S_PWA) st <= S_PWB;
        if (st == S_PWB) st <= S_PWC;
        if (st == S_PWC) begin
            if (pw_k == 5'd0) pw_master <= qe[0];
            else if ({ qo, qe } != { pw[{ !pw_master, 5'(2 * (pw_k - 5'd1) + 1) }], pw[{ !pw_master, 5'(2 * (pw_k - 5'd1)) }] })
                pw_ok <= 1'b0;
            if (pw_k == 5'd16) begin
                // the last word's check is pw_ok's last update: decide next clock
                st <= S_IDLE;
                pw_k <= 5'd17;
            end else begin
                pw_k  <= pw_k + 5'd1;
                w_ptr <= 13'(pw_k + 5'd1);
                st    <= S_PWA;
            end
        end
        if (st == S_IDLE && pw_k == 5'd17) begin
            pw_k <= 5'd0;
            if (pw_ok) begin
                if (pw_master) lock_m <= 1'b0; else lock_u <= 1'b0;
            end
            if (!pw_ok || (pw_master ? lock_u : lock_m)) begin errb <= 1'b1; err <= 8'h04; end
            bsy <= 1'b0; irq <= 1'b1;
        end
        if (st == S_WREND && !sd_ack && sd_ack_d) begin
            set_addr(cur + 28'(blk) - 28'd1);
            cur    <= cur + 28'(blk);
            remain <= remain - 9'(blk);
            irq    <= 1'b1;
            if (remain == 9'(blk)) begin bsy <= 1'b0; st <= S_IDLE; end
            else begin
                bsy <= 1'b0; drq <= 1'b1; w_ptr <= 13'd0;
                blk <= cmd == 8'hc5 ? ((remain - 9'(blk)) < 9'(mult) ? 5'(remain - 9'(blk)) : mult) : 5'd1;
                st  <= S_WRREQ;
            end
        end
    end
end

endmodule
