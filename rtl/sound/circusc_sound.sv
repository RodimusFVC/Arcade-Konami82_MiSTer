//============================================================================
//
//  Konami Circus Charlie sound board
//  Copyright (C) 2026 Rodimus
//
//  Written from the Circus Charlie schematics and MAME circusc.cpp (Nicola Salmoria, Chris Hardy, Couriersud).
//  Z80 (14.31818 / 4), two SN76489A (14.31818 / 8) written from a data latch, an 8-bit R-2R DAC, and three
//  switchable RC filters (one per source) into an op-amp mixer.
//
//  Z80 ROM 0000-3FFF in shared block 2, second port (ioctl 0x10000, rtl/konami82_board.sv)
//
//============================================================================

module circusc_sound
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,

    output logic [15:0] z80_rom_a,      // block 2 second port (0x10000 + a)
    input  logic  [7:0] z80_rom_d,

    input  logic  [7:0] latch,          // main CPU sound data (0800)
    input  logic        irq_trig,       // main CPU SOUND-ON (0C00): interrupts the Z80

    output chip_pool_pkg::z80r_i_t   z80_1_i,                 // shared sound Z80 (rtl/konami82_board.sv)
    input  chip_pool_pkg::z80r_o_t   z80_1_o,
    output chip_pool_pkg::sn76489_i_t [1:0] sn76489_i,       // shared SN76489As (rtl/konami82_board.sv)
    input  chip_pool_pkg::sn76489_o_t [1:0] sn76489_o,
    output logic signed [15:0] audio
);

// 14.31818 MHz / 4 = 3.579545 MHz from 49.152 MHz, exact on average; SN76489As on every other one
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

logic sn_ph = 1'b0;
always_ff @(posedge clk) if (ce_snd) sn_ph <= ~sn_ph;

wire cpu_ce = ce_snd & ~pause;
wire sn_ce  = ce_snd & sn_ph & ~pause;           // 1.789772 MHz

/////////////////////////////  Z80  /////////////////////////////

logic [15:0] a;
logic  [7:0] cpu_do, cpu_di;
logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
logic        irq_ff = 1'b0;

// Sound CPU: the shared T80 in rtl/konami82_board.sv
assign z80_1_i.reset_n = ~reset;              // core reset, or the board watchdog (rtl/konami82_board.sv)
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

// Interrupt (IM 1, MAME HOLD_LINE): set on the trigger, held until the CPU acknowledges it
logic trig_d = 1'b0;
always_ff @(posedge clk) begin
    trig_d <= irq_trig;
    if (reset)                     irq_ff <= 1'b0;
    else if (irq_trig & ~trig_d)   irq_ff <= 1'b1;
    else if (~m1_n & ~iorq_n)      irq_ff <= 1'b0;
end

wire mem    = ~mreq_n & rfsh_n;
wire cs_rom = mem && a[15:14] == 2'b00;          // 0000-3FFF
wire cs_ram = mem && a[15:13] == 3'b010;         // 4000-43FF, mirrored to 5FFF
wire cs_lat = mem && a[15:13] == 3'b011;         // 6000 CS0 sound data
wire cs_tmr = mem && a[15:13] == 3'b100;         // 8000 CS1 timer
wire cs_wr  = mem && a[15:13] == 3'b101;         // A000 CS2-CS6 by A2-A0

