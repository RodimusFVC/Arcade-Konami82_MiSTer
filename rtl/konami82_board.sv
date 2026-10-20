//============================================================================
//
//  Konami82 — board top
//  Copyright (C) 2026 Rodimus
//
//  Variant 0: Time Pilot board (MAME timeplt.cpp: timeplt, timepltc, timeplta, spaceplt, spaceplta)
//  Variant 3/4/5: Time Pilot board as Power Surge / Bikkuri Card / Chance Kun (timeplt.cpp)
//  Variant 6: Tutankham board (MAME tutankhm.cpp: tutankhm, tutankhms, tutankhmb)
//  Variant 7: Tutankham board as Juno First (MAME junofrst.cpp: junofrst, junofrstg), own sound board
//  Variant 8: Gyruss board (MAME gyruss.cpp: gyruss, gyrussce, gyrussb, venus), own stereo sound board
//  Variant 1: Pooyan board (MAME pooyan.cpp: pooyan, pooyans, pootan)
//  Variant 2: Roc'n Rope board (MAME rocnrope.cpp: rocnrope, rocnropek, ropeman)
//  Variant 9: Circus Charlie board (MAME circusc.cpp: circusc, circusc2-4, circuscc, circusce), own sound board
//  Variant 10/11: Time Pilot '84 board (MAME tp84.cpp: tp84, tp84a / tp84b), own sound board
//  All but Juno First use the Time Pilot sound board, instanced once here.
//  The board not selected is held in reset. A board's watchdog resets its own CPUs (pool reset_n) and, where the
//  schematic routes it there (conn 21), the sound board.
//  ROMs: one banked store (below) holds every ROM image; each board reads it through the same window addresses
//  its header lists (rom0-rom3 and second ports, sound / blitter / 8039 ROMs), the active board's address
//  selected by variant. PROMs stay in their boards, loaded from their window address in index 0.
//  CPUs and sound chips are a pool too (below): z80_0 (main), z80_1 (sound), m6809_0-1, ay[0-4], mcs48_0, sn76489[0-2],
//  each driven by the active board's bus (rtl/chip_pool_pkg.sv).
//
//  ROM window layout per board: see the board module header; tools/gen_mra.py maps the windows onto banks.
//
//============================================================================

module konami82_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic  [7:0] variant,
    input  logic  [3:0] rom_dec,
    input  logic  [7:0] game_flags2,
    input  logic [31:0][7:0] rom_map,   // index 1 bytes 64-95: ROM bank map (Banked ROM store, below)
    output logic        ce_pix,

    input  logic  [7:0] in0,
    input  logic  [7:0] in1,
    input  logic  [7:0] in2,
    input  logic  [7:0] dsw0,
    input  logic  [7:0] dsw1,
    input  logic  [7:0] coin,

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    input  logic        crt_flip,
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank,

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,

    // SDRAM byte port (ioctl index 2 regions): Chance Kun TC8830F samples
    output logic        sdr_req,
    output logic [19:0] sdr_addr,
    input  logic  [7:0] sdr_data,
    input  logic        sdr_busy,

    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

wire is_tp = variant == 8'd0 || variant == 8'd3 || variant == 8'd4 || variant == 8'd5;
wire [1:0] tp_sub = variant == 8'd3 ? 2'd1 : variant == 8'd4 ? 2'd2 : variant == 8'd5 ? 2'd3 : 2'd0;
wire is_po = variant == 8'd1;
wire is_rr = variant == 8'd2;
wire is_jf = variant == 8'd7;
wire is_gy = variant == 8'd8;
wire is_tk = variant == 8'd6 || is_jf;
wire is_cc = variant == 8'd9;
wire is_t8 = variant == 8'd10 || variant == 8'd11;

logic        tp_ce, po_ce, rr_ce, tk_ce;
logic  [7:0] tp_r, tp_g, tp_b, po_r, po_g, po_b, rr_r, rr_g, rr_b, tk_r, tk_g, tk_b;
logic        tp_hs, tp_vs, tp_hb, tp_vb, po_hs, po_vs, po_hb, po_vb, rr_hs, rr_vs, rr_hb, rr_vb;
logic        tk_hs, tk_vs, tk_hb, tk_vb;
logic        gy_ce, gy_hs, gy_vs, gy_hb, gy_vb, gy_irq;
logic  [7:0] gy_r, gy_g, gy_b, gy_latch, gy_hs_d;
logic  [7:0] tp_latch, po_latch, rr_latch, tk_latch, tp_hs_d, po_hs_d, rr_hs_d, tk_hs_d;
logic        tp_irq, tp_mute, po_irq, po_mute, rr_irq, rr_mute, tk_irq, tk_mute;
logic        tp_wdr, po_wdr, rr_wdr, tk_wdr, gy_wdr;              // board watchdog resets to the sound boards
logic [14:0] tp_r0a, po_r0a, rr_r0a, tk_r0a;
logic [13:0] tp_r1a, po_r1a, rr_r1a, tk_r1a;
logic [15:0] tp_r2a, po_r2a, rr_r2a, tk_r2a;
logic  [7:0] rom0_d, rom1_d, rom2_d;
logic [14:0] gy_r0a, gy_r0b_a;
logic [13:0] gy_r1a, gy_r1b_a;
logic [15:0] gy_r2a, gy_r2b_a;
logic  [7:0] rom0b_d, rom1b_d, rom2b_d;
logic        cc_ce, cc_hs, cc_vs, cc_hb, cc_vb, cc_irq;
logic  [7:0] cc_r, cc_g, cc_b, cc_latch, cc_hs_d;
logic [14:0] cc_r0a;
logic [13:0] cc_r1a;
logic [15:0] cc_r2a, cc_r2b_a;
logic        t8_ce, t8_hs, t8_vs, t8_hb, t8_vb, t8_irq;
logic  [7:0] t8_r, t8_g, t8_b, t8_latch, t8_hs_d;
logic [14:0] t8_r0a, t8_r0b_a;
logic [13:0] t8_r1a;
logic [15:0] t8_r2a, t8_r2b_a;

