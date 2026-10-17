//============================================================================
//
//  Konami Time Pilot sound board (also Pooyan, Roc'n Rope, Tutankham)
//  Copyright (C) 2026 Rodimus
//
//  Written from the Time Pilot sound schematic and MAME timeplt_a.cpp (Nicola Salmoria).
//  Z80 + 2x AY-3-8910 at 14.31818 / 8, LS90 timer on AY1 port B, switchable RC filter per channel.
//  Chance Kun adds a TC8830F voice chip on AY2 port A (MAME chkun_state::sound_w).
//
//============================================================================

module timeplt_sound
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr,       // sound ROM download strobe

    input  logic  [7:0] latch,          // main CPU sound command
    input  logic        irq_trig,       // main latch bit: rising edge interrupts the sound CPU
    input  logic        mute,           // LA4460 DC mute

    input  logic        tc_en,          // Chance Kun: TC8830F fitted
    output logic        tc_rom_req,     // TC8830F sample ROM (SDRAM), held until !tc_rom_busy
    output logic [16:0] tc_rom_addr,
    input  logic  [7:0] tc_rom_data,
    input  logic        tc_rom_busy,

    output chip_pool_pkg::z80_i_t   z80_1_i,           // shared sound Z80 (rtl/konami82_board.sv)
    input  chip_pool_pkg::z80_o_t   z80_1_o,
    output chip_pool_pkg::ay_i_t  [1:0] ay_i,      // shared AYs (rtl/konami82_board.sv)
    input  chip_pool_pkg::ay_o_t  [1:0] ay_o,
    output logic signed [15:0] audio
);

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

// Interrupt: set on the trigger's rising edge, held until the CPU acknowledges it
logic trig_d = 1'b0;
always_ff @(posedge clk) begin
    trig_d <= irq_trig;
    if (reset)                     irq_ff <= 1'b0;
    else if (irq_trig & ~trig_d)   irq_ff <= 1'b1;
    else if (~m1_n & ~iorq_n)      irq_ff <= 1'b0;
end

wire mem    = ~mreq_n & rfsh_n;
wire cs_rom = mem && a[15:12] < 4'h3;            // 0000-2FFF
wire cs_ram = mem && a[15:12] == 4'h3;           // 3000-33FF, mirrored to 3FFF
wire cs_ay1 = mem && a[15:13] == 3'b010;         // 4000 data, 5000 address
wire cs_ay2 = mem && a[15:13] == 3'b011;         // 6000 data, 7000 address
wire cs_flt = mem && a[15];                      // 8000-FFFF: filter select = address lines

logic [7:0] rom_d, ram_d;
dpram_dc #(.widthad_a(14)) rom
(
    .clock_a(clk), .address_a(ioctl_addr[13:0]), .data_a(ioctl_dout), .wren_a(ioctl_wr),
    .clock_b(clk), .address_b(a[13:0]), .q_b(rom_d)
);

spram #(.ADDR_WIDTH(10)) ram
(
    .clk(clk), .addr(a[9:0]), .data(cpu_do), .we(cs_ram & ~wr_n), .q(ram_d)
);

/////////////////////////////  AY-3-8910 x 2  /////////////////////////////

// LS90 timer on AY1 port B: sound clock / 512, then a bi-quinary / 10 (MAME timeplt_timer[] sequence)
logic [8:0] tdiv = 9'd0;
logic [3:0] tseq = 4'd0;
always_ff @(posedge clk) begin
    if (cpu_ce) begin
        tdiv <= tdiv + 9'd1;
        if (tdiv == 9'd511) tseq <= (tseq == 4'd9) ? 4'd0 : tseq + 4'd1;
    end
end

logic [7:0] timer;
always_comb begin
    case (tseq)
        4'd0: timer = 8'h00;  4'd1: timer = 8'h10;  4'd2: timer = 8'h20;  4'd3: timer = 8'h30;
        4'd4: timer = 8'h40;  4'd5: timer = 8'h90;  4'd6: timer = 8'hA0;  4'd7: timer = 8'hB0;
        4'd8: timer = 8'hA0;  default: timer = 8'hD0;
    endcase
end

// bus: write address = BDIR+BC1, write data = BDIR, read data = BC1
wire ay1_bdir = cs_ay1 & ~wr_n;
wire ay1_bc1  = cs_ay1 & ((~wr_n & a[12]) | (~rd_n & ~a[12]));
wire ay2_bdir = cs_ay2 & ~wr_n;
wire ay2_bc1  = cs_ay2 & ((~wr_n & a[12]) | (~rd_n & ~a[12]));

