//============================================================================
//
//  Konami Roc'n Rope board (KT-A207-1C CPU/video + KT-2207-2A sound)
//  Copyright (C) 2026 Rodimus
//
//  Written from the Roc'n Rope schematics and MAME rocnrope.cpp (Chris Hardy) / konami1.cpp
//  (Olivier Galibert). Main CPU is the KONAMI-1: a 6809 whose opcode fetches are XORed by
//  address bits 3 and 1. Modelled here as Greg Miller's MC6809 (synchronous version) plus an
//  external opcode decrypter; the CPU core is used unmodified.
//
//  ioctl index 0 (MRA), images stored as dumped, MAME region order:
//    0x00000 - 0x07FFF  sprites (0x0000 planes 0/1, 0x4000 planes 2/3)
//    0x08000 - 0x0BFFF  timeplt_audio:tpsound (shared sound board, same window on every board:
//                       the variant byte arrives in index 1, after the ROMs)
//    0x0C000 - 0x0FFFF  tiles   (0x0000 planes 0/1, 0x2000 planes 2/3)
//    0x10000 - 0x1FFFF  maincpu (code at 0x6000-0xFFFF)
//    0x20000 - 0x2001F  palette PROM a17
//    0x20020 - 0x2011F  sprite lookup b16   0x20120 - 0x2021F  char lookup pr3
//
//  rom_dec[0]: MAME init_rocnrope, byte 0x703D reads as 0x98 ^ 0x22 (rocnrope, ropeman)
//
//============================================================================

module rocnrope_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic  [3:0] rom_dec,
    output logic        ce_pix,

    input  logic  [7:0] in0,            // $3080 system
    input  logic  [7:0] in1,            // $3081 player 1
    input  logic  [7:0] in2,            // $3082 player 2
    input  logic  [7:0] dsw0,           // $3083 coinage (DSW1)
    input  logic  [7:0] dsw1,           // $3000 DSW2
    input  logic  [7:0] dsw2,           // $3100 DSW3

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    output logic [14:0] rom0_a,         // shared ROM blocks (rtl/konami82_board.sv): ioctl 0x00000-0x07FFF
    input  logic  [7:0] rom0_d,
    output logic [13:0] rom1_a,         //                                            0x0C000-0x0FFFF
    input  logic  [7:0] rom1_d,
    output logic [15:0] rom2_a,         //                                            0x10000-0x1FFFF
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
    output logic  [7:0] snd_latch,      // to the shared sound board (rtl/konami82_board.sv)
    output logic        snd_irq,
    output logic        snd_mute,

    output chip_pool_pkg::m6809r_i_t m6809_0_i,          // shared MC6809E (rtl/konami82_board.sv)
    input  chip_pool_pkg::m6809r_o_t m6809_0_o,
    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

/////////////////////////////  ROM storage  /////////////////////////////

wire load_prom = ioctl_wr0 && ioctl_addr[24:10] == 15'h0080;    // 0x20000-0x203FF
wire load_pal  = load_prom && ioctl_addr[9:5] == 5'd0;          // a17
wire [9:0]  slut_dl = ioctl_addr[9:0] - 10'h020;
wire [9:0]  clut_dl = ioctl_addr[9:0] - 10'h120;
wire load_slut = load_prom && ioctl_addr[9:0] >= 10'h020 && ioctl_addr[9:0] < 10'h120;
wire load_clut = load_prom && ioctl_addr[9:0] >= 10'h120 && ioctl_addr[9:0] < 10'h220;

logic [15:0] cpu_rom_a;
logic  [7:0] cpu_rom_d;
assign rom2_a    = cpu_rom_a;                // CPU ROM in shared block 2
assign cpu_rom_d = rom2_d;

logic [14:0] spr_rom_a;
logic  [7:0] spr_rom_d;
assign rom0_a    = spr_rom_a;                // sprites in shared block 0
assign spr_rom_d = rom0_d;

logic [13:0] tile_rom_a;
logic  [7:0] tile_rom_d;
assign rom1_a     = tile_rom_a;              // tiles in shared block 1
assign tile_rom_d = rom1_d;