/////////////////////////////  Shared CPU / sound chip pool  /////////////////////////////

// Main Z80: Time Pilot board, Pooyan, Gyruss main
chip_pool_pkg::z80r_i_t tp_z80_0_i, po_z80_0_i, gy_z80_0_i, z80_0_i;
chip_pool_pkg::z80r_o_t z80_0_o;
assign z80_0_i = is_gy ? gy_z80_0_i : is_po ? po_z80_0_i : tp_z80_0_i;

wire [15:0] z80_0_a;
wire  [7:0] z80_0_do;
wire        z80_0_m1_n, z80_0_mreq_n, z80_0_iorq_n, z80_0_rd_n, z80_0_wr_n, z80_0_rfsh_n;

T80s #(.Mode(0), .T2Write(1), .IOWait(1)) z80_0
(
    .RESET_n(~reset & z80_0_i.reset_n), .CLK(clk), .CEN(z80_0_i.ce), .WAIT_n(1'b1), .INT_n(z80_0_i.int_n), .NMI_n(z80_0_i.nmi_n), .BUSRQ_n(1'b1),
    .M1_n(z80_0_m1_n), .MREQ_n(z80_0_mreq_n), .IORQ_n(z80_0_iorq_n), .RD_n(z80_0_rd_n), .WR_n(z80_0_wr_n), .RFSH_n(z80_0_rfsh_n),
    .HALT_n(), .BUSAK_n(), .A(z80_0_a), .DI(z80_0_i.di), .DO(z80_0_do)
);

assign z80_0_o.a = z80_0_a;           assign z80_0_o.dout = z80_0_do;
assign z80_0_o.m1_n = z80_0_m1_n;     assign z80_0_o.mreq_n = z80_0_mreq_n; assign z80_0_o.iorq_n = z80_0_iorq_n;
assign z80_0_o.rd_n = z80_0_rd_n;     assign z80_0_o.wr_n = z80_0_wr_n;     assign z80_0_o.rfsh_n = z80_0_rfsh_n;

// Sound Z80: Time Pilot sound board, Juno First, Gyruss, Circus Charlie, Time Pilot '84
chip_pool_pkg::z80r_i_t tp_z80_1_i, jf_z80_1_i, gy_z80_1_i, cc_z80_1_i, t8_z80_1_i, z80_1_i;
chip_pool_pkg::z80r_o_t z80_1_o;
assign z80_1_i = is_t8 ? t8_z80_1_i : is_cc ? cc_z80_1_i : is_gy ? gy_z80_1_i : is_jf ? jf_z80_1_i : tp_z80_1_i;

wire [15:0] z80_1_a;
wire  [7:0] z80_1_do;
wire        z80_1_m1_n, z80_1_mreq_n, z80_1_iorq_n, z80_1_rd_n, z80_1_wr_n, z80_1_rfsh_n;

T80s #(.Mode(0), .T2Write(1), .IOWait(1)) z80_1
(
    .RESET_n(~reset & z80_1_i.reset_n), .CLK(clk), .CEN(z80_1_i.ce), .WAIT_n(1'b1), .INT_n(z80_1_i.int_n), .NMI_n(z80_1_i.nmi_n), .BUSRQ_n(1'b1),
    .M1_n(z80_1_m1_n), .MREQ_n(z80_1_mreq_n), .IORQ_n(z80_1_iorq_n), .RD_n(z80_1_rd_n), .WR_n(z80_1_wr_n), .RFSH_n(z80_1_rfsh_n),
    .HALT_n(), .BUSAK_n(), .A(z80_1_a), .DI(z80_1_i.di), .DO(z80_1_do)
);

assign z80_1_o.a = z80_1_a;           assign z80_1_o.dout = z80_1_do;
assign z80_1_o.m1_n = z80_1_m1_n;     assign z80_1_o.mreq_n = z80_1_mreq_n; assign z80_1_o.iorq_n = z80_1_iorq_n;
assign z80_1_o.rd_n = z80_1_rd_n;     assign z80_1_o.wr_n = z80_1_wr_n;     assign z80_1_o.rfsh_n = z80_1_rfsh_n;

