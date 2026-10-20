//============================================================================
//
//  Konami Tutankham board (KT-3203-1B CPU/video + KT-5112-2B sound)
//  Copyright (C) 2026 Rodimus
//
//  Written from the Tutankham schematics and MAME tutankhm.cpp / tutankhm_v.cpp (Mirko Buffoni,
//  after Rob Jarrett). 6809E main CPU (Greg Miller's MC6809, unmodified), 256x256 4bpp bitmap in
//  CPU RAM, 16-entry palette RAM, column scroll on the left 192 columns, banked graphics ROMs,
//  084 starfield (k084.sv, Vic20-Ian).
//
//  juno = Juno First (MAME junofrst.cpp, Chris Hardy): same video, KONAMI-1 main CPU (opcode fetches XORed
//  by address bits 3 and 1, decrypted outside the unmodified MC6809), its own I/O map, no scroll or stars,
//  12 code/graphics banks, and a 16x16 nibble blitter at 8070-8073. Its sound board is junofrst_sound.sv.
//
//  ROM windows (banked ROM store, rtl/konami82_board.sv), images stored as dumped:
//    0x00000 - 0x05FFF  maincpu A000-FFFF
//    0x08000 - 0x0BFFF  timeplt_audio:tpsound (shared sound board, same window on every board)
//    0x10000 - 0x1BFFF  maincpu banks 0-11 (9000-9FFF window; Tutankham 0-8, Juno First 0-11)
//    0x20000 - 0x21FFF  Juno First audiocpu + mcu (junofrst_sound.sv)
//    0x24000 - 0x29FFF  Juno First blitrom (blt_rom)
//
//============================================================================

module tutankhm_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic        juno,           // Juno First
    output logic        ce_pix,

    input  logic  [7:0] in0,            // $8180 system      (Juno First $8020)
    input  logic  [7:0] in1,            // $81A0 player 1    (Juno First $8024)
    input  logic  [7:0] in2,            // $81C0 player 2    (Juno First $8028)
    input  logic  [7:0] dsw0,           // $81E0 DSW1 coinage (Juno First $802C)
    input  logic  [7:0] dsw1,           // $8160 DSW2        (Juno First $8010)

    output logic [14:0] rom0_a,         // banked ROM store (rtl/konami82_board.sv): window 0x00000-0x07FFF
    input  logic  [7:0] rom0_d,
    output logic [13:0] rom1_a,         //                                                  0x0C000-0x0FFFF
    input  logic  [7:0] rom1_d,
    output logic [15:0] rom2_a,         //                                                  0x10000-0x1FFFF
    input  logic  [7:0] rom2_d,
    output logic [14:0] blt_rom_a,      //                                                  0x24000-0x2BFFF (blitter)
    input  logic  [7:0] blt_rom_d,

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
    output logic  [7:0] snd_latch,      // to the shared sound board (rtl/konami82_board.sv)
    output logic        snd_irq,        // Tutankham: trigger pulse; Juno First: 8040 bit 0 level
    output logic        snd_mute,

    output chip_pool_pkg::m6809r_i_t m6809_0_i,          // shared MC6809E (rtl/konami82_board.sv)
    input  chip_pool_pkg::m6809r_o_t m6809_0_o,
    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

/////////////////////////////  ROM storage  /////////////////////////////

logic [15:0] cpu_a;
logic  [3:0] bank;
wire  [15:0] romh_a = cpu_a - 16'hA000;

