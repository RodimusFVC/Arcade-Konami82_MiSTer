//============================================================================
//
//  Konami Gyruss sound board
//  Copyright (C) 2026 Rodimus
//
//  Written from the Gyruss sound schematic and MAME gyruss.cpp (Nicola Salmoria, Couriersud).
//  Z80 (14.31818 / 4) with five AY-3-8910s (14.31818 / 8) on I/O ports, an 8039 (8 MHz) playing samples into
//  a DAC on P1. Stereo: right = AY1 (switchable RC filters, AY1 port B) + AY3 + AY4, left = AY2 (filters on AY2
//  port B) + AY5 + DAC (MAME konami_right/left_mixer_desc). AY3 port A = /1024 bi-quinary timer.
//  8039 INT: LS74 5D set by the Z80's port-14 write, cleared while P2.7 is low (schematic: /CLR = P27).
//  8039 = T48 (Arnim Laeuger) through t8039_notri_extrom, program on the pmem port (EA low).
//
//  ROMs are in the shared blocks (rtl/konami82_board.sv), second ports:
//    audiocpu 0000-5FFF at ioctl 0x18000 (block 2), audio2 (8039) at ioctl 0x0E000 (block 1)
//
//============================================================================

module gyruss_sound
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,

    output logic [15:0] z80_rom_a,      // block 2 second port (0x18000 + a)
    input  logic  [7:0] z80_rom_d,
    output logic [13:0] mcu_rom_a,      // block 1 second port (0x0E000 + a)
    input  logic  [7:0] mcu_rom_d,

    input  logic  [7:0] latch,          // main CPU sound command (C100)
    input  logic        irq_trig,       // main CPU C080 write: interrupts the Z80

    output chip_pool_pkg::z80_i_t   z80_1_i,           // shared sound Z80 (rtl/konami82_board.sv)
    input  chip_pool_pkg::z80_o_t   z80_1_o,
    output chip_pool_pkg::ay_i_t  [4:0] ay_i,      // shared AYs (rtl/konami82_board.sv)
    input  chip_pool_pkg::ay_o_t  [4:0] ay_o,
    output chip_pool_pkg::mcs48_i_t mcs48_0_i,          // shared 8039 (rtl/konami82_board.sv)
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r
);

// 14.31818 MHz / 4 = 3.579545 MHz from 49.152 MHz, exact on average; AYs on every other one
logic [25:0] acc = 26'd0;
logic        ce_snd = 1'b0;
always_ff @(posedge clk) begin
    if (acc >= 26'd49152000 - 26'd3579545) begin
        acc    <= acc + 26'd3579545 - 26'd49152000;
        ce_snd <= 1'b1;
    end else begin
        acc    <= acc + 26'd3579545;
        ce_snd <= 1'b0;
    end
end

logic ay_ph = 1'b0;
always_ff @(posedge clk) if (ce_snd) ay_ph <= ~ay_ph;

wire cpu_ce = ce_snd & ~pause;
wire ay_ce  = ce_snd & ay_ph & ~pause;           // 1.789772 MHz

// 8 MHz 8039 crystal from 49.152 MHz (49152 / 8000 = 6.144)
logic [15:0] acc8 = 16'd0;
logic        ce_8m = 1'b0;
always_ff @(posedge clk) begin
    if (acc8 >= 16'd49152 - 16'd8000) begin
        acc8  <= acc8 + 16'd8000 - 16'd49152;
        ce_8m <= ~pause;
    end else begin
        acc8  <= acc8 + 16'd8000;
        ce_8m <= 1'b0;
    end
end

/////////////////////////////  Z80  /////////////////////////////

logic [15:0] a;
logic  [7:0] cpu_do, cpu_di;
logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
logic        irq_ff = 1'b0;

// Sound CPU: the shared T80 in rtl/konami82_board.sv
assign z80_1_i.ce    = cpu_ce;
assign z80_1_i.int_n = ~irq_ff;
assign z80_1_i.nmi_n = 1'b1;
assign z80_1_i.di    = cpu_di;
assign a = z80_1_o.a;
assign cpu_do = z80_1_o.dout;
assign m1_n = z80_1_o.m1_n;
assign mreq_n = z80_1_o.mreq_n;
assign iorq_n = z80_1_o.iorq_n;
assign rd_n = z80_1_o.rd_n;
assign wr_n = z80_1_o.wr_n;
assign rfsh_n = z80_1_o.rfsh_n;

