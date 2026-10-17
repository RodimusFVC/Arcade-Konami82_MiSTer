//============================================================================
//
//  Konami Juno First sound board
//  Copyright (C) 2026 Rodimus
//
//  Written from MAME junofrst.cpp (Chris Hardy). Z80 + AY-3-8910 at 14.31818 / 8 with a switchable RC
//  filter per channel (AY port B), and an 8039 at 8 MHz playing samples into an 8-bit R2R DAC on P1.
//  The Z80 passes commands to the 8039 through a second latch and interrupts it; the 8039 reports 3 status
//  bits on P2 (read back on AY port A with a /512 timer) and drops P2.7 to clear its interrupt.
//  8039 = T48 (Arnim Laeuger) through t8039_notri_extrom, program ROM on the pmem port (EA low).
//
//  ioctl index 0 (MRA):
//    0x20000 - 0x20FFF  audiocpu
//    0x21000 - 0x21FFF  mcu
//
//============================================================================

module junofrst_sound
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    input  logic  [7:0] latch,          // main CPU sound command (8050)
    input  logic        irq_trig,       // main CPU 8040 D0: rising edge interrupts the Z80
    input  logic        mute,           // main latch Q3 MUT -> LA4460 pin 6 DC mute (schematic p14 / p18)

    output chip_pool_pkg::z80_i_t   z80_1_i,           // shared sound Z80 (rtl/konami82_board.sv)
    input  chip_pool_pkg::z80_o_t   z80_1_o,
    output chip_pool_pkg::ay_i_t  [0:0] ay_i,      // shared AYs (rtl/konami82_board.sv)
    input  chip_pool_pkg::ay_o_t  [0:0] ay_o,
    output chip_pool_pkg::mcs48_i_t mcs48_0_i,          // shared 8039 (rtl/konami82_board.sv)
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,
    output logic signed [15:0] audio
);

wire load_z80 = ioctl_wr0 && ioctl_addr[24:12] == 13'h0020;    // 0x20000-0x20FFF
wire load_mcu = ioctl_wr0 && ioctl_addr[24:12] == 13'h0021;    // 0x21000-0x21FFF

// 14.31818 MHz / 8 = 1.789772 MHz from 49.152 MHz, exact on average
logic [25:0] acc = 26'd0;
logic        ce_snd = 1'b0;
always_ff @(posedge clk) begin
    if (acc >= 26'd49152000 - 26'd1789773) begin
        acc    <= acc + 26'd1789773 - 26'd49152000;
        ce_snd <= 1'b1;
    end else begin
        acc    <= acc + 26'd1789773;
        ce_snd <= 1'b0;
    end
end

wire cpu_ce = ce_snd & ~pause;

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

// Interrupt (IM 1): set on the trigger's rising edge, held until the CPU acknowledges it
logic trig_d = 1'b0;
always_ff @(posedge clk) begin
    trig_d <= irq_trig;
    if (reset)                     irq_ff <= 1'b0;
    else if (irq_trig & ~trig_d)   irq_ff <= 1'b1;
    else if (~m1_n & ~iorq_n)      irq_ff <= 1'b0;
end

wire mem     = ~mreq_n & rfsh_n;
wire cs_rom  = mem && a[15:12] == 4'h0;          // 0000-0FFF
wire cs_ram  = mem && a[15:10] == 6'b0010_00;    // 2000-23FF
wire cs_lat  = mem && a[15:12] == 4'h3;          // 3000 sound latch
wire cs_ay   = mem && a[15:12] == 4'h4;          // 4000 address, 4001 read, 4002 data
wire cs_lat2 = mem && a[15:12] == 4'h5;          // 5000 8039 command latch
wire cs_mirq = mem && a[15:12] == 4'h6;          // 6000 8039 interrupt

logic [7:0] rom_d, ram_d;
dpram_dc #(.widthad_a(12)) rom
(
    .clock_a(clk), .address_a(ioctl_addr[11:0]), .data_a(ioctl_dout), .wren_a(load_z80),
    .clock_b(clk), .address_b(a[11:0]), .q_b(rom_d)
);

spram #(.ADDR_WIDTH(10)) ram
(
    .clk(clk), .addr(a[9:0]), .data(cpu_do), .we(cs_ram & ~wr_n), .q(ram_d)
);

/////////////////////////////  AY-3-8910  /////////////////////////////