logic [7:0] slut_a, slut_d;
dpram_dc #(.widthad_a(8)) prom_slut
(
    .clock_a(clk), .address_a(slut_dl[7:0]), .data_a(ioctl_dout), .wren_a(load_slut),
    .clock_b(clk), .address_b(slut_a), .q_b(slut_d)
);

logic [7:0] clut_a, clut_d;
dpram_dc #(.widthad_a(8)) prom_clut
(
    .clock_a(clk), .address_a(clut_dl[7:0]), .data_a(ioctl_dout), .wren_a(load_clut),
    .clock_b(clk), .address_b(clut_a), .q_b(clut_d)
);

logic [4:0] pal_a;
logic [7:0] pal_d;
dpram_dc #(.widthad_a(5)) prom_pal
(
    .clock_a(clk), .address_a(ioctl_addr[4:0]), .data_a(ioctl_dout), .wren_a(load_pal),
    .clock_b(clk), .address_b(pal_a), .q_b(pal_d)
);

/////////////////////////////  Clocks  /////////////////////////////

// 18.432 MHz / 3 = 6.144 MHz pixel clock = 49.152 / 8; 6809 E = 18.432 / 12 = 1.536 MHz = 49.152 / 32
logic [4:0] div = 5'd0;
always_ff @(posedge clk) div <= div + 5'd1;