// A000-FFFF in ROM window 0 (A000-DFFF at 0x0000, E000-FFFF at 0x4000), banks in ROM window 2
// (0-7 at 0x0000, 8-11 at 0x8000). One CPU reads them, one cycle at a time.
assign rom0_a = (cpu_a[15:13] == 3'b111) ? {2'b10, cpu_a[12:0]} : {1'b0, romh_a[13:0]};
assign rom1_a = 14'd0;
assign rom2_a = ~bank[3] ? {1'b0, bank[2:0], cpu_a[11:0]} : {2'b10, bank[1:0], cpu_a[11:0]};

// Juno First blitter source ROM (BLTROM, 24K, window 0x24000): read only by the blitter
logic [14:0] blt_ra;
assign blt_rom_a = blt_ra;

/////////////////////////////  Clocks  /////////////////////////////

// 18.432 MHz / 3 = 6.144 MHz pixel clock = 49.152 / 8; 6809E E = 18.432 / 12 = 1.536 MHz = 49.152 / 32
logic [4:0] div = 5'd0;
always_ff @(posedge clk) div <= div + 5'd1;

assign ce_pix = (div[2:0] == 3'd7);

// The Juno First blitter holds the CPU for whole E cycles while it runs (MAME blits instantly; HW timing #unverified)
logic blt_busy;
logic blt_hold = 1'b0;
always_ff @(posedge clk) if (div == 5'd0) blt_hold <= blt_busy;

wire   fall_q = (div == 5'd23) & ~pause & ~blt_hold;      // Q falls a quarter cycle before E
wire   fall_e = (div == 5'd31) & ~pause & ~blt_hold;

/////////////////////////////  Video timing  /////////////////////////////

// H counts 128..511 (384 pixels, 256..511 visible), V counts 248..511 (264 lines, 272..495 visible = y 16..239)
logic [8:0] hcnt = 9'd128;
logic [8:0] vcnt = 9'd248;

always_ff @(posedge clk) begin
    if (ce_pix) begin
        if (hcnt == 9'd511) begin
            hcnt <= 9'd128;
            vcnt <= (vcnt == 9'd511) ? 9'd248 : vcnt + 9'd1;
        end else
            hcnt <= hcnt + 9'd1;
    end
end

wire [8:0] v_line = vcnt - 9'd248;                             // 0..263
wire [8:0] hs_on  = 9'd176 + {{4{h_adj[3]}}, h_adj, 1'b0};
wire [8:0] vs_on  = v_adj[3] ? 9'd268 + {{5{1'b1}}, v_adj} : 9'd4 + {5'd0, v_adj};    // 4 + v, mod 264
wire [8:0] vs_beg = (vs_on >= 9'd264) ? vs_on - 9'd264 : vs_on;
wire [9:0] vs_dist = (v_line >= vs_beg) ? {1'b0, v_line - vs_beg} : {1'b0, v_line} + 10'd264 - {1'b0, vs_beg};

wire raw_hblank = ~hcnt[8];
wire raw_vblank = (vcnt < 9'd272) || (vcnt >= 9'd496);

// Watchdog, frozen while paused, cleared by a kick; it holds the CPU and the main latch (and the sound board) in reset.
// Juno First: LS293 H9 counts frames at vblank end, kick = any access to 801C-801F; QD (8 frames) -> reset for 8 frames,
// then the count wraps (schematic). Tutankham: inside the 084 (F3), kick = any access to 8120-812F; its timeout is not
// on the schematic, so 64 frames (MAME: 3 s) with the same 8-frame reset (#unverified). Video timing keeps running.
logic       wd_vb = 1'b0, wd_kick;
logic [6:0] wd_cnt = 7'd0;
wire        wd_edge = juno ? !raw_vblank && wd_vb : raw_vblank && !wd_vb;
always_ff @(posedge clk) begin
    if (ce_pix) wd_vb <= raw_vblank;
    if (reset || wd_kick)                    wd_cnt <= 7'd0;
    else if (ce_pix && wd_edge && !pause)    wd_cnt <= (wd_cnt == (juno ? 7'd15 : 7'd71)) ? 7'd0 : wd_cnt + 7'd1;
end
wire wd_rst  = juno ? wd_cnt[3] : wd_cnt[6];
wire cpu_rst = reset | wd_rst;
wire raw_hs     = ~((hcnt >= hs_on) && (hcnt < hs_on + 9'd32));
wire raw_vs     = (vs_dist >= 10'd3);

// Main latch (LS259 C3): Q0 IRQ enable, Q1 pay out, Q2/Q3 coin counters, Q4 stars enable, Q5 sound mute,
// Q6 flip X, Q7 flip Y. Juno First (LS259 B3): Q0 IRQ enable, Q1/Q2 coin counters, Q3 sound mute, Q4 flip X, Q5 flip Y.
logic [7:0] mainlatch = 8'h00;
wire fx = (juno ? mainlatch[4] : mainlatch[6]) ^ crt_flip;
wire fy = (juno ? mainlatch[5] : mainlatch[7]) ^ crt_flip;

/////////////////////////////  Main CPU (6809E)  /////////////////////////////

logic  [7:0] cpu_do, cpu_di, bus_d;
logic        cpu_rw, cpu_lic;
logic        irq_ff = 1'b0;

// Main CPU: the shared MC6809E in rtl/konami82_board.sv
assign m6809_0_i.reset_n = ~wd_rst;
assign m6809_0_i.fall_e = fall_e;
assign m6809_0_i.fall_q = fall_q;
assign m6809_0_i.irq_n  = ~irq_ff;
assign m6809_0_i.firq_n = 1'b1;
assign m6809_0_i.nmi_n  = 1'b1;
assign m6809_0_i.d      = cpu_di;
assign cpu_a = m6809_0_o.a;
assign cpu_do = m6809_0_o.dout;
assign cpu_rw = m6809_0_o.rw;
assign cpu_lic = m6809_0_o.lic;

// KONAMI-1 (Juno First): opcode fetch = the bus cycle after LIC (instruction byte 1), or the byte after a
// $10/$11 page prefix. The reset and interrupt vector reads also follow LIC; they sit at FFF0-FFFF, where no
// code runs.
logic lic_q = 1'b0, pfx_q = 1'b0;
wire  op_fetch = juno && ((lic_q && cpu_a[15:4] != 12'hFFF) || pfx_q);

function automatic [7:0] k1_key(input [15:0] a);
    case ({a[3], a[1]})
        2'b00: k1_key = 8'h22;
        2'b01: k1_key = 8'h82;
        2'b10: k1_key = 8'h28;
        2'b11: k1_key = 8'h88;
    endcase
endfunction

assign cpu_di = op_fetch ? bus_d ^ k1_key(cpu_a) : bus_d;

always_ff @(posedge clk) begin
    if (cpu_rst) begin
        lic_q <= 1'b0;
        pfx_q <= 1'b0;
    end else if (fall_e) begin
        lic_q <= cpu_lic;
        pfx_q <= op_fetch && (cpu_di == 8'h10 || cpu_di == 8'h11);
    end
end

// Tutankham map
wire tk_pal  = cpu_a[15:8] == 8'h80;                                // 8000-80FF, 16 entries mirrored
wire tk_scrl = cpu_a[15:4] == 12'h810;                              // 8100-810F
wire tk_in   = cpu_a[15:8] == 8'h81 && cpu_a[7:5] != 3'd0;          // 8120-81FF watchdog / inputs
wire tk_ltch = cpu_a[15:8] == 8'h82;                                // 8200-82FF main latch (A2-A0)
wire tk_bank = cpu_a[15:8] == 8'h83;                                // 8300-83FF bank select
wire tk_snd  = cpu_a[15:8] == 8'h86;                                // 8600-86FF sound IRQ
wire tk_slat = cpu_a[15:8] == 8'h87;                                // 8700-87FF sound latch
wire tk_ram  = cpu_a[15:11] == 5'b1000_1;                           // 8800-8FFF

// Juno First map (MAME junofrst_state::main_map)
wire jf_pal  = cpu_a[15:4] == 12'h800;                              // 8000-800F
wire jf_in   = cpu_a[15:6] == 10'h200 && (cpu_a[5:2] == 4'd4 || cpu_a[5:4] == 2'b10);
                                                                    // 8010 DSW2, 8020-802C inputs / DSW1
wire jf_ltch = cpu_a[15:3] == 13'h1006;                             // 8030-8037 main latch (A2-A0)
wire jf_snd  = cpu_a[15:4] == 12'h804;                              // 8040 sound IRQ trigger
wire jf_slat = cpu_a[15:4] == 12'h805;                              // 8050 sound latch
wire jf_bank = cpu_a[15:4] == 12'h806;                              // 8060 bank select
wire jf_blit = cpu_a[15:4] == 12'h807;                              // 8070-8073 blitter
wire jf_ram  = cpu_a[15:12] == 4'h8 && cpu_a[11:8] != 4'h0;         // 8100-8FFF

wire cs_vram = ~cpu_a[15];                                          // 0000-7FFF bitmap
wire cs_pal  = juno ? jf_pal  : tk_pal;
wire cs_scrl = ~juno & tk_scrl;
wire cs_in   = juno ? jf_in   : tk_in;
wire cs_ltch = juno ? jf_ltch : tk_ltch;
wire cs_bank = juno ? jf_bank : tk_bank;
wire cs_snd  = juno ? jf_snd  : tk_snd;
wire cs_slat = juno ? jf_slat : tk_slat;
wire cs_blit = juno & jf_blit;
wire cs_ram  = juno ? jf_ram  : tk_ram;
wire cs_brom = cpu_a[15:12] == 4'h9;                                // 9000-9FFF banked ROM

assign wd_kick  = fall_e && (juno ? cpu_a[15:2] == 14'h2007 : cpu_a[15:4] == 12'h812);
assign wd_reset = wd_rst;
wire cs_rom  = cpu_a >= 16'hA000;

// one write per bus cycle, at the end of E
wire wr = fall_e & ~cpu_rw;

// Bitmap RAM: CPU (or the blitter) on port A, video on port B
logic [14:0] vram_va, blt_va;
logic  [7:0] vram_cpu_d, vram_vd, blt_wd;
logic        blt_we;
dpram_dc #(.widthad_a(15)) vram
(
    .clock_a(clk), .address_a(blt_busy ? blt_va : cpu_a[14:0]), .data_a(blt_busy ? blt_wd : cpu_do),
    .wren_a(blt_busy ? blt_we : cs_vram & wr), .q_a(vram_cpu_d),
    .clock_b(clk), .address_b(vram_va), .q_b(vram_vd)
);

// Work RAM 8000-8FFF (Tutankham uses 8800-8FFF, Juno First 8100-8FFF); second port for the hiscore system
logic [7:0] ram_cpu_d;
wire        hs_cs = hs_address[15:12] == 4'h8;
dpram_dc #(.widthad_a(12)) ram_work
(
    .clock_a(clk), .address_a(cpu_a[11:0]), .data_a(cpu_do), .wren_a(cs_ram & wr), .q_a(ram_cpu_d),
    .clock_b(clk), .address_b(hs_address[11:0]), .data_b(hs_data_in), .wren_b(hs_cs & hs_write), .q_b(hs_data_out)
);

logic [7:0] pal[16];
logic [7:0] scroll = 8'd0;

// 8160 DSW2, 8180 IN0, 81A0 IN1, 81C0 IN2, 81E0 DSW1 (A7-A5); 8120 is the watchdog
// Juno First: 8010 DSW2, 8020 SYSTEM, 8024 P1, 8028 P2, 802C DSW1 (A5-A2); 801C is the watchdog
logic [7:0] in_d;
always_comb begin
    if (juno)
        case (cpu_a[5:2])
            4'd4:    in_d = dsw1;
            4'd8:    in_d = in0;
            4'd9:    in_d = in1;
            4'd10:   in_d = in2;
            4'd11:   in_d = dsw0;
            default: in_d = 8'hFF;
        endcase
    else
        case (cpu_a[7:5])
            3'd3:    in_d = dsw1;
            3'd4:    in_d = in0;
            3'd5:    in_d = in1;
            3'd6:    in_d = in2;
            3'd7:    in_d = dsw0;
            default: in_d = 8'hFF;
        endcase
end

// Banks: Tutankham 0-8 (9-15 read 00), Juno First 0-11 (12-15 read 00, MAME ROMREGION_ERASE00)
wire [7:0] brom_d = (~bank[3] || (juno ? bank[2] == 1'b0 : bank[2:0] == 3'd0)) ? rom2_d : 8'h00;

always_comb begin
    if      (cs_vram) bus_d = vram_cpu_d;
    else if (cs_pal)  bus_d = pal[cpu_a[3:0]];
    else if (cs_scrl) bus_d = scroll;
    else if (cs_in)   bus_d = in_d;
    else if (cs_ram)  bus_d = ram_cpu_d;
    else if (cs_brom) bus_d = brom_d;
    else if (cs_rom)  bus_d = rom0_d;
    else              bus_d = 8'hFF;
end

logic [7:0] sound_latch = 8'h00;
logic [5:0] snd_pulse = 6'd0;
logic       snd_trig = 1'b0;                                        // Juno First 8040 D0
logic [7:0] blt_reg[4];
logic       blt_go;

always_ff @(posedge clk) begin
    if (snd_pulse != 6'd0) snd_pulse <= snd_pulse - 6'd1;
    blt_go <= 1'b0;
    if (cpu_rst) begin
        mainlatch <= 8'h00;
        bank      <= 4'd0;
        snd_pulse <= 6'd0;
        snd_trig  <= 1'b0;
        blt_reg   <= '{8'h00, 8'h00, 8'h00, 8'h00};
    end else if (wr) begin
        if (cs_pal)  pal[cpu_a[3:0]] <= cpu_do;
        if (cs_scrl) scroll <= cpu_do;
        if (cs_ltch) mainlatch[cpu_a[2:0]] <= cpu_do[0];
        if (cs_bank) bank <= cpu_do[3:0];
        if (cs_slat) sound_latch <= cpu_do;
        if (cs_snd)  begin snd_pulse <= 6'd63; snd_trig <= cpu_do[0]; end   // MAME sound_on_w: trigger 0 then 1
        if (cs_blit) begin
            blt_reg[cpu_a[1:0]] <= cpu_do;
            blt_go <= cpu_a[1:0] == 2'd3;                           // a write to 8073 starts the blit
        end
    end
end

/////////////////////////////  Juno First blitter  /////////////////////////////

// MAME junofrst_state::blitter_w: 16x16 nibbles from BLTROM (source nibble address 8072/3 & FFFC) to the
// bitmap (destination nibble address 8070/1, rows 256 nibbles apart). Only non-zero source nibbles are
// written: the source nibble itself when 8073 bit 0 is set, else 0 (erase). Odd nibble = low ROM nibble,
// high bitmap nibble. Three clocks per nibble: address, BRAM read, merge + write.
logic [15:0] blt_src, blt_dst;
logic        blt_copy;
logic  [7:0] blt_cnt;
logic  [1:0] blt_st = 2'd0;
logic        blt_srcodd, blt_dstodd;
logic        blt_oob;

assign blt_busy = blt_st != 2'd0 || blt_go || blt_we;           // the last write lands after the FSM ends

wire [7:0] blt_rom = blt_oob ? 8'h00 : blt_rom_d;
wire [3:0] blt_nib = blt_srcodd ? blt_rom[3:0] : blt_rom[7:4];
wire [3:0] blt_out = blt_copy ? blt_nib : 4'd0;

always_ff @(posedge clk) begin
    blt_we <= 1'b0;
    if (cpu_rst)
        blt_st <= 2'd0;
    else case (blt_st)
        2'd0: if (blt_go) begin
            blt_src  <= {blt_reg[2], blt_reg[3]} & 16'hFFFC;
            blt_dst  <= {blt_reg[0], blt_reg[1]};
            blt_copy <= blt_reg[3][0];
            blt_cnt  <= 8'd0;
            blt_st   <= 2'd1;
        end
        2'd1: begin                                                 // address source byte and bitmap byte
            blt_ra     <= blt_src[15:1];
            blt_oob    <= blt_src[15:1] >= 15'h6000;
            blt_srcodd <= blt_src[0];
            blt_va     <= blt_dst[15:1];
            blt_dstodd <= blt_dst[0];
            blt_st     <= 2'd2;
        end
        2'd2: blt_st <= 2'd3;                                       // BRAM read
        2'd3: begin
            if (blt_nib != 4'd0) begin
                blt_wd <= blt_dstodd ? {blt_out, vram_cpu_d[3:0]} : {vram_cpu_d[7:4], blt_out};
                blt_we <= 1'b1;
            end
            blt_src <= blt_src + 16'd1;
            blt_dst <= blt_dst + ((blt_cnt[3:0] == 4'd15) ? 16'd241 : 16'd1);
            blt_cnt <= blt_cnt + 8'd1;
            blt_st  <= (blt_cnt == 8'd255) ? 2'd0 : 2'd1;
        end
    endcase
end

// IRQ every other vblank (MAME: flip-flops divide it by two), held until the enable is cleared
logic irq_toggle = 1'b0;
wire  vblank_start = ce_pix && hcnt == 9'd128 && vcnt == 9'd496;
always_ff @(posedge clk) begin
    if (cpu_rst) begin
        irq_toggle <= 1'b0;
        irq_ff     <= 1'b0;
    end else begin
        if (vblank_start) begin
            irq_toggle <= ~irq_toggle;
            if (~irq_toggle && mainlatch[0]) irq_ff <= 1'b1;
        end
        if (!mainlatch[0]) irq_ff <= 1'b0;
    end
end

/////////////////////////////  Bitmap  /////////////////////////////

// Pixel x of line y: effx = x ^ flip X, the left 192 columns scroll vertically, effy = (y ^ flip Y) + scroll;
// byte effy * 128 + effx / 2, low nibble for even effx (MAME tutankhm_v.cpp).
wire [7:0] effx = hcnt[7:0] ^ {8{fx}};
wire [7:0] effy = (vcnt[7:0] ^ {8{fy}}) + ((effx < 8'd192 && !juno) ? scroll : 8'd0);

logic       nib_hi;
logic [3:0] pix1;
logic       hb0, vb0, hs0, vs0, hb1, vb1, hs1, vs1;
logic [5:0] star1;
logic       star_on1;

wire        star_on;
wire  [1:0] star_r, star_g, star_b;

always_ff @(posedge clk) begin
    if (ce_pix) begin
        // stage 0: address the pixel
        vram_va <= {effy, effx[7:1]};
        nib_hi  <= effx[0];
        hb0 <= raw_hblank; vb0 <= raw_vblank; hs0 <= raw_hs; vs0 <= raw_vs;
        // stage 1: pixel + star for it (k084 presents a pixel's star one pixel later)
        pix1     <= nib_hi ? vram_vd[7:4] : vram_vd[3:0];
        star_on1 <= star_on;
        star1    <= {star_r, star_g, star_b};
        hb1 <= hb0; vb1 <= vb0; hs1 <= hs0; vs1 <= vs0;
    end
end

/////////////////////////////  084 starfield  /////////////////////////////

k084 stars
(
    .clk(clk),
    .reset(~reset),
    .cen_6m(ce_pix),
    .hblank(raw_hblank),
    .vblank(raw_vblank),
    .blank(raw_hblank | raw_vblank),
    .aux_en(1'b1),                                  // gated against the bitmap below
    .stars_en(~juno & mainlatch[4]),                // Juno First has no star latch bit
    .hff(fx),
    .h8q(~(hcnt[3] ^ fx)),                          // H8 inverted and flipped by the LS86 at F11
    .v1(vcnt[0]),
    .v2(vcnt[1]),
    .hpos_hi(hcnt[7:6]),
    .wd_kick(1'b0),
    .bootleg_mode(1'b0),
    .star_r(star_r),
    .star_g(star_g),
    .star_b(star_b),
    .star_on(star_on),
    .wd_reset()
);

/////////////////////////////  Palette / output  /////////////////////////////

// Palette RAM 3-3-2 through 1K / 470 / 220 (B 470 / 220), 470 pull-down, max 224 (MAME raw_to_rgb_func);
// star levels {100 ohm, 150 ohm}: 0 / 194 / 214 / 255 (MAME galaxian_palette)
function automatic [7:0] dac3(input [2:0] b);
    case (b)
        3'd0: dac3 = 8'd0;   3'd1: dac3 = 8'd29;  3'd2: dac3 = 8'd62;  3'd3: dac3 = 8'd91;
        3'd4: dac3 = 8'd133; 3'd5: dac3 = 8'd162; 3'd6: dac3 = 8'd195; default: dac3 = 8'd224;
    endcase
endfunction

function automatic [7:0] dac2(input [1:0] b);
    case (b)
        2'd0: dac2 = 8'd0; 2'd1: dac2 = 8'd69; 2'd2: dac2 = 8'd148; default: dac2 = 8'd217;
    endcase
endfunction

function automatic [7:0] star_lvl(input [1:0] s);                // s = {100 ohm, 150 ohm}
    case (s)
        2'd0: star_lvl = 8'd0; 2'd1: star_lvl = 8'd194; 2'd2: star_lvl = 8'd214; default: star_lvl = 8'd255;
    endcase
endfunction

wire [7:0] pcol = pal[pix1];

always_ff @(posedge clk) begin
    if (ce_pix) begin
        video_hblank <= hb1;
        video_vblank <= vb1;
        video_hs     <= hs1;
        video_vs     <= vs1;
        if (hb1 | vb1) begin
            video_r <= 8'd0;
            video_g <= 8'd0;
            video_b <= 8'd0;
        end else if (star_on1 && pix1 == 4'd0) begin                // stars show through pen 0 (#unverified)
            video_r <= star_lvl(star1[5:4]);
            video_g <= star_lvl(star1[3:2]);
            video_b <= star_lvl(star1[1:0]);
        end else begin
            video_r <= dac3(pcol[2:0]);
            video_g <= dac3(pcol[5:3]);
            video_b <= dac2(pcol[7:6]);
        end
    end
end

/////////////////////////////  Sound board (shared, in konami82_board)  /////////////////////////////

assign snd_latch = sound_latch;
assign snd_irq   = juno ? snd_trig : snd_pulse != 6'd0;
assign snd_mute  = juno ? mainlatch[3] : mainlatch[5];       // Juno First: LS259 B3 Q3 MUT (schematic p18)

endmodule