// Port A: timer (sound clock / 512, MAME portA_r) in D7-D4, 8039 status in D2-D0, D3 unconnected = 1 (schematic p14)
logic [12:0] tdiv = 13'd0;
always_ff @(posedge clk) if (cpu_ce) tdiv <= tdiv + 13'd1;

logic [2:0] mcu_status;

// bus: write address = BDIR+BC1 (4000), write data = BDIR (4002), read data = BC1 (4001)
wire ay_bdir = cs_ay & ~wr_n;
wire ay_bc1  = cs_ay & ((~wr_n & ~a[1]) | ~rd_n);

logic [7:0] ay_do, ay_pb;
logic [7:0] ay_a, ay_b, ay_c;

// AY: shared AY in rtl/konami82_board.sv
assign ay_i[0].ce     = cpu_ce;
assign ay_i[0].bdir   = ay_bdir;
assign ay_i[0].bc1    = ay_bc1;
assign ay_i[0].din    = cpu_do;
assign ay_i[0].ioa_in = {tdiv[12:9], 1'b1, mcu_status};
assign ay_i[0].iob_in = 8'hFF;
assign ay_do = ay_o[0].dout;
assign ay_a = ay_o[0].a;
assign ay_b = ay_o[0].b;
assign ay_c = ay_o[0].c;
assign ay_pb = ay_o[0].iob_out;

always_comb begin
    if      (cs_rom)       cpu_di = rom_d;
    else if (cs_ram)       cpu_di = ram_d;
    else if (cs_lat)       cpu_di = latch;
    else if (cs_ay & a[0]) cpu_di = ay_do;
    else                   cpu_di = 8'hFF;
end

/////////////////////////////  8039  /////////////////////////////

logic [7:0] latch2 = 8'h00;
logic       mcu_irq = 1'b0;
logic [7:0] mcu_p1, mcu_p2, mcu_rom_d;
logic [11:0] mcu_pa;
logic       mcu_rd_n;
logic       wr_d = 1'b0;

always_ff @(posedge clk) begin
    wr_d <= ~wr_n;
    if (reset) begin
        latch2  <= 8'h00;
        mcu_irq <= 1'b0;
    end else begin
        if (~wr_n & ~wr_d & cs_lat2) latch2 <= cpu_do;
        // P2.7 low clears (and holds off) the interrupt (MAME i8039_irqen_and_status_w; level #unverified)
        if (~mcu_p2[7])                    mcu_irq <= 1'b0;
        else if (~wr_n & ~wr_d & cs_mirq)  mcu_irq <= 1'b1;
    end
end

assign mcu_status = mcu_p2[6:4];

dpram_dc #(.widthad_a(12)) mcu_rom
(
    .clock_a(clk), .address_a(ioctl_addr[11:0]), .data_a(ioctl_dout), .wren_a(load_mcu),
    .clock_b(clk), .address_b(mcu_pa), .q_b(mcu_rom_d)
);

// 8039: the shared 8039 in rtl/konami82_board.sv
assign mcs48_0_i.xtal_en = ce_8m;
assign mcs48_0_i.int_n   = ~mcu_irq;
assign mcs48_0_i.db      = latch2;
assign mcs48_0_i.pmem_d  = mcu_rom_d;
assign mcu_p1 = mcs48_0_o.p1;
assign mcu_p2 = mcs48_0_o.p2;
assign mcu_pa = mcs48_0_o.pmem_a;
assign mcu_rd_n = mcs48_0_o.rd_n;

/////////////////////////////  Filters  /////////////////////////////

// Each AY channel: 1K -> 4066-switched 0.047u (bit 0) / 0.22u (bit 1) to GND -> 2.2K -> AMP1 -> 200 ohm pot
// (schematic p14). Cap sees (AY ~250 + 1K) || (2.2K + 200) = 822 ohm (MAME LOWPASS_3R uses 706).
// One-pole IIR at 1.789772 MHz / 8; k = 1 - exp(-1 / (R * C * fs)), Q16. No cap = straight through.
// Port B: D1-D0 channel A, D3-D2 B, D5-D4 C.
function automatic [15:0] flt_k(input [1:0] s);
    case (s)
        2'd1:    flt_k = 16'd7161;      // 0.047u, 4.1 kHz
        2'd2:    flt_k = 16'd1600;      // 0.22u, 880 Hz
        2'd3:    flt_k = 16'd1321;      // 0.267u
        default: flt_k = 16'd0;
    endcase
endfunction

logic [2:0] fdiv = 3'd0;
logic       f_ce = 1'b0;
always_ff @(posedge clk) begin
    f_ce <= 1'b0;
    if (ce_snd) begin
        fdiv <= fdiv + 3'd1;
        f_ce <= (fdiv == 3'd7);
    end
end

logic [23:0] ch_mem[3];                           // 8.16 fixed point
logic  [1:0] fch = 2'd3;
logic  [7:0] f_in;
logic  [1:0] f_sel;

always_comb begin
    case (fch)
        2'd0:    begin f_in = ay_a; f_sel = ay_pb[1:0]; end
        2'd1:    begin f_in = ay_b; f_sel = ay_pb[3:2]; end
        default: begin f_in = ay_c; f_sel = ay_pb[5:4]; end
    endcase
end

wire        [23:0] f_mem  = ch_mem[(fch > 2'd2) ? 2'd2 : fch];
wire signed [24:0] f_diff = $signed({1'b0, f_in, 16'd0}) - $signed({1'b0, f_mem});
wire signed [41:0] f_prod = f_diff * $signed({1'b0, flt_k(f_sel)});
wire        [23:0] f_next = f_mem + f_prod[39:16];

always_ff @(posedge clk) begin
    if (f_ce) fch <= 2'd0;
    else if (fch != 2'd3) begin
        ch_mem[fch] <= (f_sel == 2'd0) ? {f_in, 16'd0} : f_next;
        fch <= fch + 2'd1;
    end
end

/////////////////////////////  Mix  /////////////////////////////

// AY channel = MAME legacy swing 0.5 x 0.30 = 0.15 / 255 -> 3 per count (one mix count = 0.05 / 255). DAC 6 per count:
// measured against MAME with the other source muted (sim DAC-only AC level was a steady 1.67x MAME at weight 10,
// 2026-10-15), not the 10 its nominal -1..+1 x 0.25 gives.
logic [12:0] mix;
always_ff @(posedge clk)
    mix <= 13'd3 * ({5'd0, ch_mem[0][23:16]} + {5'd0, ch_mem[1][23:16]} + {5'd0, ch_mem[2][23:16]}) +
           13'd6 * {5'd0, mcu_p1};

// Audio-band limit: two one-pole low-passes at ~15 kHz at the filter rate (k = 0.344, Q16). In play the game runs
// AY channel C at tone period 0 (111.9 kHz carrier under the envelope); the amplifier never passes it, and MAME's
// resampler removes it. Unfiltered it aliased into the 48 kHz output (15.86 kHz line, sim 2026-10-15).
logic [28:0] lp1 = 29'd0, lp2 = 29'd0;                         // mix, 16 fraction bits
wire  signed [29:0] lp1_d = $signed({1'b0, mix, 16'd0}) - $signed({1'b0, lp1});
wire  signed [29:0] lp2_d = $signed({1'b0, lp1}) - $signed({1'b0, lp2});
wire  signed [46:0] lp1_p = lp1_d * $signed(17'sd22564);
wire  signed [46:0] lp2_p = lp2_d * $signed(17'sd22564);
always_ff @(posedge clk) if (f_ce) begin
    lp1 <= lp1 + lp1_p[44:16];
    lp2 <= lp2 + lp2_p[44:16];
end

// Unipolar sources; coupling capacitors remove the DC. One-pole DC tracker at the filter rate, ~9 Hz corner.
logic [28:0] dc_avg = 29'd0;                                    // mix, 16 fraction bits
wire  signed [29:0] dc_diff = $signed({1'b0, lp2}) - $signed({1'b0, dc_avg});
wire  signed [29:0] dc_step = dc_diff >>> 12;
always_ff @(posedge clk) if (f_ce) dc_avg <= dc_avg + dc_step[28:0];

// AC part x 10.67 (one mix count = 0.05/255 of MAME full scale; Time Pilot board is x128 per 0.6/255), saturating
wire signed [22:0] ac      = $signed({2'b00, lp2[28:8]}) - $signed({2'b00, dc_avg[28:8]});     // 8 fraction bits
wire signed [32:0] ac_g    = ac * $signed(11'sd683);                                            // x 683/64 after >>14
wire signed [18:0] ac_s    = ac_g[32:14];
assign audio = mute ? 16'sd0 : ac_s > 19'sd32767 ? 16'sd32767 : ac_s < -19'sd32768 ? -16'sd32768 : ac_s[15:0];

endmodule
