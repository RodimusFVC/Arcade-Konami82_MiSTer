//============================================================================
//
//  Konami Gyruss board (CPU/video board; sound board in rtl/sound/gyruss_sound.sv)
//  Copyright (C) 2026 Rodimus
//
//  Written from the Gyruss schematics and MAME gyruss.cpp (Nicola Salmoria, Couriersud).
//  Z80 main CPU (tilemap, sound commands) + KONAMI-1 sub CPU (sprites), sharing 2K of RAM.
//  KONAMI-1 = Greg Miller's MC6809 (unmodified) + the external opcode decrypter used on Roc'n Rope.
//  32x32 2bpp tilemap (attr bit 4 = tile over sprites), 48 8x16 4bpp sprites, 396 x 256 timing.
//
//  ROM windows (banked ROM store, rtl/konami82_board.sv; PROMs load from index 0 at their window address):
//    0x00000 - 0x05FFF  maincpu 0000-5FFF        (block 0, port B)
//    0x06000 - 0x07FFF  sub E000-FFFF            (block 0, port A)
//    0x0C000 - 0x0DFFF  tiles                    (block 1, port B)
//    0x0E000 - 0x0EFFF  audio2 (8039)            (block 1, port A, sound board)
//    0x10000 - 0x17FFF  sprites                  (block 2, port B)
//    0x18000 - 0x1DFFF  audiocpu 0000-5FFF       (block 2, port A, sound board)
//    0x20000 - 0x2001F  palette PROM pr3   0x20020 - 0x2011F  sprite lookup pr1   0x20120 - 0x2021F  char lookup pr2
//
//============================================================================

module gyruss_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    output logic        ce_pix,

    input  logic  [7:0] in0,            // $C080 system
    input  logic  [7:0] in1,            // $C0A0 player 1
    input  logic  [7:0] in2,            // $C0C0 player 2
    input  logic  [7:0] dsw0,           // $C0E0 DSW1 (coinage)
    input  logic  [7:0] dsw1,           // $C000 DSW2
    input  logic  [7:0] dsw2,           // $C100 DSW3

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    output logic [14:0] rom0_a,         // banked ROM store (rtl/konami82_board.sv): main CPU
    input  logic  [7:0] rom0_d,
    output logic [14:0] rom0b_a,        //   sub CPU (block 0 second port)
    input  logic  [7:0] rom0b_d,
    output logic [13:0] rom1_a,         //   tiles
    input  logic  [7:0] rom1_d,
    output logic [15:0] rom2_a,         //   sprites
    input  logic  [7:0] rom2_d,

    input  logic        crt_flip,
    input  logic  [3:0] h_adj,          // HSYNC moved 2 pixels per step (signed)
    input  logic  [3:0] v_adj,          // VSYNC moved 1 line per step (signed)

    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank,

    output logic        wd_reset,       // watchdog reset to the sound board (conn 21)
    output logic  [7:0] snd_latch,      // to rtl/sound/gyruss_sound.sv
    output logic        snd_irq,

    output chip_pool_pkg::z80r_i_t   z80_0_i,          // shared Z80 (rtl/konami82_board.sv)
    input  chip_pool_pkg::z80r_o_t   z80_0_o,
    output chip_pool_pkg::m6809r_i_t m6809_0_i,          // shared MC6809E (rtl/konami82_board.sv)
    input  chip_pool_pkg::m6809r_o_t m6809_0_o,
    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

/////////////////////////////  PROMs  /////////////////////////////

wire load_prom = ioctl_wr0 && ioctl_addr[24:10] == 15'h0080;    // 0x20000-0x203FF
wire load_pal  = load_prom && ioctl_addr[9:5] == 5'd0;          // pr3
wire [9:0] lut_dl = ioctl_addr[9:0] - 10'h020;
wire load_lut  = load_prom && ioctl_addr[9:0] >= 10'h020 && ioctl_addr[9:0] < 10'h220;

// Lookup PROMs: 0x000-0x0FF sprites (pr1), 0x100-0x1FF chars (pr2); low nibble used
logic [8:0] lut_a;
logic [7:0] lut_d;
dpram_dc #(.widthad_a(9)) prom_lut
(
    .clock_a(clk), .address_a(lut_dl[8:0]), .data_a(ioctl_dout), .wren_a(load_lut),
    .clock_b(clk), .address_b(lut_a), .q_b(lut_d)
);