// MC6809E: Roc'n Rope, Tutankham / Juno First, Gyruss sub, Circus Charlie, Time Pilot '84 main (Greg Miller's mc6809is, unmodified)
chip_pool_pkg::m6809r_i_t rr_m6809_0_i, tk_m6809_0_i, gy_m6809_0_i, cc_m6809_0_i, t8_m6809_0_i, m6809_0_i;
chip_pool_pkg::m6809r_o_t m6809_0_o;
assign m6809_0_i = is_t8 ? t8_m6809_0_i : is_cc ? cc_m6809_0_i : is_gy ? gy_m6809_0_i : is_tk ? tk_m6809_0_i : rr_m6809_0_i;

wire [15:0] m6809_0_a;
wire  [7:0] m6809_0_do;
wire        m6809_0_rw, m6809_0_lic;

mc6809is m6809_0
(
    .CLK(clk), .fallE_en(m6809_0_i.fall_e), .fallQ_en(m6809_0_i.fall_q), .D(m6809_0_i.d), .DOut(m6809_0_do), .ADDR(m6809_0_a),
    .RnW(m6809_0_rw), .BS(), .BA(), .nIRQ(m6809_0_i.irq_n), .nFIRQ(m6809_0_i.firq_n), .nNMI(m6809_0_i.nmi_n), .AVMA(), .BUSY(),
    .LIC(m6809_0_lic), .nHALT(1'b1), .nRESET(~reset & m6809_0_i.reset_n), .nDMABREQ(1'b1), .RegData()
);

assign m6809_0_o.a = m6809_0_a;  assign m6809_0_o.dout = m6809_0_do;  assign m6809_0_o.rw = m6809_0_rw;  assign m6809_0_o.lic = m6809_0_lic;

// Second MC6809E: Time Pilot '84 sub
chip_pool_pkg::m6809r_i_t t8_m6809_1_i, m6809_1_i;
chip_pool_pkg::m6809r_o_t m6809_1_o;
assign m6809_1_i = t8_m6809_1_i;

wire [15:0] m6809_1_a;
wire  [7:0] m6809_1_do;
wire        m6809_1_rw, m6809_1_lic;

mc6809is m6809_1
(
    .CLK(clk), .fallE_en(m6809_1_i.fall_e), .fallQ_en(m6809_1_i.fall_q), .D(m6809_1_i.d), .DOut(m6809_1_do), .ADDR(m6809_1_a),
    .RnW(m6809_1_rw), .BS(), .BA(), .nIRQ(m6809_1_i.irq_n), .nFIRQ(m6809_1_i.firq_n), .nNMI(m6809_1_i.nmi_n), .AVMA(), .BUSY(),
    .LIC(m6809_1_lic), .nHALT(1'b1), .nRESET(~reset & m6809_1_i.reset_n), .nDMABREQ(1'b1), .RegData()
);

assign m6809_1_o.a = m6809_1_a;  assign m6809_1_o.dout = m6809_1_do;  assign m6809_1_o.rw = m6809_1_rw;  assign m6809_1_o.lic = m6809_1_lic;

// AY-3-8910 x 5: Time Pilot sound board uses 0-1, Juno First 0, Gyruss 0-4
chip_pool_pkg::ay_i_t [1:0] tp_ay_i;
chip_pool_pkg::ay_i_t [0:0] jf_ay_i;
chip_pool_pkg::ay_i_t [4:0] gy_ay_i;
chip_pool_pkg::ay_o_t [4:0] ay_o;