logic [7:0] ay1_do, ay2_do;
logic [7:0] ay1_a, ay1_b, ay1_c, ay2_a, ay2_b, ay2_c;

// AY1: shared AY in rtl/konami82_board.sv
assign ay_i[0].ce     = cpu_ce;
assign ay_i[0].bdir   = ay1_bdir;
assign ay_i[0].bc1    = ay1_bc1;
assign ay_i[0].din    = cpu_do;
assign ay_i[0].ioa_in = latch;
assign ay_i[0].iob_in = timer;
assign ay1_do = ay_o[0].dout;
assign ay1_a = ay_o[0].a;
assign ay1_b = ay_o[0].b;
assign ay1_c = ay_o[0].c;

// AY2: shared AY in rtl/konami82_board.sv
assign ay_i[1].ce     = cpu_ce;
assign ay_i[1].bdir   = ay2_bdir;
assign ay_i[1].bc1    = ay2_bc1;
assign ay_i[1].din    = cpu_do;
assign ay_i[1].ioa_in = 8'hFF;
assign ay_i[1].iob_in = 8'hFF;
assign ay2_do = ay_o[1].dout;
assign ay2_a = ay_o[1].a;
assign ay2_b = ay_o[1].b;
assign ay2_c = ay_o[1].c;

always_comb begin
    if      (cs_rom)          cpu_di = rom_d;
    else if (cs_ram)          cpu_di = ram_d;
    else if (cs_ay1 & ~a[12]) cpu_di = ay1_do;
    else if (cs_ay2 & ~a[12]) cpu_di = ay2_do;
    else                      cpu_di = 8'hFF;
end

/////////////////////////////  TC8830F (Chance Kun)  /////////////////////////////

// AY2 port A drives the chip: d0-d3 P0-P3, d6 /W, d4 /ACL. As MAME's AY8910, the port write handler runs on a
// register 14 write while port A is an output (R7 bit 6), and when R7 bit 6 changes (FF when it turns to input).
logic [3:0] ay2_reg = 4'd0;
logic [7:0] ay2_r7 = 8'd0, ay2_pa = 8'd0;
logic       ay2_wr_d = 1'b0;
logic       pa_wr = 1'b0;
logic [7:0] pa_val;
wire        ay2_wr = cs_ay2 & ~wr_n;

