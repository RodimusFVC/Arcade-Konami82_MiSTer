//============================================================================
//
//  Konami Time Pilot '84 sound section
//  Copyright (C) 2026 Rodimus
//
//  Written from the Time Pilot '84 schematics and MAME tp84.cpp (Aaron Giles).
//  Z80 (14.31818 / 4), three SN76489A (14.31818 / 8), each through a switchable RC filter into one mix.
//
//  Z80 ROM 0000-1FFF in shared block 2, second port (ioctl 0x10000, rtl/konami82_board.sv)
//
//============================================================================

module tp84_sound
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,

    output logic [15:0] z80_rom_a,      // block 2 second port (0x10000 + a)
    input  logic  [7:0] z80_rom_d,

    input  logic  [7:0] latch,          // main CPU sound data (3A00)
    input  logic        irq_trig,       // main CPU SON (3800): interrupts the Z80

    output chip_pool_pkg::z80_i_t   z80_1_i,                 // shared sound Z80 (rtl/konami82_board.sv)
    input  chip_pool_pkg::z80_o_t   z80_1_o,
    output chip_pool_pkg::sn76489_i_t [2:0] sn76489_i,       // shared SN76489As (rtl/konami82_board.sv)
    input  chip_pool_pkg::sn76489_o_t [2:0] sn76489_o,
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
wire cs_lat = mem && a[15:13] == 3'b011;         // 6000 sound data
wire cs_tmr = mem && a[15:13] == 3'b100;         // 8000 timer
wire cs_flt = mem && a[15:13] == 3'b101;         // A000 filters (address bits)
wire cs_snd = mem && a[15:13] == 3'b110;         // C000-C004

assign z80_rom_a = {2'b00, a[13:0]};             // block 2 at 0x0000 (ioctl 0x10000)

logic [7:0] ram_d;
spram #(.ADDR_WIDTH(10)) ram
(
    .clk(clk), .addr(a[9:0]), .data(cpu_do), .we(cs_ram & ~wr_n), .q(ram_d)
);

// Timer: the Z80 clock / 1024 into a 4-bit counter on D3-D0 (MAME sh_timer_r)
logic [13:0] tcnt = 14'd0;
always_ff @(posedge clk) if (cpu_ce) tcnt <= tcnt + 14'd1;

always_comb begin
    if      (cs_rom) cpu_di = z80_rom_d;
    else if (cs_ram) cpu_di = ram_d;
    else if (cs_lat) cpu_di = latch;
    else if (cs_tmr) cpu_di = {4'b0000, tcnt[13:10]};
    else             cpu_di = 8'hFF;
end

/////////////////////////////  SN76489A x 3, filter switches  /////////////////////////////

// C000 stores the data, C001 / C003 / C004 write it to SN76489A E5 / E6 / E7 (C002 = E4, not fitted). A000-A1FF:
// filter caps from address bits: A3 / A4 E5 0.047u / 0.47u, A7 E6 0.47u, A8 E7 0.47u (A5 / A6 = E4)
logic [7:0] sn_data = 8'h00;
logic       f1a = 1'b0, f1b = 1'b0, f2 = 1'b0, f3 = 1'b0;
logic [2:0] sn_wr = 3'b000;
logic       wr_d = 1'b0;

always_ff @(posedge clk) begin
    wr_d  <= ~wr_n;
    sn_wr <= 3'b000;
    if (reset) begin
        sn_data <= 8'h00;
        f1a <= 1'b0; f1b <= 1'b0; f2 <= 1'b0; f3 <= 1'b0;
    end else if (~wr_n && ~wr_d) begin
        if (cs_flt) begin f1a <= a[3]; f1b <= a[4]; f2 <= a[7]; f3 <= a[8]; end
        if (cs_snd) begin
            case (a[2:0])
                3'd0: sn_data <= cpu_do;
                3'd1: sn_wr <= 3'b001;
                3'd3: sn_wr <= 3'b010;
                3'd4: sn_wr <= 3'b100;
                default: ;
            endcase
        end
    end
end

logic signed [10:0] sn_snd[3];

// The three SN76489As: the shared jt89s in rtl/konami82_board.sv
genvar gi;
generate
    for (gi = 0; gi < 3; gi = gi + 1) begin : g_sn
        assign sn76489_i[gi].rst  = reset;
        assign sn76489_i[gi].ce   = sn_ce;
        assign sn76489_i[gi].wr_n = ~sn_wr[gi];
        assign sn76489_i[gi].cs_n = ~sn_wr[gi];
        assign sn76489_i[gi].din  = sn_data;
        assign sn_snd[gi] = sn76489_o[gi].sound;
    end
endgenerate

/////////////////////////////  Filters / mix  /////////////////////////////

// Per chip: 1K into a switched cap to GND, then 2.2K onto the bus; the cap sees 748 ohm (schematic; MAME 762).
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

wire [15:0] k1 = {f1b, f1a} == 2'd1 ? 16'd7829 :      // 0.047u, 4.53 kHz
                 {f1b, f1a} == 2'd2 ? 16'd828  :      // 0.47u, 453 Hz
                 {f1b, f1a} == 2'd3 ? 16'd754  :      // 0.517u, 412 Hz
                                      16'd0;
wire [15:0] k2 = f2 ? 16'd828 : 16'd0;
wire [15:0] k3 = f3 ? 16'd828 : 16'd0;

wire signed [13:0] in1 = 14'(sn_snd[0]) <<< 1;
wire signed [13:0] in2 = 14'(sn_snd[1]) <<< 1;
wire signed [13:0] in3 = 14'(sn_snd[2]) <<< 1;

logic signed [29:0] y1 = 30'sd0, y2 = 30'sd0, y3 = 30'sd0;      // 16 fraction bits

function automatic signed [29:0] rc(input signed [13:0] x, input signed [29:0] y, input [15:0] k);
    logic signed [30:0] d;
    logic signed [47:0] p;
    d = $signed({x, 16'd0}) - y;
    p = d * $signed({1'b0, k});
    rc = (k == 16'd0) ? $signed({x, 16'd0}) : y + 30'(p >>> 16);
endfunction

always_ff @(posedge clk) begin
    if (f_ce) begin
        y1 <= rc(in1, y1, k1);
        y2 <= rc(in2, y2, k2);
        y3 <= rc(in3, y3, k3);
    end
end

// 0.1u on the 1K volume pot wiper: one-pole 2.59 kHz (k 4598); DC removal ~3.4 Hz (>>> 14); gain, saturate.
// The schematic shows E7 (C004) on an amplifier marked "no layout parts"; MAME mixes all three, as here (#unverified).
wire signed [31:0] mix = 32'(y1) + 32'(y2) + 32'(y3);
logic signed [31:0] lp = 32'sd0, dc = 32'sd0;
wire signed [32:0] lp_d = 33'(mix) - 33'(lp);
wire signed [49:0] lp_p = lp_d * $signed(17'sd4598);

always_ff @(posedge clk) begin
    if (f_ce) begin
        lp <= lp + 32'(lp_p >>> 16);
        dc <= dc + ((lp - dc) >>> 14);
    end
end

wire signed [31:0] ac = (lp - dc) >>> 13;                      // level matched to MAME in sim (2026-10-17)
assign audio = ac > 32'sd32767 ? 16'sd32767 : ac < -32'sd32768 ? -16'sd32768 : ac[15:0];

endmodule