// Interrupt (IM 1, MAME HOLD_LINE): set on the trigger's rising edge, held until the CPU acknowledges it
logic trig_d = 1'b0;
always_ff @(posedge clk) begin
    trig_d <= irq_trig;
    if (reset)                     irq_ff <= 1'b0;
    else if (irq_trig & ~trig_d)   irq_ff <= 1'b1;
    else if (~m1_n & ~iorq_n)      irq_ff <= 1'b0;
end

wire mem    = ~mreq_n & rfsh_n;
wire io     = ~iorq_n & m1_n;
wire cs_rom = mem && a[15:13] < 3'd3;            // 0000-5FFF
wire cs_ram = mem && a[15:10] == 6'b0110_00;     // 6000-63FF
wire cs_lat = mem && a[15:12] == 4'h8;           // 8000 sound latch

assign z80_rom_a = {1'b1, a[14:0]};                // block 2 at 0x8000 (ioctl 0x18000)

logic [7:0] ram_d;
spram #(.ADDR_WIDTH(10)) ram
(
    .clk(clk), .addr(a[9:0]), .data(cpu_do), .we(cs_ram & ~wr_n), .q(ram_d)
);

/////////////////////////////  AY-3-8910 x 5  /////////////////////////////

// I/O A4-A2: 0-4 = AY1-AY5 (A1-A0: 0 address, 1 read, 2 data), 5 = 8039 interrupt (14), 6 = 8039 latch (18)
wire [2:0] io_sel = a[4:2];

// AY3 port A: sound clock / 1024, then a bi-quinary / 10 (MAME gyruss porta_r timer[] sequence)
logic [9:0] tdiv = 10'd0;
logic [3:0] tseq = 4'd0;
always_ff @(posedge clk) begin
    if (cpu_ce) begin
        tdiv <= tdiv + 10'd1;
        if (tdiv == 10'd1023) tseq <= (tseq == 4'd9) ? 4'd0 : tseq + 4'd1;
    end
end

logic [7:0] timer;
always_comb begin
    case (tseq)
        4'd0: timer = 8'h00;  4'd1: timer = 8'h01;  4'd2: timer = 8'h02;  4'd3: timer = 8'h03;
        4'd4: timer = 8'h04;  4'd5: timer = 8'h09;  4'd6: timer = 8'h0A;  4'd7: timer = 8'h0B;
        4'd8: timer = 8'h0A;  default: timer = 8'h0D;
    endcase
end

logic [7:0] ay_do[5];
logic [7:0] ay_a[5], ay_b[5], ay_c[5];
logic [7:0] ay1_pb, ay2_pb;

// The five AYs: the shared AYs in rtl/konami82_board.sv
genvar gi;
generate
    for (gi = 0; gi < 5; gi = gi + 1) begin : g_ay
        wire cs = io && io_sel == gi;
        assign ay_i[gi].ce     = ay_ce;
        assign ay_i[gi].bdir   = cs & ~wr_n;
        assign ay_i[gi].bc1    = cs & ((~wr_n & ~a[1]) | ~rd_n);
        assign ay_i[gi].din    = cpu_do;
        assign ay_i[gi].ioa_in = (gi == 2) ? timer : 8'hFF;
        assign ay_i[gi].iob_in = 8'hFF;
        assign ay_do[gi] = ay_o[gi].dout;
        assign ay_a[gi]  = ay_o[gi].a;
        assign ay_b[gi]  = ay_o[gi].b;
        assign ay_c[gi]  = ay_o[gi].c;
    end
endgenerate

assign ay1_pb = ay_o[0].iob_out;
assign ay2_pb = ay_o[1].iob_out;

always_comb begin
    if      (cs_rom)                                cpu_di = z80_rom_d;
    else if (cs_ram)                                cpu_di = ram_d;
    else if (cs_lat)                                cpu_di = latch;
    else if (io && io_sel < 3'd5 && a[1:0] == 2'd1) cpu_di = ay_do[io_sel];
    else                                            cpu_di = 8'hFF;
end

/////////////////////////////  8039  /////////////////////////////

logic [7:0] latch2 = 8'h00;
logic       mcu_irq = 1'b0;
logic [7:0] mcu_p1, mcu_p2;
logic [11:0] mcu_pa;
logic       wr_d = 1'b0;

always_ff @(posedge clk) begin
    wr_d <= ~wr_n;
    if (reset) begin
        latch2  <= 8'h00;
        mcu_irq <= 1'b0;
    end else begin
        if (io && ~wr_n && ~wr_d && io_sel == 3'd6) latch2 <= cpu_do;
        if (~mcu_p2[7])                                    mcu_irq <= 1'b0;
        else if (io && ~wr_n && ~wr_d && io_sel == 3'd5)   mcu_irq <= 1'b1;
    end
end

assign mcu_rom_a = {2'b10, mcu_pa};              // block 1 at 0x2000 (ioctl 0x0E000)

// 8039: the shared 8039 in rtl/konami82_board.sv
assign mcs48_0_i.xtal_en = ce_8m;
assign mcs48_0_i.int_n   = ~mcu_irq;
assign mcs48_0_i.db      = latch2;
assign mcs48_0_i.pmem_d  = mcu_rom_d;
assign mcu_p1 = mcs48_0_o.p1;
assign mcu_p2 = mcs48_0_o.p2;
assign mcu_pa = mcs48_0_o.pmem_a;

/////////////////////////////  Filters  /////////////////////////////

// AY1 / AY2 (12D / 11D) channels: 1K -> 4066-switched 0.047u (bit 0) / 0.22u (bit 1) to GND -> 2.2K -> mixer bus
// (schematic p30; port B D1-D0 channel A, D3-D2 B, D5-D4 C). Cap sees (AY ~250 + 1K) || 2.2K = 797 ohm
// (MAME uses 1356, unloaded). One-pole IIR at 1.789772 MHz / 8, Q16.
function automatic [15:0] flt_k(input [1:0] s);
    case (s)
        2'd1:    flt_k = 16'd7371;      // 0.047u, 4.2 kHz
        2'd2:    flt_k = 16'd1649;      // 0.22u, 910 Hz
        2'd3:    flt_k = 16'd1362;      // 0.267u
        default: flt_k = 16'd0;
    endcase
endfunction

logic [3:0] fdiv = 4'd0;
logic       f_ce = 1'b0;
always_ff @(posedge clk) begin
    f_ce <= 1'b0;
    if (ce_snd) begin
        fdiv <= fdiv + 4'd1;
        f_ce <= (fdiv == 4'd15);                // 3.579545 MHz / 16 = 223.7 kHz
    end
end

// channels 0-2 = AY1 A/B/C, 3-5 = AY2 A/B/C; one channel per clock after each filter tick
logic [23:0] ch_mem[6];                           // 8.16 fixed point
logic  [2:0] fch = 3'd6;
logic  [7:0] f_in;
logic  [1:0] f_sel;

always_comb begin
    case (fch)
        3'd0: begin f_in = ay_a[0]; f_sel = ay1_pb[1:0]; end
        3'd1: begin f_in = ay_b[0]; f_sel = ay1_pb[3:2]; end
        3'd2: begin f_in = ay_c[0]; f_sel = ay1_pb[5:4]; end
        3'd3: begin f_in = ay_a[1]; f_sel = ay2_pb[1:0]; end
        3'd4: begin f_in = ay_b[1]; f_sel = ay2_pb[3:2]; end
        default: begin f_in = ay_c[1]; f_sel = ay2_pb[5:4]; end
    endcase
end

wire        [23:0] f_mem  = ch_mem[(fch > 3'd5) ? 3'd5 : fch];
wire signed [24:0] f_diff = $signed({1'b0, f_in, 16'd0}) - $signed({1'b0, f_mem});
wire signed [41:0] f_prod = f_diff * $signed({1'b0, flt_k(f_sel)});
wire        [23:0] f_next = f_mem + f_prod[39:16];

always_ff @(posedge clk) begin
    if (f_ce) fch <= 3'd0;
    else if (fch != 3'd6) begin
        ch_mem[fch] <= (f_sel == 2'd0) ? {f_in, 16'd0} : f_next;
        fch <= fch + 3'd1;
    end
end

/////////////////////////////  Mix  /////////////////////////////

// Mixer bus into the 200 ohm volume pot, so weights = 1/R (schematic p30). AY channels: filtered 1K + 2.2K vs
// unfiltered 3.3K -> equal, 1 per count. DAC: R-2R -> follower -> 4.7K, ~4 V full scale vs an AY channel's
// ~1.41 V into ~3.5K -> 2.1x per full scale -> 2 per count.
function automatic [9:0] sum3(input [7:0] x, input [7:0] y, input [7:0] z);
    sum3 = {2'b00, x} + {2'b00, y} + {2'b00, z};
endfunction

logic [12:0] mix_r, mix_l;
always_ff @(posedge clk) begin
    mix_r <= {3'd0, sum3(ch_mem[0][23:16], ch_mem[1][23:16], ch_mem[2][23:16])} +
             {3'd0, sum3(ay_a[2], ay_b[2], ay_c[2])} + {3'd0, sum3(ay_a[3], ay_b[3], ay_c[3])};
    mix_l <= {3'd0, sum3(ch_mem[3][23:16], ch_mem[4][23:16], ch_mem[5][23:16])} +
             {3'd0, sum3(ay_a[4], ay_b[4], ay_c[4])} + 13'd2 * {5'd0, mcu_p1};
end

// Per side: one-pole ~8 kHz (mixer feedback 200 ohm / 0.1u, MAME konami_*_mixer_desc), one-pole ~15 kHz
// (keeps AY ultrasonic tones out of the 48 kHz output), DC removal ~9 Hz, gain, saturate.
function automatic signed [15:0] sat16(input signed [24:0] v);
    sat16 = v > 25'sd32767 ? 16'sd32767 : v < -25'sd32768 ? -16'sd32768 : v[15:0];
endfunction

genvar si;
generate
    for (si = 0; si < 2; si = si + 1) begin : g_out
        logic [28:0] lpa = 29'd0, lpb = 29'd0, dc = 29'd0;     // 16 fraction bits
        wire  [12:0] mix_in = (si == 0) ? mix_r : mix_l;
        wire signed [29:0] da = $signed({1'b0, mix_in, 16'd0}) - $signed({1'b0, lpa});
        wire signed [29:0] db = $signed({1'b0, lpa}) - $signed({1'b0, lpb});
        wire signed [29:0] dd = $signed({1'b0, lpb}) - $signed({1'b0, dc});
        wire signed [29:0] ds = dd >>> 12;
        wire signed [46:0] pa = da * $signed(17'sd13188);
        wire signed [46:0] pb = db * $signed(17'sd22531);
        always_ff @(posedge clk) if (f_ce) begin
            lpa <= lpa + pa[44:16];
            lpb <= lpb + pb[44:16];
            dc  <= dc + ds[28:0];
        end
        // AC part x 44 per mix count: x 60 matched MAME's AC level (sim 2026-10-15) but clipped the start jingle
        // on the left (37 samples); x 44 keeps ~1.4x headroom over it
        wire signed [22:0] ac = $signed({2'b00, lpb[28:8]}) - $signed({2'b00, dc[28:8]});   // 8 fraction bits
        wire signed [29:0] am = ac * $signed(5'sd11);                 // |am| < 2^23 (mix <= 2295 x 256 x 11)
        wire signed [29:0] gs = am >>> 6;                             // signed wire: arithmetic shift; x 11/64 = x 44/256
        wire signed [24:0] g  = gs[24:0];
        if (si == 0) begin : g_r assign audio_r = sat16(g); end
        else         begin : g_l assign audio_l = sat16(g); end
    end
endgenerate

endmodule