always_ff @(posedge clk) begin
    ay2_wr_d <= ay2_wr;
    pa_wr    <= 1'b0;
    if (reset) begin
        ay2_reg <= 4'd0; ay2_r7 <= 8'd0; ay2_pa <= 8'd0;
    end else if (ay2_wr && !ay2_wr_d) begin
        if (a[12]) ay2_reg <= cpu_do[3:0];                              // 7000: register address
        else if (ay2_reg == 4'd14) begin                                // 6000: data, port A
            ay2_pa <= cpu_do;
            if (ay2_r7[6]) begin pa_wr <= 1'b1; pa_val <= cpu_do; end
        end
        else if (ay2_reg == 4'd7) begin
            ay2_r7 <= cpu_do;
            if (cpu_do[6] != ay2_r7[6]) begin pa_wr <= 1'b1; pa_val <= cpu_do[6] ? ay2_pa : 8'hFF; end
        end
    end
end

logic signed [15:0] tc_out;
tc8830f voice
(
    .clk(clk),
    .reset(reset | ~tc_en),
    .pause(pause),
    .p_wr(tc_en & pa_wr & ~pa_val[6]),
    .p_data(pa_val[3:0]),
    .acl(tc_en & pa_wr & ~pa_val[4]),
    .rom_req(tc_rom_req),
    .rom_addr(tc_rom_addr),
    .rom_data(tc_rom_data),
    .rom_busy(tc_rom_busy),
    .out(tc_out)
);

/////////////////////////////  Filters  /////////////////////////////

// Each channel: 1K into 0.22u (bit 0) and/or 0.047u (bit 1) to ground, 5.1K on to the mixer.
// One-pole IIR at 1.789772 MHz / 8; k = 1 - exp(-1 / (836R * C * fs)), Q16. No cap = straight through.
// Latch order (MAME filter_w): A1-A2 AY2 ch A, A3-A4 AY2 B, A5-A6 AY2 C, A7-A8 AY1 A, A9-A10 AY1 B, A11-A12 AY1 C
logic [11:0] flt_sel = 12'd0;
logic        wr_d = 1'b0;
always_ff @(posedge clk) begin
    wr_d <= ~wr_n;
    if (reset)                     flt_sel <= 12'd0;
    else if (cs_flt & ~wr_n & ~wr_d) flt_sel <= a[11:0];
end

function automatic [15:0] flt_k(input [1:0] s);
    case (s)
        2'd1:    flt_k = 16'd1573;      // 0.22u
        2'd2:    flt_k = 16'd7046;      // 0.047u
        2'd3:    flt_k = 16'd1299;      // 0.267u
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

// channels 0-2 = AY1 A/B/C, 3-5 = AY2 A/B/C; one channel per clock after each filter tick
logic [23:0] ch_mem[6];                           // 8.16 fixed point
logic  [2:0] fch = 3'd6;
logic  [7:0] f_in;
logic  [1:0] f_sel;

always_comb begin
    case (fch)
        3'd0: begin f_in = ay1_a; f_sel = flt_sel[7:6];   end
        3'd1: begin f_in = ay1_b; f_sel = flt_sel[9:8];   end
        3'd2: begin f_in = ay1_c; f_sel = flt_sel[11:10]; end
        3'd3: begin f_in = ay2_a; f_sel = flt_sel[1:0];   end
        3'd4: begin f_in = ay2_b; f_sel = flt_sel[3:2];   end
        default: begin f_in = ay2_c; f_sel = flt_sel[5:4]; end
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

// Equal-weight mix of the six channels (MAME 0.60 each); LA4460 mute zeroes the output
logic [10:0] mix;
always_ff @(posedge clk)
    mix <= {3'd0, ch_mem[0][23:16]} + {3'd0, ch_mem[1][23:16]} + {3'd0, ch_mem[2][23:16]} +
           {3'd0, ch_mem[3][23:16]} + {3'd0, ch_mem[4][23:16]} + {3'd0, ch_mem[5][23:16]};

// The AY outputs are unipolar; the board's coupling capacitors remove the DC. Without that, loud passages
// clip solid at x128 (seen in Chance Kun). One-pole DC tracker at the filter rate, ~9 Hz corner.
logic [26:0] dc_avg = 27'd0;                                    // mix, 16 fraction bits
wire  signed [27:0] dc_diff = $signed({1'b0, mix, 16'd0}) - $signed({1'b0, dc_avg});
wire  signed [27:0] dc_step = dc_diff >>> 12;
always_ff @(posedge clk) if (f_ce) dc_avg <= dc_avg + dc_step[26:0];

// x128 of the AC part (HW: x32 too quiet on Pooyan music, x128 "much better", user 2026-10-15), saturating.
// Chance Kun drives the AYs far harder (6-channel sum to ~800 vs ~45 on Pooyan) and clips at x128: x32 there.
wire signed [20:0] ay_ac    = $signed({2'b00, mix, 8'd0}) - $signed({2'b00, dc_avg[26:8]});   // 8 fraction bits
wire signed [19:0] ay_gain  = tc_en ? {{2{ay_ac[20]}}, ay_ac[20:3]} : ay_ac[20:1];
wire signed [15:0] ay_audio = ay_gain > 20'sd32767 ? 16'sd32767 : ay_gain < -20'sd32768 ? -16'sd32768 : ay_gain[15:0];

// TC8830F at 1/8. MAME's 1/16-equivalent balance (route 0.10, a guess: chkun is MACHINE_IMPERFECT_SOUND, no
// schematic) left the voice too quiet under the music on HW (user 2026-10-16). Peak 4096 + music peak ~25.6K fits.
// Each term in its own signed wire: a concatenation is unsigned, and one unsigned operand makes the whole
// expression unsigned, >>> included (a logical shift turned every negative voice sample into +16K spikes).
wire signed [17:0] ay_ext = {{2{ay_audio[15]}}, ay_audio};
wire signed [17:0] tc_ext = {{2{tc_out[15]}}, tc_out};
wire signed [17:0] tc_sh  = tc_ext >>> 3;
wire signed [17:0] tc_mix = ay_ext + tc_sh;
wire signed [15:0] all_audio = tc_mix > 18'sd32767 ? 16'sd32767 : tc_mix < -18'sd32768 ? -16'sd32768 : tc_mix[15:0];

assign audio = mute ? 16'sd0 : all_audio;

endmodule