assign z80_rom_a = {2'b00, a[13:0]};             // block 2 at 0x0000 (ioctl 0x10000)

logic [7:0] ram_d;
spram #(.ADDR_WIDTH(10)) ram
(
    .clk(clk), .addr(a[9:0]), .data(cpu_do), .we(cs_ram & ~wr_n), .q(ram_d)
);

// Timer: the Z80 clock through ten /2 stages into a 4-bit counter on D4-D1 (MAME sh_timer_r)
logic [13:0] tcnt = 14'd0;
always_ff @(posedge clk) if (cpu_ce) tcnt <= tcnt + 14'd1;

always_comb begin
    if      (cs_rom) cpu_di = z80_rom_d;
    else if (cs_ram) cpu_di = ram_d;
    else if (cs_lat) cpu_di = latch;
    else if (cs_tmr) cpu_di = {3'b000, tcnt[13:10], 1'b0};
    else             cpu_di = 8'hFF;
end

/////////////////////////////  SN76489A x 2, DAC, filter switches  /////////////////////////////

// A000 CS2 data latch, A001 CS3 / A002 CS4 write the latch to SN76489A 1 / 2, A003 CS5 DAC,
// A004 CS6 filter switches from address bits: A5 SN1, A4-A3 SN2, A6 DAC
logic [7:0] sn_latch = 8'h00;
logic [7:0] dac = 8'h00;
logic       f_sn0 = 1'b0, f_dac = 1'b0;
logic [1:0] f_sn1 = 2'd0;
logic [1:0] sn_wr = 2'b00;
logic       wr_d = 1'b0;

always_ff @(posedge clk) begin
    wr_d  <= ~wr_n;
    sn_wr <= 2'b00;
    if (reset) begin
        sn_latch <= 8'h00;
        dac      <= 8'h00;
        f_sn0    <= 1'b0;
        f_sn1    <= 2'd0;
        f_dac    <= 1'b0;
    end else if (cs_wr && ~wr_n && ~wr_d) begin
        case (a[2:0])
            3'd0: sn_latch <= cpu_do;
            3'd1: sn_wr    <= 2'b01;
            3'd2: sn_wr    <= 2'b10;
            3'd3: dac      <= cpu_do;
            3'd4: begin f_sn0 <= a[5]; f_sn1 <= a[4:3]; f_dac <= a[6]; end
            default: ;
        endcase
    end
end

logic signed [10:0] sn_snd[2];

// The two SN76489As: the shared jt89s in rtl/konami82_board.sv
genvar gi;
generate
    for (gi = 0; gi < 2; gi = gi + 1) begin : g_sn
        assign sn76489_i[gi].rst  = reset;
        assign sn76489_i[gi].ce   = sn_ce;
        assign sn76489_i[gi].wr_n = ~sn_wr[gi];
        assign sn76489_i[gi].cs_n = ~sn_wr[gi];
        assign sn76489_i[gi].din  = sn_latch;
        assign sn_snd[gi] = sn76489_o[gi].sound;
    end
endgenerate

/////////////////////////////  Filters / mix  /////////////////////////////

// Per source 1K into a switched cap to GND (LS174 3G: A5 SN1 0.47u, A3 / A4 SN2 0.047u / 0.47u, A6 DAC 0.47u),
// then 2.2K / 2.2K / 10K onto the 1K volume pot with 0.1u on the bus, 0.47u to the LA4460 (schematic p2 = MAME).
// The caps see 1K || (2.2K + mixer) = 744 ohm (SN) / 914 ohm (DAC); MAME uses 1K unloaded.
// Weights per count: SN 2, DAC 9 (MAME source scale, jt89 = +-255 per channel; branch conductance 1/3.2K : 1/11K).
// One-pole IIRs at 3.579545 MHz / 16 = 223.7 kHz, k = 1 - exp(-2 pi fc / fs) in Q16.
logic [3:0] fdiv = 4'd0;
logic       f_ce = 1'b0;
always_ff @(posedge clk) begin
    f_ce <= 1'b0;
    if (ce_snd) begin
        fdiv <= fdiv + 4'd1;
        f_ce <= (fdiv == 4'd15);
    end
end

function automatic [15:0] k_sn1(input [1:0] s);
    case (s)
        2'd1:    k_sn1 = 16'd7863;      // 0.047u, 4.55 kHz
        2'd2:    k_sn1 = 16'd832;       // 0.47u, 455 Hz
        2'd3:    k_sn1 = 16'd757;       // 0.517u, 414 Hz
        default: k_sn1 = 16'd0;
    endcase
endfunction

wire signed [13:0] in0 = 14'(sn_snd[0]) <<< 1;
wire signed [13:0] in1 = 14'(sn_snd[1]) <<< 1;
wire signed [13:0] in2 = $signed({3'd0, dac, 3'd0}) + $signed({6'd0, dac});   // x 9

wire [15:0] k0 = f_sn0 ? 16'd832 : 16'd0;       // 455 Hz
wire [15:0] k1 = k_sn1(f_sn1);
wire [15:0] k2 = f_dac ? 16'd678 : 16'd0;       // 371 Hz

logic signed [29:0] y0 = 30'sd0, y1 = 30'sd0, y2 = 30'sd0;      // 16 fraction bits

function automatic signed [29:0] rc(input signed [13:0] x, input signed [29:0] y, input [15:0] k);
    logic signed [30:0] d;
    logic signed [47:0] p;
    d = $signed({x, 16'd0}) - y;
    p = d * $signed({1'b0, k});
    rc = (k == 16'd0) ? $signed({x, 16'd0}) : y + 30'(p >>> 16);
endfunction

always_ff @(posedge clk) begin
    if (f_ce) begin
        y0 <= rc(in0, y0, k0);
        y1 <= rc(in1, y1, k1);
        y2 <= rc(in2, y2, k2);
    end
end

// Bus 0.1u against 583 ohm: one-pole 2.73 kHz (k 4837); DC removal ~3.4 Hz (>>> 14); gain x 32, saturate
// (x 32 put the attract jingle at MAME's level in sim, 2026-10-16)
wire signed [31:0] mix = 32'(y0) + 32'(y1) + 32'(y2);
logic signed [31:0] lp = 32'sd0, dc = 32'sd0;
wire signed [32:0] lp_d = 33'(mix) - 33'(lp);
wire signed [49:0] lp_p = lp_d * $signed(17'sd4837);

always_ff @(posedge clk) begin
    if (f_ce) begin
        lp <= lp + 32'(lp_p >>> 16);
        dc <= dc + ((lp - dc) >>> 14);
    end
end

wire signed [31:0] ac = (lp - dc) >>> 11;                      // 5 fraction bits left: x 32
assign audio = ac > 32'sd32767 ? 16'sd32767 : ac < -32'sd32768 ? -16'sd32768 : ac[15:0];

endmodule