genvar ai;
generate
    for (ai = 0; ai < 5; ai = ai + 1) begin : g_ay
        chip_pool_pkg::ay_i_t i;
        if (ai == 0)      begin : g0 assign i = is_gy ? gy_ay_i[ai] : is_jf ? jf_ay_i[0] : tp_ay_i[ai]; end
        else if (ai == 1) begin : g1 assign i = is_gy ? gy_ay_i[ai] : tp_ay_i[ai]; end
        else              begin : gn assign i = gy_ay_i[ai]; end
        wire [7:0] dout, a, b, c, iob;
        wire [9:0] snd;
        jt49_bus ay
        (
            .rst_n(~reset), .clk(clk), .clk_en(i.ce), .bdir(i.bdir), .bc1(i.bc1), .din(i.din), .sel(1'b1),
            .dout(dout), .sound(snd), .A(a), .B(b), .C(c), .sample(),
            .IOA_in(i.ioa_in), .IOA_out(), .IOB_in(i.iob_in), .IOB_out(iob)
        );
        assign ay_o[ai].dout = dout; assign ay_o[ai].a = a; assign ay_o[ai].b = b; assign ay_o[ai].c = c;
        assign ay_o[ai].iob_out = iob; assign ay_o[ai].sound = snd;
    end
endgenerate

// 8039: Juno First, Gyruss (T48 t8039_notri_extrom, Arnim Laeuger; program on pmem, EA low)
chip_pool_pkg::mcs48_i_t jf_mcs48_0_i, gy_mcs48_0_i, mcs48_0_i;
chip_pool_pkg::mcs48_o_t mcs48_0_o;
assign mcs48_0_i = is_gy ? gy_mcs48_0_i : jf_mcs48_0_i;

wire  [7:0] mcu_p1, mcu_p2;
wire [11:0] mcu_pa;
wire        mcu_rd_n;

t8039_notri_extrom #(
    .gate_port_input_g (0),
    .ram_addr_width_g  (7)                       // 8039 = 128 bytes internal RAM
) mcs48_0 (
    .xtal_i(clk), .xtal_en_i(mcs48_0_i.xtal_en), .reset_n_i(~reset),
    .t0_i(1'b0), .t0_o(), .t0_dir_o(), .int_n_i(mcs48_0_i.int_n), .ea_i(1'b0),
    .rd_n_o(mcu_rd_n), .psen_n_o(), .wr_n_o(), .ale_o(),
    .db_i(mcs48_0_i.db), .db_o(), .db_dir_o(), .t1_i(1'b0),
    .p2_i(8'hFF), .p2_o(mcu_p2), .p2l_low_imp_o(), .p2h_low_imp_o(),
    .p1_i(8'hFF), .p1_o(mcu_p1), .p1_low_imp_o(), .prog_n_o(),
    .pmem_addr_o(mcu_pa), .pmem_data_i(mcs48_0_i.pmem_d)
);

assign mcs48_0_o.p1 = mcu_p1;  assign mcs48_0_o.p2 = mcu_p2;  assign mcs48_0_o.pmem_a = mcu_pa;  assign mcs48_0_o.rd_n = mcu_rd_n;

// SN76489A x 3: Circus Charlie 0-1, Time Pilot '84 0-2 (jt89, Jose Tejada)
chip_pool_pkg::sn76489_i_t [1:0] cc_sn76489_i;
chip_pool_pkg::sn76489_i_t [2:0] t8_sn76489_i;
chip_pool_pkg::sn76489_o_t [2:0] sn76489_o;

genvar si;
generate
    for (si = 0; si < 3; si = si + 1) begin : g_sn76489
        chip_pool_pkg::sn76489_i_t i;
        if (si < 2) begin : gc assign i = is_t8 ? t8_sn76489_i[si] : cc_sn76489_i[si]; end
        else        begin : gt assign i = t8_sn76489_i[si]; end
        wire [10:0] sound;
        wire        ready;
        jt89 sn76489
        (
            .rst(i.rst), .clk(clk), .clk_en(i.ce), .wr_n(i.wr_n), .cs_n(i.cs_n), .din(i.din), .sound(sound), .ready(ready)
        );
        assign sn76489_o[si].sound = sound; assign sn76489_o[si].ready = ready;
    end
endgenerate

/////////////////////////////  Banked ROM store  /////////////////////////////

// Every ROM image lives in one store of NBANK 8K banks. Loading is linear and variant-free (the variant arrives after
// the ROMs): index 0 byte n -> bank n[16:13], offset n[12:0]; tools/gen_mra.py copies each set's window pages
// bank-aligned (PROMs stay at their window address, read by the boards' own loaders).
// Each ROM reader is a channel issuing the window address it always did. Per set, index 1 (rom_map) gives each
// channel a base bank (bank = base + address[15:13], mod 16; bytes 0-15) and each bank its owner on either port
// ({port A, port B} channel, F = none; bytes 16-31). A channel reading a bank it doesn't own gets 0, as an unloaded
// window byte read before. Same latency as one RAM: the owners' addresses go straight to the banks, and the data
// comes back through a bank select registered alongside them.
//   port B: 0 rom0, 1 rom1, 2 rom2, 3 rom3, 4 Time Pilot sound ROM, 5 Juno First blitter ROM
//   port A: 8 rom0b, 9 rom1b, 10 rom2b, 11 Juno First 8039 ROM (port A also loads, on the write strobe)
localparam NBANK = 15;

wire [13:0] cc_r3a;
wire [12:0] t8_r3a;
wire [11:0] jf_r3a;
wire  [7:0] rom3_d;
logic [12:0] snd_rom_a;
logic [14:0] blt_rom_a;
logic [11:0] jf_mcu_a;
logic  [7:0] snd_rom_d, blt_rom_d, jf_mcu_d;

logic [15:0] ch_a[16];                          // channel window address, by channel id
logic  [7:0] ch_d[16];
always_comb begin
    for (int c = 0; c < 16; c++) ch_a[c] = 16'd0;
    ch_a[0]  = {1'b0, is_t8 ? t8_r0a : is_cc ? cc_r0a : is_gy ? gy_r0a : is_tk ? tk_r0a : is_rr ? rr_r0a : is_po ? po_r0a : tp_r0a};
    ch_a[1]  = {2'b00, is_t8 ? t8_r1a : is_cc ? cc_r1a : is_gy ? gy_r1a : is_tk ? tk_r1a : is_rr ? rr_r1a : is_po ? po_r1a : tp_r1a};
    ch_a[2]  = is_t8 ? t8_r2a : is_cc ? cc_r2a : is_gy ? gy_r2a : is_tk ? tk_r2a : is_rr ? rr_r2a : is_po ? po_r2a : tp_r2a;
    ch_a[3]  = {2'b00, is_cc ? cc_r3a : is_t8 ? {1'b0, t8_r3a} : {2'b00, jf_r3a}};
    ch_a[4]  = {3'b000, snd_rom_a};
    ch_a[5]  = {1'b0, blt_rom_a};
    ch_a[8]  = {1'b0, is_t8 ? t8_r0b_a : gy_r0b_a};
    ch_a[9]  = {2'b00, gy_r1b_a};
    ch_a[10] = is_t8 ? t8_r2b_a : is_cc ? cc_r2b_a : gy_r2b_a;
    ch_a[11] = {4'd0, jf_mcu_a};
end

assign rom0_d = ch_d[0];   assign rom1_d = ch_d[1];   assign rom2_d = ch_d[2];   assign rom3_d = ch_d[3];
assign snd_rom_d = ch_d[4];   assign blt_rom_d = ch_d[5];
assign rom0b_d = ch_d[8];  assign rom1b_d = ch_d[9];  assign rom2b_d = ch_d[10]; assign jf_mcu_d = ch_d[11];

// Bank owners, registered from rom_map (static once the set is loaded): low 3 bits index the port's channels
logic [3:0] own_a[NBANK], own_b[NBANK];
always_ff @(posedge clk)
    for (int b = 0; b < NBANK; b++) {own_a[b], own_b[b]} <= rom_map[16 + b];

// Bank each channel addresses, and whether it owns it there, registered with the address the banks take
wire  [3:0] ch_bank[16];
logic [3:0] rd_bank[16];
logic       rd_own[16];
genvar ci;
generate
    for (ci = 0; ci < 16; ci = ci + 1) begin : g_ch
        assign ch_bank[ci] = rom_map[ci][3:0] + {1'b0, ch_a[ci][15:13]};
        wire [3:0] owner = ch_bank[ci] >= NBANK ? 4'hF : ci < 8 ? own_b[ch_bank[ci]] : own_a[ch_bank[ci]];
        always_ff @(posedge clk) begin
            rd_bank[ci] <= ch_bank[ci];
            rd_own[ci]  <= owner == ci;
        end
    end
endgenerate

wire  [7:0] bank_qa[16], bank_qb[16];               // 15: no bank
assign bank_qa[15] = 8'd0;
assign bank_qb[15] = 8'd0;
always_comb
    for (int c = 0; c < 16; c++) ch_d[c] = ~rd_own[c] ? 8'd0 : c < 8 ? bank_qb[rd_bank[c]] : bank_qa[rd_bank[c]];

genvar bi;
generate
    for (bi = 0; bi < NBANK; bi = bi + 1) begin : g_bank
        wire        ld  = ioctl_wr0 && ioctl_addr[24:13] == 12'(bi);
        wire [12:0] a_b = ch_a[{1'b0, own_b[bi][2:0]}][12:0];      // F (none): channel 7, unused
        wire [12:0] a_a = ch_a[{1'b1, own_a[bi][2:0]}][12:0];      // F (none): channel 15, unused
        dpram_dc #(.widthad_a(13)) rom
        (
            .clock_a(clk), .address_a(ld ? ioctl_addr[12:0] : a_a), .data_a(ioctl_dout), .wren_a(ld), .q_a(bank_qa[bi]),
            .clock_b(clk), .address_b(a_b), .q_b(bank_qb[bi])
        );
    end
endgenerate

timeplt_board timeplt
(
    .clk(clk),
    .reset(reset | ~is_tp),
    .pause(pause),
    .sub(tp_sub),
    .ce_pix(tp_ce),

    .in0(in0),
    .in1(in1),
    .in2(in2),
    .dsw0(dsw0),
    .dsw1(dsw1),

    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_wr0(ioctl_wr0),
    .rom0_a(tp_r0a),
    .rom0_d(rom0_d),
    .rom1_a(tp_r1a),
    .rom1_d(rom1_d),
    .rom2_a(tp_r2a),
    .rom2_d(rom2_d),

    .crt_flip(crt_flip),
    .h_adj(h_adj),
    .v_adj(v_adj),

    .video_r(tp_r),
    .video_g(tp_g),
    .video_b(tp_b),
    .video_hs(tp_hs),
    .video_vs(tp_vs),
    .video_hblank(tp_hb),
    .video_vblank(tp_vb),

    .wd_reset(tp_wdr),
    .snd_latch(tp_latch),
    .snd_irq(tp_irq),
    .snd_mute(tp_mute),

    .z80_0_i(tp_z80_0_i),
    .z80_0_o(z80_0_o),

    .hs_address(hs_address),
    .hs_data_in(hs_data_in),
    .hs_data_out(tp_hs_d),
    .hs_write(hs_write & is_tp)
);

pooyan_board pooyan
(
    .clk(clk),
    .reset(reset | ~is_po),
    .pause(pause),
    .ce_pix(po_ce),

    .in0(in0),
    .in1(in1),
    .in2(in2),
    .dsw0(dsw0),
    .dsw1(dsw1),

    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_wr0(ioctl_wr0),
    .rom0_a(po_r0a),
    .rom0_d(rom0_d),
    .rom1_a(po_r1a),
    .rom1_d(rom1_d),
    .rom2_a(po_r2a),
    .rom2_d(rom2_d),

    .crt_flip(crt_flip),
    .h_adj(h_adj),
    .v_adj(v_adj),

    .video_r(po_r),
    .video_g(po_g),
    .video_b(po_b),
    .video_hs(po_hs),
    .video_vs(po_vs),
    .video_hblank(po_hb),
    .video_vblank(po_vb),

    .wd_reset(po_wdr),
    .snd_latch(po_latch),
    .snd_irq(po_irq),
    .snd_mute(po_mute),

    .z80_0_i(po_z80_0_i),
    .z80_0_o(z80_0_o),

    .hs_address(hs_address),
    .hs_data_in(hs_data_in),
    .hs_data_out(po_hs_d),
    .hs_write(hs_write & is_po)
);

rocnrope_board rocnrope
(
    .clk(clk),
    .reset(reset | ~is_rr),
    .pause(pause),
    .rom_dec(rom_dec),
    .ce_pix(rr_ce),

    .in0(in0),
    .in1(in1),
    .in2(in2),
    .dsw0(dsw0),
    .dsw1(dsw1),
    .dsw2(coin),                                // DSW3 rides the sixth input port

    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_wr0(ioctl_wr0),
    .rom0_a(rr_r0a),
    .rom0_d(rom0_d),
    .rom1_a(rr_r1a),
    .rom1_d(rom1_d),
    .rom2_a(rr_r2a),
    .rom2_d(rom2_d),

    .crt_flip(crt_flip),
    .h_adj(h_adj),
    .v_adj(v_adj),

    .video_r(rr_r),
    .video_g(rr_g),
    .video_b(rr_b),
    .video_hs(rr_hs),
    .video_vs(rr_vs),
    .video_hblank(rr_hb),
    .video_vblank(rr_vb),

    .wd_reset(rr_wdr),
    .snd_latch(rr_latch),
    .snd_irq(rr_irq),
    .snd_mute(rr_mute),

    .m6809_0_i(rr_m6809_0_i),
    .m6809_0_o(m6809_0_o),

    .hs_address(hs_address),
    .hs_data_in(hs_data_in),
    .hs_data_out(rr_hs_d),
    .hs_write(hs_write & is_rr)
);

tutankhm_board tutankhm
(
    .clk(clk),
    .reset(reset | ~is_tk),
    .pause(pause),
    .juno(is_jf),
    .ce_pix(tk_ce),

    .in0(in0),
    .in1(in1),
    .in2(in2),
    .dsw0(dsw0),
    .dsw1(dsw1),

    .rom0_a(tk_r0a),
    .rom0_d(rom0_d),
    .rom1_a(tk_r1a),
    .rom1_d(rom1_d),
    .rom2_a(tk_r2a),
    .rom2_d(rom2_d),
    .blt_rom_a(blt_rom_a),
    .blt_rom_d(blt_rom_d),

    .crt_flip(crt_flip),
    .h_adj(h_adj),
    .v_adj(v_adj),

    .video_r(tk_r),
    .video_g(tk_g),
    .video_b(tk_b),
    .video_hs(tk_hs),
    .video_vs(tk_vs),
    .video_hblank(tk_hb),
    .video_vblank(tk_vb),

    .wd_reset(tk_wdr),
    .snd_latch(tk_latch),
    .snd_irq(tk_irq),
    .snd_mute(tk_mute),

    .m6809_0_i(tk_m6809_0_i),
    .m6809_0_o(m6809_0_o),

    .hs_address(hs_address),
    .hs_data_in(hs_data_in),
    .hs_data_out(tk_hs_d),
    .hs_write(hs_write & is_tk)
);

assign ce_pix       = is_t8 ? t8_ce   : is_cc ? cc_ce   : is_gy ? gy_ce   : is_tk ? tk_ce   : is_rr ? rr_ce   : is_po ? po_ce   : tp_ce;
assign video_r      = is_t8 ? t8_r    : is_cc ? cc_r    : is_gy ? gy_r    : is_tk ? tk_r    : is_rr ? rr_r    : is_po ? po_r    : tp_r;
assign video_g      = is_t8 ? t8_g    : is_cc ? cc_g    : is_gy ? gy_g    : is_tk ? tk_g    : is_rr ? rr_g    : is_po ? po_g    : tp_g;
assign video_b      = is_t8 ? t8_b    : is_cc ? cc_b    : is_gy ? gy_b    : is_tk ? tk_b    : is_rr ? rr_b    : is_po ? po_b    : tp_b;
assign video_hs     = is_t8 ? t8_hs   : is_cc ? cc_hs   : is_gy ? gy_hs   : is_tk ? tk_hs   : is_rr ? rr_hs   : is_po ? po_hs   : tp_hs;
assign video_vs     = is_t8 ? t8_vs   : is_cc ? cc_vs   : is_gy ? gy_vs   : is_tk ? tk_vs   : is_rr ? rr_vs   : is_po ? po_vs   : tp_vs;
assign video_hblank = is_t8 ? t8_hb   : is_cc ? cc_hb   : is_gy ? gy_hb   : is_tk ? tk_hb   : is_rr ? rr_hb   : is_po ? po_hb   : tp_hb;
assign video_vblank = is_t8 ? t8_vb   : is_cc ? cc_vb   : is_gy ? gy_vb   : is_tk ? tk_vb   : is_rr ? rr_vb   : is_po ? po_vb   : tp_vb;
assign hs_data_out  = is_t8 ? t8_hs_d : is_cc ? cc_hs_d : is_gy ? gy_hs_d : is_tk ? tk_hs_d : is_rr ? rr_hs_d : is_po ? po_hs_d : tp_hs_d;

gyruss_board gyruss
(
    .clk(clk),
    .reset(reset | ~is_gy),
    .pause(pause),
    .ce_pix(gy_ce),

    .in0(in0),
    .in1(in1),
    .in2(in2),
    .dsw0(dsw0),
    .dsw1(dsw1),
    .dsw2(coin),                                // DSW3 rides the sixth input port

    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_wr0(ioctl_wr0),
    .rom0_a(gy_r0a),
    .rom0_d(rom0_d),
    .rom0b_a(gy_r0b_a),
    .rom0b_d(rom0b_d),
    .rom1_a(gy_r1a),
    .rom1_d(rom1_d),
    .rom2_a(gy_r2a),
    .rom2_d(rom2_d),

    .crt_flip(crt_flip),
    .h_adj(h_adj),
    .v_adj(v_adj),

    .video_r(gy_r),
    .video_g(gy_g),
    .video_b(gy_b),
    .video_hs(gy_hs),
    .video_vs(gy_vs),
    .video_hblank(gy_hb),
    .video_vblank(gy_vb),

    .wd_reset(gy_wdr),
    .snd_latch(gy_latch),
    .snd_irq(gy_irq),

    .z80_0_i(gy_z80_0_i),
    .z80_0_o(z80_0_o),
    .m6809_0_i(gy_m6809_0_i),
    .m6809_0_o(m6809_0_o),

    .hs_address(hs_address),
    .hs_data_in(hs_data_in),
    .hs_data_out(gy_hs_d),
    .hs_write(hs_write & is_gy)
);

/////////////////////////////  Time Pilot sound board  /////////////////////////////

logic [16:0] tc_rom_addr;
assign sdr_addr = {3'd0, tc_rom_addr};             // TC8830F ROM at SDRAM byte 0 (index 2 offset 0)

logic signed [15:0] tp_audio, jf_audio;

timeplt_sound sound
(
    .clk(clk),
    .reset(reset | is_jf | is_gy | is_cc | is_t8 | tp_wdr | po_wdr | rr_wdr | tk_wdr),
    .pause(pause),
    .rom_a(snd_rom_a),
    .rom_q(snd_rom_d),
    .latch(is_tk ? tk_latch : is_rr ? rr_latch : is_po ? po_latch : tp_latch),
    .irq_trig(is_tk ? tk_irq : is_rr ? rr_irq : is_po ? po_irq : tp_irq),
    .mute(is_tk ? tk_mute : is_rr ? rr_mute : is_po ? po_mute : tp_mute),
    .tc_en(variant == 8'd5),                    // Chance Kun
    .tc_rom_req(sdr_req),
    .tc_rom_addr(tc_rom_addr),
    .tc_rom_data(sdr_data),
    .tc_rom_busy(sdr_busy),
    .z80_1_i(tp_z80_1_i),
    .z80_1_o(z80_1_o),
    .ay_i(tp_ay_i),
    .ay_o(ay_o[1:0]),
    .audio(tp_audio)
);

/////////////////////////////  Juno First sound board  /////////////////////////////

junofrst_sound jf_sound
(
    .clk(clk),
    .reset(reset | ~is_jf | tk_wdr),
    .pause(pause),
    .rom3_a(jf_r3a),
    .rom3_d(rom3_d),
    .mcu_rom_a(jf_mcu_a),
    .mcu_rom_d(jf_mcu_d),
    .latch(tk_latch),
    .irq_trig(tk_irq),
    .mute(tk_mute),
    .z80_1_i(jf_z80_1_i),
    .z80_1_o(z80_1_o),
    .ay_i(jf_ay_i),
    .ay_o(ay_o[0:0]),
    .mcs48_0_i(jf_mcs48_0_i),
    .mcs48_0_o(mcs48_0_o),
    .audio(jf_audio)
);

/////////////////////////////  Gyruss sound board (stereo)  /////////////////////////////

logic signed [15:0] gy_audio_l, gy_audio_r;

gyruss_sound gy_sound
(
    .clk(clk),
    .reset(reset | ~is_gy | gy_wdr),
    .pause(pause),
    .z80_rom_a(gy_r2b_a),
    .z80_rom_d(rom2b_d),
    .mcu_rom_a(gy_r1b_a),
    .mcu_rom_d(rom1b_d),
    .latch(gy_latch),
    .irq_trig(gy_irq),
    .z80_1_i(gy_z80_1_i),
    .z80_1_o(z80_1_o),
    .ay_i(gy_ay_i),
    .ay_o(ay_o),
    .mcs48_0_i(gy_mcs48_0_i),
    .mcs48_0_o(mcs48_0_o),
    .audio_l(gy_audio_l),
    .audio_r(gy_audio_r)
);

/////////////////////////////  Circus Charlie  /////////////////////////////

circusc_board circusc
(
    .clk(clk),
    .reset(reset | ~is_cc),
    .pause(pause),
    .ce_pix(cc_ce),

    .in0(in0),
    .in1(in1),
    .in2(in2),
    .dsw0(dsw0),
    .dsw1(dsw1),

    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_wr0(ioctl_wr0),
    .rom0_a(cc_r0a),
    .rom0_d(rom0_d),
    .rom1_a(cc_r1a),
    .rom1_d(rom1_d),
    .rom2_a(cc_r2a),
    .rom2_d(rom2_d),
    .rom3_a(cc_r3a),
    .rom3_d(rom3_d),

    .crt_flip(crt_flip),
    .h_adj(h_adj),
    .v_adj(v_adj),

    .video_r(cc_r),
    .video_g(cc_g),
    .video_b(cc_b),
    .video_hs(cc_hs),
    .video_vs(cc_vs),
    .video_hblank(cc_hb),
    .video_vblank(cc_vb),

    .snd_latch(cc_latch),
    .snd_irq(cc_irq),

    .m6809_0_i(cc_m6809_0_i),
    .m6809_0_o(m6809_0_o),

    .hs_address(hs_address),
    .hs_data_in(hs_data_in),
    .hs_data_out(cc_hs_d),
    .hs_write(hs_write & is_cc)
);

logic signed [15:0] cc_audio;

circusc_sound cc_sound
(
    .clk(clk),
    .reset(reset | ~is_cc),
    .pause(pause),
    .z80_rom_a(cc_r2b_a),
    .z80_rom_d(rom2b_d),
    .latch(cc_latch),
    .irq_trig(cc_irq),
    .z80_1_i(cc_z80_1_i),
    .z80_1_o(z80_1_o),
    .sn76489_i(cc_sn76489_i),
    .sn76489_o(sn76489_o[1:0]),
    .audio(cc_audio)
);

/////////////////////////////  Time Pilot '84  /////////////////////////////

tp84_board tp84
(
    .clk(clk),
    .reset(reset | ~is_t8),
    .pause(pause),
    .b84(variant == 8'd11),
    .ce_pix(t8_ce),

    .in0(in0),
    .in1(in1),
    .in2(in2),
    .dsw0(dsw0),
    .dsw1(dsw1),

    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_wr0(ioctl_wr0),
    .rom0_a(t8_r0a),
    .rom0_d(rom0_d),
    .rom0b_a(t8_r0b_a),
    .rom0b_d(rom0b_d),
    .rom1_a(t8_r1a),
    .rom1_d(rom1_d),
    .rom2_a(t8_r2a),
    .rom2_d(rom2_d),
    .rom3_a(t8_r3a),
    .rom3_d(rom3_d),

    .crt_flip(crt_flip),
    .h_adj(h_adj),
    .v_adj(v_adj),

    .video_r(t8_r),
    .video_g(t8_g),
    .video_b(t8_b),
    .video_hs(t8_hs),
    .video_vs(t8_vs),
    .video_hblank(t8_hb),
    .video_vblank(t8_vb),

    .snd_latch(t8_latch),
    .snd_irq(t8_irq),

    .m6809_0_i(t8_m6809_0_i),
    .m6809_0_o(m6809_0_o),
    .m6809_1_i(t8_m6809_1_i),
    .m6809_1_o(m6809_1_o),

    .hs_address(hs_address),
    .hs_data_in(hs_data_in),
    .hs_data_out(t8_hs_d),
    .hs_write(hs_write & is_t8)
);

logic signed [15:0] t8_audio;

tp84_sound t8_sound
(
    .clk(clk),
    .reset(reset | ~is_t8),
    .pause(pause),
    .z80_rom_a(t8_r2b_a),
    .z80_rom_d(rom2b_d),
    .latch(t8_latch),
    .irq_trig(t8_irq),
    .z80_1_i(t8_z80_1_i),
    .z80_1_o(z80_1_o),
    .sn76489_i(t8_sn76489_i),
    .sn76489_o(sn76489_o),
    .audio(t8_audio)
);

assign audio_l = is_t8 ? t8_audio : is_cc ? cc_audio : is_gy ? gy_audio_l : is_jf ? jf_audio : tp_audio;
assign audio_r = is_t8 ? t8_audio : is_cc ? cc_audio : is_gy ? gy_audio_r : is_jf ? jf_audio : tp_audio;

endmodule