assign ce_pix = (div[2:0] == 3'd7);
wire   fall_q = (div == 5'd23) & ~pause;      // Q falls a quarter cycle before E
wire   fall_e = (div == 5'd31) & ~pause;

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

// Watchdog (LS293 E2): counts frames at vblank start (frozen while paused), cleared by an 8000 write (8000-807F). QD (8 frames without
// a kick) holds the KONAMI-1 and LS259 B2 (and the sound board) in reset for 8 frames, then the count wraps (schematic). Video timing keeps running.
logic       wd_vb = 1'b0, wd_kick;
logic [3:0] wd_cnt = 4'd0;
always_ff @(posedge clk) begin
    if (ce_pix) wd_vb <= raw_vblank;
    if (reset || wd_kick)                      wd_cnt <= 4'd0;
    else if (ce_pix && raw_vblank && !wd_vb && !pause)  wd_cnt <= wd_cnt + 4'd1;
end
wire wd_rst  = wd_cnt[3];
wire cpu_rst = reset | wd_rst;
wire raw_hs     = ~((hcnt >= hs_on) && (hcnt < hs_on + 9'd32));
wire raw_vs     = (vs_dist >= 10'd3);

// Main latch (LS259 B2): Q0 /flip, Q1 sound IRQ, Q2 sound mute, Q3/Q4 coin counters, Q7 IRQ enable
logic [7:0] mainlatch = 8'h00;
wire tflip = ~mainlatch[0] ^ crt_flip;         // MAME flips only the tilemap with the game's flip

/////////////////////////////  Main CPU (KONAMI-1)  /////////////////////////////

logic [15:0] cpu_a;
logic  [7:0] cpu_do, cpu_di, bus_d;
logic        cpu_rw, cpu_lic;
logic        irq_ff = 1'b0;

// Main CPU (KONAMI-1): the shared MC6809E in rtl/konami82_board.sv
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

// Opcode fetch = the bus cycle after LIC (instruction byte 1), or the byte after a $10/$11 page prefix.
// The reset and interrupt vector reads also follow LIC; they sit at FFF0-FFFF, where no code runs.
logic lic_q = 1'b0, pfx_q = 1'b0;
wire  op_fetch = (lic_q && cpu_a[15:4] != 12'hFFF) || pfx_q;

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

wire cs_io   = cpu_a[15:12] == 4'h3;                                // 3000-3FFF inputs / DIPs
wire cs_sprb = cpu_a[15:10] == 6'b0100_00;                          // 4000-43FF (sprite attr / Y)
wire cs_spra = cpu_a[15:10] == 6'b0100_01;                          // 4400-47FF (sprite X / code)
wire cs_col  = cpu_a[15:10] == 6'b0100_10;                          // 4800-4BFF
wire cs_vid  = cpu_a[15:10] == 6'b0100_11;                          // 4C00-4FFF
wire cs_ram  = cpu_a[15:12] == 4'h5;                                // 5000-5FFF
wire cs_ctl  = cpu_a[15:12] == 4'h8;                                // 8000-8FFF writes
wire cs_vec  = cpu_a >= 16'hFFF2 && cpu_a <= 16'hFFFD;              // IRQ vectors in RAM
wire cs_rom  = cpu_a >= 16'h6000;

assign cpu_rom_a = cpu_a;

// one write per bus cycle, at the end of E
wire wr = fall_e & ~cpu_rw;

// Sprite RAM: bank B (4000) = attribute / Y, bank A (4400) = X / code; 1K each, sprites use the first 0x30
logic [9:0] spr_ram_a;
logic [7:0] spra_cpu_d, sprb_cpu_d, spra_d, sprb_d;

dpram_dc #(.widthad_a(10)) ram_spra
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a(cpu_do), .wren_a(cs_spra & wr), .q_a(spra_cpu_d),
    .clock_b(clk), .address_b(spr_ram_a), .q_b(spra_d)
);

dpram_dc #(.widthad_a(10)) ram_sprb
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a(cpu_do), .wren_a(cs_sprb & wr), .q_a(sprb_cpu_d),
    .clock_b(clk), .address_b(spr_ram_a), .q_b(sprb_d)
);

// Colour / video RAM: CPU on port A, tile fetch on port B
logic [9:0] tile_ram_a;
logic [7:0] col_cpu_d, vid_cpu_d, col_d, vid_d;

dpram_dc #(.widthad_a(10)) ram_col
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a(cpu_do), .wren_a(cs_col & wr), .q_a(col_cpu_d),
    .clock_b(clk), .address_b(tile_ram_a), .q_b(col_d)
);

dpram_dc #(.widthad_a(10)) ram_vid
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a(cpu_do), .wren_a(cs_vid & wr), .q_a(vid_cpu_d),
    .clock_b(clk), .address_b(tile_ram_a), .q_b(vid_d)
);

// Work RAM 5000-5FFF; second port for the hiscore system
logic [7:0] ram_cpu_d;
wire        hs_cs = hs_address[15:12] == 4'h5;
dpram_dc #(.widthad_a(12)) ram_work
(
    .clock_a(clk), .address_a(cpu_a[11:0]), .data_a(cpu_do), .wren_a(cs_ram & wr), .q_a(ram_cpu_d),
    .clock_b(clk), .address_b(hs_address[11:0]), .data_b(hs_data_in), .wren_b(hs_cs & hs_write), .q_b(hs_data_out)
);

// IRQ vectors: written at 8182-818D, read back at FFF2-FFFD (the ROM holds FF there)
logic [7:0] vec[12];
wire  [3:0] vec_ra = cpu_a[3:0] - 4'd2;

// 3080-3083 by A1-A0 = system, P1, P2, DSW1; 3000 DSW2; 3100 DSW3
logic [7:0] io_d;
always_comb begin
    if      (cpu_a[8]) io_d = dsw2;
    else if (cpu_a[7]) case (cpu_a[1:0])
                           2'd0: io_d = in0;
                           2'd1: io_d = in1;
                           2'd2: io_d = in2;
                           2'd3: io_d = dsw0;
                       endcase
    else               io_d = dsw1;
end

wire patch_703d = rom_dec[0] && cpu_a == 16'h703D;

always_comb begin
    if      (cs_vec)     bus_d = vec[vec_ra];
    else if (patch_703d) bus_d = 8'h98 ^ 8'h22;
    else if (cs_rom)     bus_d = cpu_rom_d;
    else if (cs_io)      bus_d = io_d;
    else if (cs_sprb)    bus_d = sprb_cpu_d;
    else if (cs_spra)    bus_d = spra_cpu_d;
    else if (cs_col)     bus_d = col_cpu_d;
    else if (cs_vid)     bus_d = vid_cpu_d;
    else if (cs_ram)     bus_d = ram_cpu_d;
    else                 bus_d = 8'hFF;
end

logic [7:0] sound_latch = 8'h00;

assign wd_kick  = cs_ctl && wr && cpu_a[11:7] == 5'd0;
assign wd_reset = wd_rst;
wire  [7:0] vec_wa = cpu_a[7:0] - 8'h82;

always_ff @(posedge clk) begin
    if (cpu_rst) begin
        mainlatch <= 8'h00;
    end else if (cs_ctl && wr) begin
        if (cpu_a[11:0] >= 12'h080 && cpu_a[11:0] <= 12'h087) mainlatch[cpu_a[2:0]] <= cpu_do[0];
        if (cpu_a[11:0] == 12'h100) sound_latch <= cpu_do;
        if (cpu_a[11:0] >= 12'h182 && cpu_a[11:0] <= 12'h18D) vec[vec_wa[3:0]] <= cpu_do;
    end
end

// IRQ on vblank start while enabled; held until the enable is cleared
wire vblank_start = ce_pix && hcnt == 9'd128 && vcnt == 9'd496;
always_ff @(posedge clk) begin
    if (cpu_rst || !mainlatch[7]) irq_ff <= 1'b0;
    else if (vblank_start)      irq_ff <= 1'b1;
end

/////////////////////////////  Tile layer  /////////////////////////////

// The next column is fetched while the current one is shown; its data takes over on the last pixel of a column.
// Per column: planes 0/1 bytes for pixels 0-3 and 4-7, then planes 2/3 (second half of the ROM).
logic [7:0] fetch_x;
logic [7:0] fetch_y;
logic [3:0] fetch_st = 4'd0;
logic [7:0] nxt_attr, cur_attr;
logic [8:0] nxt_code;
logic [7:0] nxt_d[4], cur_d[4];
logic [2:0] nxt_row;

always_ff @(posedge clk) begin
    if (ce_pix && hcnt[2:0] == 3'd0) begin
        fetch_x  <= (hcnt[7:0] + 8'd8) ^ {8{tflip}};
        fetch_y  <= vcnt[7:0] ^ {8{tflip}};
        fetch_st <= 4'd1;
    end else begin
        case (fetch_st)
            4'd1: begin tile_ram_a <= {fetch_y[7:3], fetch_x[7:3]}; fetch_st <= 4'd2; end
            4'd2: fetch_st <= 4'd3;
            4'd3: begin
                nxt_attr <= col_d;
                nxt_code <= {col_d[7], vid_d};
                nxt_row  <= fetch_y[2:0] ^ {3{col_d[5]}};
                fetch_st <= 4'd4;
            end
            4'd4: begin tile_rom_a <= {1'b0, nxt_code, 1'b0, nxt_row}; fetch_st <= 4'd5; end
            4'd5: begin tile_rom_a <= {1'b0, nxt_code, 1'b1, nxt_row}; fetch_st <= 4'd6; end
            4'd6: begin tile_rom_a <= {1'b1, nxt_code, 1'b0, nxt_row}; nxt_d[0] <= tile_rom_d; fetch_st <= 4'd7; end
            4'd7: begin tile_rom_a <= {1'b1, nxt_code, 1'b1, nxt_row}; nxt_d[1] <= tile_rom_d; fetch_st <= 4'd8; end
            4'd8: begin nxt_d[2] <= tile_rom_d; fetch_st <= 4'd9; end
            4'd9: begin nxt_d[3] <= tile_rom_d; fetch_st <= 4'd0; end
            default: fetch_st <= 4'd0;
        endcase
    end

    if (ce_pix && hcnt[2:0] == 3'd7) begin
        cur_attr <= nxt_attr;
        cur_d    <= nxt_d;
    end
end

// Pixel within the tile: screen flip, then the tile's own X flip (attr bit 6)
wire [2:0] tpx  = hcnt[2:0] ^ {3{tflip}} ^ {3{cur_attr[6]}};
wire [7:0] tlo  = tpx[2] ? cur_d[1] : cur_d[0];
wire [7:0] thi  = tpx[2] ? cur_d[3] : cur_d[2];
wire [3:0] tpen = {thi[3 - tpx[1:0]], thi[7 - tpx[1:0]], tlo[3 - tpx[1:0]], tlo[7 - tpx[1:0]]};

/////////////////////////////  Sprites  /////////////////////////////

// Two line buffers of the sprite lookup PROM output (0 = transparent): one is shown (and cleared behind the
// beam) while the other is drawn with the next line. Buffer vcnt[0] is shown on line vcnt.
logic       rd_sel;                 // buffer being shown / cleared
logic       sp_buf;                 // buffer being drawn
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

// Sprite renderer: slots 23 down to 0 (MAME offs 0x2E..0x00), later slots drawn over earlier ones.
// X = 240 - bank A[offs], Y = bank B[offs + 1], code = bank A[offs + 1], attr = bank B[offs]
typedef enum logic [3:0] { SP_IDLE, SP_Y0, SP_Y1, SP_Y2, SP_A0, SP_A1, SP_A2, SP_G0, SP_G1, SP_G2, SP_G3,
                           SP_P0, SP_P1, SP_P2 } sp_state_t;
sp_state_t  sp_st = SP_IDLE;
logic [4:0] sp_slot;
logic [7:0] sp_line;
logic [7:0] sp_code, sp_attr;
logic [9:0] sp_x;                                                   // signed: 240 - X can go below 0
logic [3:0] sp_row;
logic [1:0] sp_grp;
logic [1:0] sp_k;
logic [7:0] sp_lo, sp_hi;
logic [9:0] sp_wpx;

wire [8:0]  sp_dy   = {1'b0, sp_line} - {1'b0, sprb_d};             // line - Y
wire [3:0]  sp_srcx = {sp_grp, sp_k};
wire [3:0]  sp_dx   = sp_attr[6] ? ~sp_srcx : sp_srcx;              // attr bit 6 set = X flipped
wire [9:0]  sp_px   = sp_x + {6'd0, sp_dx};
wire [3:0]  sp_pen  = {sp_hi[3 - sp_k], sp_hi[7 - sp_k], sp_lo[3 - sp_k], sp_lo[7 - sp_k]};
wire [14:0] sp_rom  = {1'b0, sp_code, sp_row[3], sp_grp, sp_row[2:0]};

always_ff @(posedge clk) begin
    lb_wr <= 1'b0;
    case (sp_st)
        SP_IDLE: ;
        SP_Y0: begin spr_ram_a <= {4'd0, sp_slot, 1'b1}; sp_st <= SP_Y1; end
        SP_Y1: sp_st <= SP_Y2;
        SP_Y2: begin
            if (sp_dy[8:4] == 5'd0) begin
                sp_row    <= sp_dy[3:0];
                spr_ram_a <= {4'd0, sp_slot, 1'b0};
                sp_st     <= SP_A0;
            end else if (sp_slot == 5'd0)
                sp_st <= SP_IDLE;
            else begin
                sp_slot <= sp_slot - 5'd1;
                sp_st   <= SP_Y0;
            end
        end
        SP_A0: begin spr_ram_a <= {4'd0, sp_slot, 1'b1}; sp_st <= SP_A1; end
        SP_A1: begin sp_x <= 10'd240 - {2'b00, spra_d}; sp_attr <= sprb_d; sp_st <= SP_A2; end
        SP_A2: begin
            sp_code <= spra_d;
            if (!sp_attr[7]) sp_row <= ~sp_row;                          // attr bit 7 clear = Y flipped
            sp_grp  <= 2'd0;
            sp_st   <= SP_G0;
        end
        SP_G0: begin spr_rom_a <= sp_rom; sp_st <= SP_G1; end
        SP_G1: begin spr_rom_a <= sp_rom | 15'h4000; sp_st <= SP_G2; end
        SP_G2: begin sp_lo <= spr_rom_d; sp_st <= SP_G3; end
        SP_G3: begin sp_hi <= spr_rom_d; sp_k <= 2'd0; sp_st <= SP_P0; end
        // per pixel: lookup PROM address, wait, write if the lookup is not 0
        SP_P0: begin slut_a <= {sp_attr[3:0], sp_pen}; sp_wpx <= sp_px; sp_st <= SP_P1; end
        SP_P1: sp_st <= SP_P2;
        SP_P2: begin
            if (sp_wpx[9:8] == 2'b00 && slut_d[3:0] != 4'd0) begin
                lb_wr_a <= sp_wpx[7:0] ^ {8{crt_flip}};
                lb_wr_d <= {4'd0, slut_d[3:0]};
                lb_wr   <= 1'b1;
            end
            sp_k <= sp_k + 2'd1;
            if (sp_k != 2'd3)
                sp_st <= SP_P0;
            else begin
                sp_grp <= sp_grp + 2'd1;
                if (sp_grp != 2'd3)
                    sp_st <= SP_G0;
                else if (sp_slot == 5'd0)
                    sp_st <= SP_IDLE;
                else begin
                    sp_slot <= sp_slot - 5'd1;
                    sp_st   <= SP_Y0;
                end
            end
        end
        default: sp_st <= SP_IDLE;
    endcase

    // a new line starts: draw the line after it
    if (ce_pix && hcnt == 9'd128) begin
        sp_line <= (vcnt[7:0] + 8'd1) ^ {8{crt_flip}};
        sp_buf  <= ~vcnt[0];
        sp_slot <= 5'd23;
        sp_st   <= SP_Y0;
    end
end

/////////////////////////////  Mixer / palette  /////////////////////////////

// Pixel H is captured on its ce_pix edge and leaves as RGB on the next one:
// line buffer + char lookup PROM, then the palette PROM (sprites and chars both index entries 0-15)
logic [3:0] s1_tcol, s1_tpen;
logic       hs_d, vs_d, hb_d, vb_d;
logic [2:0] mix_st = 3'd0;
logic       s2_spr;
logic [3:0] s2_sv;

always_ff @(posedge clk) begin
    clr_wr <= 1'b0;

    if (ce_pix) begin
        s1_tcol <= cur_attr[3:0];
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
            3'd1: begin clut_a <= {s1_tcol, s1_tpen}; mix_st <= 3'd2; end
            3'd2: begin
                if (!hb_d) clr_wr <= 1'b1;              // erase behind the beam (visible pixels only)
                s2_spr <= lb_q[3:0] != 4'd0;
                s2_sv  <= lb_q[3:0];
                mix_st <= 3'd3;
            end
            3'd3: begin pal_a <= {1'b0, s2_spr ? s2_sv : clut_d[3:0]}; mix_st <= 3'd4; end
            3'd4: mix_st <= 3'd5;
            3'd5: mix_st <= 3'd0;
            default: mix_st <= 3'd0;
        endcase
    end
end

// Resistor DAC: R/G 1K / 470 / 220, B 470 / 220, 1K pull-down (MAME compute_resistor_weights)
function automatic [7:0] dac3(input [2:0] b);
    case (b)
        3'd0: dac3 = 8'd0;   3'd1: dac3 = 8'd33;  3'd2: dac3 = 8'd71;  3'd3: dac3 = 8'd104;
        3'd4: dac3 = 8'd151; 3'd5: dac3 = 8'd184; 3'd6: dac3 = 8'd222; default: dac3 = 8'd255;
    endcase
endfunction

function automatic [7:0] dac2(input [1:0] b);
    case (b)
        2'd0: dac2 = 8'd0; 2'd1: dac2 = 8'd80; 2'd2: dac2 = 8'd171; default: dac2 = 8'd251;
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

/////////////////////////////  Sound board (shared, in konami82_board)  /////////////////////////////

assign snd_latch = sound_latch;
assign snd_irq   = mainlatch[1];
assign snd_mute  = mainlatch[2];

endmodule