logic [4:0] pal_a;
logic [7:0] pal_d;
dpram_dc #(.widthad_a(5)) prom_pal
(
    .clock_a(clk), .address_a(ioctl_addr[4:0]), .data_a(ioctl_dout), .wren_a(load_pal),
    .clock_b(clk), .address_b(pal_a), .q_b(pal_d)
);

/////////////////////////////  Clocks  /////////////////////////////

// 18.432 MHz / 3 = 6.144 MHz pixel clock = 49.152 / 8; Z80 18.432 / 6 = 3.072 MHz = 49.152 / 16;
// 6809E E = 18.432 / 12 = 1.536 MHz = 49.152 / 32
logic [4:0] div = 5'd0;
always_ff @(posedge clk) div <= div + 5'd1;

assign ce_pix = (div[2:0] == 3'd7);
wire   cpu_ce = (div[3:0] == 4'd15) & ~pause;
wire   fall_q = (div == 5'd23) & ~pause;          // Q falls a quarter cycle before E
wire   fall_e = (div == 5'd31) & ~pause;

/////////////////////////////  Video timing  /////////////////////////////

// MAME: 396 x 256 at 6.144 MHz (PCB measured 15.50 kHz / 60.56 Hz), visible x 0-255, lines 16-239.
// H counts 116..511 (256..511 visible = x 0..255), V counts 0..255.
logic [8:0] hcnt = 9'd116;
logic [7:0] vcnt = 8'd0;

always_ff @(posedge clk) begin
    if (ce_pix) begin
        if (hcnt == 9'd511) begin
            hcnt <= 9'd116;
            vcnt <= vcnt + 8'd1;
        end else
            hcnt <= hcnt + 9'd1;
    end
end

wire [8:0] hs_on  = 9'd176 + {{4{h_adj[3]}}, h_adj, 1'b0};
wire [7:0] vs_beg = 8'd248 + {{4{v_adj[3]}}, v_adj};
wire [7:0] vs_dist = vcnt - vs_beg;

wire raw_hblank = ~hcnt[8];
wire raw_vblank = (vcnt < 8'd16) || (vcnt >= 8'd240);

// Watchdog (LS293 17J; MAME has none): counts frames at vblank end (frozen while paused), cleared by a main CPU C000
// write. QD (8 frames without a kick) holds the Z80, the KONAMI-1 sub, its IRQ mask and LS259 3C (and the sound
// board) in reset for 8 frames, then the count wraps (schematic). Video timing keeps running.
logic       wd_vb = 1'b0, wd_kick;
logic [3:0] wd_cnt = 4'd0;
always_ff @(posedge clk) begin
    if (ce_pix) wd_vb <= raw_vblank;
    if (reset || wd_kick)                              wd_cnt <= 4'd0;
    else if (ce_pix && !raw_vblank && wd_vb && !pause) wd_cnt <= wd_cnt + 4'd1;
end
wire wd_rst  = wd_cnt[3];
wire cpu_rst = reset | wd_rst;
wire raw_hs     = ~((hcnt >= hs_on) && (hcnt < hs_on + 9'd32));
wire raw_vs     = (vs_dist >= 8'd3);

// Main latch (LS259 3C): Q0 NMI enable, Q2/Q3 coin counters, Q5 flip screen
logic [7:0] mainlatch = 8'h00;
wire tflip = mainlatch[5] ^ crt_flip;           // MAME flips only the tilemap with the game's flip

/////////////////////////////  Main CPU (Z80)  /////////////////////////////

logic [15:0] cpu_a;
logic  [7:0] cpu_do, cpu_di;
logic        cpu_mreq_n, cpu_rd_n, cpu_wr_n, cpu_rfsh_n;
logic        nmi_ff = 1'b0;

// Main CPU: the shared T80 in rtl/konami82_board.sv
assign z80_0_i.reset_n = ~wd_rst;
assign z80_0_i.ce    = cpu_ce;
assign z80_0_i.int_n = 1'b1;
assign z80_0_i.nmi_n = ~nmi_ff;
assign z80_0_i.di    = cpu_di;
assign cpu_a = z80_0_o.a;
assign cpu_do = z80_0_o.dout;
assign cpu_mreq_n = z80_0_o.mreq_n;
assign cpu_rd_n = z80_0_o.rd_n;
assign cpu_wr_n = z80_0_o.wr_n;
assign cpu_rfsh_n = z80_0_o.rfsh_n;

wire mem     = ~cpu_mreq_n & cpu_rfsh_n;
wire cs_rom  = mem && cpu_a < 16'h6000;                         // 0000-5FFF (6000-7FFF diagnostics socket, empty)
wire cs_col  = mem && cpu_a[15:10] == 6'b1000_00;              // 8000-83FF
wire cs_vid  = mem && cpu_a[15:10] == 6'b1000_01;              // 8400-87FF
wire cs_ram  = mem && cpu_a[15:12] == 4'h9;                    // 9000-9FFF
wire cs_shr  = mem && cpu_a[15:11] == 5'b1010_0;               // A000-A7FF shared with the sub CPU
wire cs_io   = mem && cpu_a[15:12] == 4'hC;

assign rom0_a = cpu_a[14:0];

wire wr_strobe = ~cpu_wr_n;
logic wr_d = 1'b0;
always_ff @(posedge clk) wr_d <= wr_strobe;
wire wr_edge = wr_strobe & ~wr_d;

// Colour / video RAM: CPU on port A, tile fetch on port B
logic [9:0] tile_ram_a;
logic [7:0] col_cpu_d, vid_cpu_d, col_d, vid_d;

dpram_dc #(.widthad_a(10)) ram_col
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a(cpu_do), .wren_a(cs_col & wr_strobe), .q_a(col_cpu_d),
    .clock_b(clk), .address_b(tile_ram_a), .q_b(col_d)
);

dpram_dc #(.widthad_a(10)) ram_vid
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a(cpu_do), .wren_a(cs_vid & wr_strobe), .q_a(vid_cpu_d),
    .clock_b(clk), .address_b(tile_ram_a), .q_b(vid_d)
);

// Work RAM 9000-9FFF; second port for the hiscore system
logic [7:0] ram_cpu_d;
wire        hs_cs = hs_address[15:12] == 4'h9;
dpram_dc #(.widthad_a(12)) ram_work
(
    .clock_a(clk), .address_a(cpu_a[11:0]), .data_a(cpu_do), .wren_a(cs_ram & wr_strobe), .q_a(ram_cpu_d),
    .clock_b(clk), .address_b(hs_address[11:0]), .data_b(hs_data_in), .wren_b(hs_cs & hs_write), .q_b(hs_data_out)
);

// Shared RAM: main A000-A7FF on port A, sub 6000-67FF on port B
logic [15:0] sub_a;
logic  [7:0] sub_do;
logic        sub_rw;
logic  [7:0] shr_main_d, shr_sub_d;
wire         sub_cs_shr = sub_a[15:11] == 5'b0110_0;
wire         sub_wr     = fall_e & ~sub_rw;

dpram_dc #(.widthad_a(11)) ram_shared
(
    .clock_a(clk), .address_a(cpu_a[10:0]), .data_a(cpu_do), .wren_a(cs_shr & wr_strobe), .q_a(shr_main_d),
    .clock_b(clk), .address_b(sub_a[10:0]), .data_b(sub_do), .wren_b(sub_cs_shr & sub_wr), .q_b(shr_sub_d)
);

// I/O at C000-C1FF (A8-A5): C000 DSW2 / watchdog, C080 SYSTEM / sound IRQ, C0A0 P1, C0C0 P2, C0E0 DSW1,
// C100 DSW3 / sound latch, C180-C187 main latch
logic [7:0] io_d;
always_comb begin
    case (cpu_a[8:5])
        4'b0000: io_d = dsw1;
        4'b0100: io_d = in0;
        4'b0101: io_d = in1;
        4'b0110: io_d = in2;
        4'b0111: io_d = dsw0;
        4'b1000: io_d = dsw2;
        default: io_d = 8'hFF;
    endcase
end

always_comb begin
    if      (cs_rom) cpu_di = rom0_d;
    else if (cs_col) cpu_di = col_cpu_d;
    else if (cs_vid) cpu_di = vid_cpu_d;
    else if (cs_ram) cpu_di = ram_cpu_d;
    else if (cs_shr) cpu_di = shr_main_d;
    else if (cs_io)  cpu_di = io_d;
    else             cpu_di = 8'hFF;
end

logic [7:0] sound_latch = 8'h00;
logic [5:0] snd_pulse = 6'd0;

assign wd_kick  = cs_io && wr_edge && cpu_a[8:7] == 2'b00;
assign wd_reset = wd_rst;

always_ff @(posedge clk) begin
    if (snd_pulse != 6'd0) snd_pulse <= snd_pulse - 6'd1;
    if (cpu_rst) begin
        mainlatch <= 8'h00;
        snd_pulse <= 6'd0;
    end else if (cs_io && wr_edge) begin
        if (cpu_a[8:7] == 2'b01) snd_pulse <= 6'd63;                // C080: interrupt the sound CPU
        if (cpu_a[8:7] == 2'b10) sound_latch <= cpu_do;             // C100
        if (cpu_a[8:7] == 2'b11) mainlatch[cpu_a[2:0]] <= cpu_do[0];   // C180-C187
    end
end

// NMI at vblank start (line 240) while enabled; clearing the enable releases it
wire vblank_start = ce_pix && hcnt == 9'd116 && vcnt == 8'd240;
always_ff @(posedge clk) begin
    if (cpu_rst)                   nmi_ff <= 1'b0;
    else if (!mainlatch[0])        nmi_ff <= 1'b0;
    else if (vblank_start)         nmi_ff <= 1'b1;
end

/////////////////////////////  Sub CPU (KONAMI-1)  /////////////////////////////

logic  [7:0] sub_di, sub_bus;
logic        sub_lic;
logic        sub_irq = 1'b0, sub_irq_en = 1'b0;

// Sub CPU (KONAMI-1): the shared MC6809E in rtl/konami82_board.sv
assign m6809_0_i.reset_n = ~wd_rst;
assign m6809_0_i.fall_e = fall_e;
assign m6809_0_i.fall_q = fall_q;
assign m6809_0_i.irq_n  = ~sub_irq;
assign m6809_0_i.firq_n = 1'b1;
assign m6809_0_i.nmi_n  = 1'b1;
assign m6809_0_i.d      = sub_di;
assign sub_a = m6809_0_o.a;
assign sub_do = m6809_0_o.dout;
assign sub_rw = m6809_0_o.rw;
assign sub_lic = m6809_0_o.lic;

// Opcode fetch = the bus cycle after LIC (instruction byte 1), or the byte after a $10/$11 page prefix.
// The reset and interrupt vector reads also follow LIC; they sit at FFF0-FFFF, where no code runs.
logic lic_q = 1'b0, pfx_q = 1'b0;
wire  op_fetch = (lic_q && sub_a[15:4] != 12'hFFF) || pfx_q;

function automatic [7:0] k1_key(input [15:0] a);
    case ({a[3], a[1]})
        2'b00: k1_key = 8'h22;
        2'b01: k1_key = 8'h82;
        2'b10: k1_key = 8'h28;
        2'b11: k1_key = 8'h88;
    endcase
endfunction

assign sub_di = op_fetch ? sub_bus ^ k1_key(sub_a) : sub_bus;

always_ff @(posedge clk) begin
    if (cpu_rst) begin
        lic_q <= 1'b0;
        pfx_q <= 1'b0;
    end else if (fall_e) begin
        lic_q <= sub_lic;
        pfx_q <= op_fetch && (sub_di == 8'h10 || sub_di == 8'h11);
    end
end

wire sub_cs_scan = sub_a[15:13] == 3'b000;                      // 0000 scanline (1V-128V)
wire sub_cs_irq  = sub_a[15:13] == 3'b001;                      // 2000 IRQ enable
wire sub_cs_ram  = sub_a[15:11] == 5'b0100_0;                   // 4000-47FF (sprites at 4040-40FF)
wire sub_cs_rom  = sub_a[15:13] == 3'b111;                      // E000-FFFF

assign rom0b_a = {2'b11, sub_a[12:0]};                          // block 0 at 0x6000

// Sub RAM 4000-47FF: CPU on port A, sprite engine on port B
logic [10:0] spr_ram_a;
logic  [7:0] sub_ram_d, spr_d;
dpram_dc #(.widthad_a(11)) ram_sub
(
    .clock_a(clk), .address_a(sub_a[10:0]), .data_a(sub_do), .wren_a(sub_cs_ram & sub_wr), .q_a(sub_ram_d),
    .clock_b(clk), .address_b(spr_ram_a), .q_b(spr_d)
);

always_comb begin
    if      (sub_cs_scan) sub_bus = vcnt;
    else if (sub_cs_ram)  sub_bus = sub_ram_d;
    else if (sub_cs_shr)  sub_bus = shr_sub_d;
    else if (sub_cs_rom)  sub_bus = rom0b_d;
    else                  sub_bus = 8'hFF;
end

// IRQ at vblank start while enabled (2000 D0), held until the enable is cleared
always_ff @(posedge clk) begin
    if (cpu_rst) begin
        sub_irq_en <= 1'b0;
        sub_irq    <= 1'b0;
    end else begin
        if (sub_cs_irq & sub_wr) sub_irq_en <= sub_do[0];
        if (!sub_irq_en)         sub_irq <= 1'b0;
        else if (vblank_start)   sub_irq <= 1'b1;
    end
end

/////////////////////////////  Tile layer  /////////////////////////////

// The next column is fetched while the current one is shown; its data takes over on the last pixel of a column
logic [7:0] fetch_x;
logic [7:0] fetch_y;
logic [3:0] fetch_st = 4'd0;
logic [7:0] nxt_attr, nxt_d0, nxt_d1, cur_attr, cur_d0, cur_d1;
logic [8:0] nxt_code;
logic [2:0] nxt_row;
logic [12:0] tile_rom_a;

assign rom1_a = {1'b0, tile_rom_a};

always_ff @(posedge clk) begin
    if (ce_pix && hcnt[2:0] == 3'd0) begin
        fetch_x  <= (hcnt[7:0] + 8'd8) ^ {8{tflip}};
        fetch_y  <= vcnt ^ {8{tflip}};
        fetch_st <= 4'd1;
    end else begin
        case (fetch_st)
            4'd1: begin tile_ram_a <= {fetch_y[7:3], fetch_x[7:3]}; fetch_st <= 4'd2; end
            4'd2: fetch_st <= 4'd3;
            4'd3: begin
                nxt_attr <= col_d;
                nxt_code <= {col_d[5], vid_d};
                nxt_row  <= fetch_y[2:0] ^ {3{col_d[7]}};               // attr bit 7 = Y flip
                fetch_st <= 4'd4;
            end
            4'd4: begin tile_rom_a <= {nxt_code, 1'b0, nxt_row}; fetch_st <= 4'd5; end
            4'd5: begin tile_rom_a <= {nxt_code, 1'b1, nxt_row}; fetch_st <= 4'd6; end
            4'd6: begin nxt_d0 <= rom1_d; fetch_st <= 4'd7; end
            4'd7: begin nxt_d1 <= rom1_d; fetch_st <= 4'd0; end
            default: fetch_st <= 4'd0;
        endcase
    end

    if (ce_pix && hcnt[2:0] == 3'd7) begin
        cur_attr <= nxt_attr;
        cur_d0   <= nxt_d0;
        cur_d1   <= nxt_d1;
    end
end

// Pixel within the tile: screen flip, then the tile's own X flip (attr bit 6); planes { 4, 0 }
wire [2:0] tpx   = hcnt[2:0] ^ {3{tflip}} ^ {3{cur_attr[6]}};
wire [7:0] tbyte = tpx[2] ? cur_d1 : cur_d0;
wire [1:0] tpen  = {tbyte[3 - tpx[1:0]], tbyte[7 - tpx[1:0]]};

/////////////////////////////  Sprites  /////////////////////////////

// Two line buffers of {colour[3:0], pen[3:0]}: one is shown (and cleared behind the beam) while the other is
// drawn with the next line. Buffer vcnt[0] is shown on line vcnt.
logic       rd_sel;
logic       sp_buf;
logic [7:0] lb_rd_a;
logic [7:0] lb_q0, lb_q1;
logic [7:0] lb_wr_a, lb_wr_d;
logic       lb_wr;
logic [7:0] clr_a;
logic       clr_wr;

wire clr0 = clr_wr & ~rd_sel, clr1 = clr_wr & rd_sel;
wire wr0  = lb_wr  & ~sp_buf, wr1  = lb_wr  & sp_buf;

dpram_dc #(.widthad_a(8)) lbuf0
(
    .clock_a(clk), .address_a(clr0 ? clr_a : lb_wr_a), .data_a(clr0 ? 8'h00 : lb_wr_d), .wren_a(clr0 | wr0),
    .clock_b(clk), .address_b(lb_rd_a), .q_b(lb_q0)
);

dpram_dc #(.widthad_a(8)) lbuf1
(
    .clock_a(clk), .address_a(clr1 ? clr_a : lb_wr_a), .data_a(clr1 ? 8'h00 : lb_wr_d), .wren_a(clr1 | wr1),
    .clock_b(clk), .address_b(lb_rd_a), .q_b(lb_q1)
);

wire [7:0] lb_q = rd_sel ? lb_q1 : lb_q0;

// MAME draw_sprites: offs 0xBC down to 0 (slots 47..0), later slots drawn over earlier ones.
// Per slot (sprite RAM 4040 + 4 x slot): +0 X, +1 code[6:0] / half select, +2 attr, +3 Y; sprite top = 241 - Y.
// 8x16, 4bpp: planes { 0x4000*8+4, 0x4000*8+0, 4, 0 }, row r at byte {r[3], half, xh, r[2:0]} of a 64-byte sprite.
typedef enum logic [3:0] { SP_IDLE, SP_Y0, SP_Y1, SP_Y2, SP_A0, SP_A1, SP_A2, SP_A3, SP_A4,
                           SP_R0, SP_R1, SP_R2, SP_R3, SP_PIX } sp_state_t;
sp_state_t  sp_st = SP_IDLE;
logic [5:0] sp_slot;
logic [7:0] sp_line;
logic [7:0] sp_x, sp_c1, sp_attr;
logic [3:0] sp_row;
logic       sp_xh;
logic [1:0] sp_k;
logic [7:0] sp_lo, sp_hi;
logic [13:0] sp_rom;

wire [7:0] sp_base = 8'h40 + {sp_slot, 2'b00};
wire [9:0] sp_dy   = {2'b00, sp_line} + {2'b00, spr_d} - 10'd241;   // line - (241 - Y)
wire [2:0] sp_srcx = {sp_xh, sp_k};
wire [2:0] sp_dx   = sp_attr[6] ? sp_srcx : ~sp_srcx;                // attr bit 6 clear = X flipped
wire [8:0] sp_px   = {1'b0, sp_x} + {6'd0, sp_dx};
wire [3:0] sp_pen  = {sp_hi[3 - sp_k], sp_hi[7 - sp_k], sp_lo[3 - sp_k], sp_lo[7 - sp_k]};

always_ff @(posedge clk) begin
    lb_wr <= 1'b0;
    case (sp_st)
        SP_IDLE: ;
        SP_Y0: begin spr_ram_a <= {3'b000, sp_base + 8'd3}; sp_st <= SP_Y1; end
        SP_Y1: sp_st <= SP_Y2;
        SP_Y2: begin
            if (sp_dy[9:4] == 6'd0) begin
                sp_row    <= sp_dy[3:0];
                spr_ram_a <= {3'b000, sp_base};
                sp_st     <= SP_A0;
            end else if (sp_slot == 6'd0)
                sp_st <= SP_IDLE;
            else begin
                sp_slot <= sp_slot - 6'd1;
                sp_st   <= SP_Y0;
            end
        end
        SP_A0: begin spr_ram_a <= {3'b000, sp_base + 8'd1}; sp_st <= SP_A1; end
        SP_A1: begin sp_x <= spr_d; spr_ram_a <= {3'b000, sp_base + 8'd2}; sp_st <= SP_A2; end
        SP_A2: begin sp_c1 <= spr_d; sp_st <= SP_A3; end
        SP_A3: begin
            sp_attr <= spr_d;
            if (spr_d[7]) sp_row <= ~sp_row;                            // Y flip
            sp_xh   <= 1'b0;
            sp_st   <= SP_A4;
        end
        SP_A4: begin sp_rom <= {sp_attr[5], sp_c1[7:1], sp_row[3], sp_c1[0], sp_xh, sp_row[2:0]}; sp_st <= SP_R0; end
        SP_R0: begin rom2_a <= {1'b0, 1'b0, sp_rom}; sp_st <= SP_R1; end       // planes 1-0 (0x0000)
        SP_R1: begin rom2_a <= {1'b0, 1'b1, sp_rom}; sp_st <= SP_R2; end       // planes 3-2 (0x4000)
        SP_R2: begin sp_lo <= rom2_d; sp_st <= SP_R3; end
        SP_R3: begin sp_hi <= rom2_d; sp_k <= 2'd0; sp_st <= SP_PIX; end
        SP_PIX: begin
            if (!sp_px[8] && sp_pen != 4'd0) begin
                lb_wr_a <= sp_px[7:0] ^ {8{crt_flip}};
                lb_wr_d <= {sp_attr[3:0], sp_pen};
                lb_wr   <= 1'b1;
            end
            sp_k <= sp_k + 2'd1;
            if (sp_k == 2'd3) begin
                if (!sp_xh) begin
                    sp_xh <= 1'b1;
                    sp_st <= SP_A4;
                end else if (sp_slot == 6'd0)
                    sp_st <= SP_IDLE;
                else begin
                    sp_slot <= sp_slot - 6'd1;
                    sp_st   <= SP_Y0;
                end
            end
        end
        default: sp_st <= SP_IDLE;
    endcase

    // a new line starts: draw the line after it
    if (ce_pix && hcnt == 9'd116) begin
        sp_line <= (vcnt + 8'd1) ^ {8{crt_flip}};
        sp_buf  <= ~vcnt[0];
        sp_slot <= 6'd47;
        sp_st   <= SP_Y0;
    end
end

/////////////////////////////  Mixer / palette  /////////////////////////////

// Stage 1 = tile pen + line buffer read, stage 2 = lookup PROM + palette PROM
logic [3:0] s1_tcol;
logic       s1_pri;
logic [1:0] s1_tpen;
logic       hs_d, vs_d, hb_d, vb_d;
logic [2:0] mix_st = 3'd0;
logic       s2_spr;

always_ff @(posedge clk) begin
    clr_wr <= 1'b0;

    if (ce_pix) begin
        s1_tcol <= cur_attr[3:0];
        s1_pri  <= cur_attr[4];
        s1_tpen <= tpen;
        lb_rd_a <= hcnt[7:0];
        clr_a   <= hcnt[7:0];
        rd_sel  <= vcnt[0];
        hb_d    <= raw_hblank;
        vb_d    <= raw_vblank;
        hs_d    <= raw_hs;
        vs_d    <= raw_vs;
        mix_st  <= 3'd1;
    end else begin
        case (mix_st)
            3'd1: mix_st <= 3'd2;                       // line buffer data valid next clock
            3'd2: begin
                if (!hb_d) clr_wr <= 1'b1;              // erase behind the beam (visible pixels only)
                // attr bit 4 tiles cover sprites (MAME group 0, opaque); sprite pen 0 is transparent
                s2_spr <= ~s1_pri && lb_q[3:0] != 4'd0;
                lut_a  <= (~s1_pri && lb_q[3:0] != 4'd0) ? {1'b0, lb_q} : {3'b100, s1_tcol, s1_tpen};
                mix_st <= 3'd3;
            end
            3'd3: mix_st <= 3'd4;
            3'd4: begin pal_a <= {~s2_spr, lut_d[3:0]}; mix_st <= 3'd5; end
            3'd5: mix_st <= 3'd6;
            3'd6: mix_st <= 3'd0;
            default: mix_st <= 3'd0;
        endcase
    end
end

// Palette PROM: R 1K / 470 / 220 (bits 0-2), G 1K / 470 / 220 (bits 3-5), B 470 / 220 (bits 6-7), 470 pull-down
// (MAME compute_resistor_weights, autoscaled)
function automatic [7:0] dac3(input [2:0] b);
    case (b)
        3'd0: dac3 = 8'd0;   3'd1: dac3 = 8'd33;  3'd2: dac3 = 8'd71;  3'd3: dac3 = 8'd104;
        3'd4: dac3 = 8'd151; 3'd5: dac3 = 8'd184; 3'd6: dac3 = 8'd222; default: dac3 = 8'd255;
    endcase
endfunction

function automatic [7:0] dac2(input [1:0] b);
    case (b)
        2'd0: dac2 = 8'd0; 2'd1: dac2 = 8'd79; 2'd2: dac2 = 8'd168; default: dac2 = 8'd247;
    endcase
endfunction

always_ff @(posedge clk) begin
    if (ce_pix) begin
        video_hblank <= hb_d;
        video_vblank <= vb_d;
        video_hs     <= hs_d;
        video_vs     <= vs_d;
        if (hb_d | vb_d) begin
            video_r <= 8'd0;
            video_g <= 8'd0;
            video_b <= 8'd0;
        end else begin
            video_r <= dac3(pal_d[2:0]);
            video_g <= dac3(pal_d[5:3]);
            video_b <= dac2(pal_d[7:6]);
        end
    end
end

/////////////////////////////  Sound board  /////////////////////////////

assign snd_latch = sound_latch;
assign snd_irq   = snd_pulse != 6'd0;

endmodule
