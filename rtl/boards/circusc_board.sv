//============================================================================
//
//  Konami Circus Charlie board (GX380: PWB(A)3000161 CPU/video + PWB(B)3000148 sound)
//  Copyright (C) 2026 Rodimus
//
//  Written from the Circus Charlie schematics and MAME circusc.cpp (Nicola Salmoria, Chris Hardy,
//  Couriersud). Main CPU is the KONAMI-1, modelled as on the Roc'n Rope board: Greg Miller's MC6809
//  (unmodified, shared in rtl/konami82_board.sv) plus an external opcode decrypter.
//
//  ioctl index 0 (MRA), images stored as dumped:
//    0x00000 - 0x07FFF  sprites 0x0000-0x7FFF (shared block 0)
//    0x08000 - 0x0BFFF  (Time Pilot sound board window, unused here)
//    0x0C000 - 0x0FFFF  tiles (shared block 1)
//    0x10000 - 0x13FFF  audiocpu 0000-3FFF (shared block 2, second port: rtl/sound/circusc_sound.sv)
//    0x16000 - 0x1FFFF  maincpu 6000-FFFF (shared block 2)
//    0x20000 - 0x23FFF  sprites 0x8000-0xBFFF (this board)
//    0x24000 - 0x2401F  palette PROM j18   0x24020 - 0x2411F  char lookup j17   0x24120 - 0x2421F  sprite lookup j16
//
//============================================================================

module circusc_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    output logic        ce_pix,

    input  logic  [7:0] in0,            // $1000 system
    input  logic  [7:0] in1,            // $1001 player 1
    input  logic  [7:0] in2,            // $1002 player 2
    input  logic  [7:0] dsw0,           // $1400 DSW1 coinage
    input  logic  [7:0] dsw1,           // $1800 DSW2

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

    output logic  [7:0] snd_latch,      // to rtl/sound/circusc_sound.sv
    output logic        snd_irq,        // one clock per SOUND-ON write

    output chip_pool_pkg::m6809r_i_t m6809_0_i,          // shared MC6809E (rtl/konami82_board.sv)
    input  chip_pool_pkg::m6809r_o_t m6809_0_o,
    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

/////////////////////////////  ROM storage  /////////////////////////////

wire load_sprhi = ioctl_wr0 && ioctl_addr[24:14] == 11'h008;     // 0x20000-0x23FFF
wire load_prom  = ioctl_wr0 && ioctl_addr[24:10] == 15'h0090;    // 0x24000-0x243FF
wire load_pal   = load_prom && ioctl_addr[9:5] == 5'd0;          // j18
wire [9:0] clut_dl = ioctl_addr[9:0] - 10'h020;
wire [9:0] slut_dl = ioctl_addr[9:0] - 10'h120;
wire load_clut  = load_prom && ioctl_addr[9:0] >= 10'h020 && ioctl_addr[9:0] < 10'h120;
wire load_slut  = load_prom && ioctl_addr[9:0] >= 10'h120 && ioctl_addr[9:0] < 10'h220;

logic [15:0] cpu_rom_a;
logic  [7:0] cpu_rom_d;
assign rom2_a    = cpu_rom_a;                // CPU ROM in shared block 2
assign cpu_rom_d = rom2_d;

logic [14:0] spr_rom_a;
logic  [7:0] spr_rom_d;
assign rom0_a    = spr_rom_a;                // sprites 0x0000-0x7FFF in shared block 0
assign spr_rom_d = rom0_d;

logic [13:0] tile_rom_a;
logic  [7:0] tile_rom_d;
assign rom1_a     = tile_rom_a;              // tiles in shared block 1
assign tile_rom_d = rom1_d;

logic [13:0] sprhi_a;
logic  [7:0] sprhi_d;
dpram_dc #(.widthad_a(14)) rom_sprhi                // sprites 0x8000-0xBFFF
(
    .clock_a(clk), .address_a(ioctl_addr[13:0]), .data_a(ioctl_dout), .wren_a(load_sprhi),
    .clock_b(clk), .address_b(sprhi_a), .q_b(sprhi_d)
);

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
// The hiscore system borrows a CPU RAM port while the CPU is paused; pause_x holds the CPU two clocks longer so
// its first read after a pause sees its own address again.
logic [1:0] pause_d = 2'b00;
always_ff @(posedge clk) pause_d <= {pause_d[0], pause};
wire pause_x = pause | (|pause_d);

wire   fall_q = (div == 5'd23) & ~pause_x;    // Q falls a quarter cycle before E
wire   fall_e = (div == 5'd31) & ~pause_x;

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

// Watchdog (LS293 12G): counts frames at vblank start (frozen while paused), cleared by a WDOG write (0400-07FF). QD (8 frames without
// a kick) holds the KONAMI-1 and LS259 2C in reset for 8 frames, then the count wraps (schematic). Video timing keeps running.
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

wire vblank_start = ce_pix && hcnt == 9'd128 && vcnt == 9'd496;

// Main latch (LS259 2C): Q0 FLIP, Q1 INTST (IRQ enable), Q2 MUT (unused), Q3/Q4 coin counters, Q5 OBJ CHENG
logic [7:0] mainlatch = 8'h00;
wire flip = mainlatch[0] ^ crt_flip;           // the game's flip turns tiles and sprites together

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

wire cs_latch = cpu_a[15:10] == 6'b0000_00;                         // 0000-03FF LS259 (A2-A0)
wire cs_slat  = cpu_a[15:10] == 6'b0000_10;                         // 0800-0BFF sound data
wire cs_son   = cpu_a[15:10] == 6'b0000_11;                         // 0C00-0FFF SOUND-ON
wire cs_in    = cpu_a[15:10] == 6'b0001_00;                         // 1000-13FF system / P1 / P2 by A1-A0
wire cs_dsw1  = cpu_a[15:10] == 6'b0001_01;                         // 1400-17FF
wire cs_dsw2  = cpu_a[15:10] == 6'b0001_10;                         // 1800-1BFF
wire cs_scrl  = cpu_a[15:10] == 6'b0001_11;                         // 1C00-1FFF VGAP (scroll)
wire cs_ram   = cpu_a[15:12] == 4'h2;                               // 2000-2FFF
wire cs_col   = cpu_a[15:10] == 6'b0011_00;                         // 3000-33FF
wire cs_vid   = cpu_a[15:10] == 6'b0011_01;                         // 3400-37FF
wire cs_obj   = cpu_a[15:11] == 5'b0011_1;                          // 3800-3BFF, mirrored at 3C00-3FFF
wire cs_rom   = cpu_a >= 16'h6000;
wire cs_wdog  = cpu_a[15:10] == 6'b0000_01;                         // 0400-07FF WDOG

assign cpu_rom_a = cpu_a;

// one write per bus cycle, at the end of E
wire wr = fall_e & ~cpu_rw;

// Colour / video RAM: CPU on port A, tile fetch on port B. Video RAM port A is the hiscore system's while paused
// (the shown hiscore digits).
logic [9:0] tile_ram_a;
logic [7:0] col_cpu_d, vid_cpu_d, col_d, vid_d, hs_work_d;
wire        hs_vid = hs_address[15:10] == 6'b0011_01;

dpram_dc #(.widthad_a(10)) ram_col
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a(cpu_do), .wren_a(cs_col & wr), .q_a(col_cpu_d),
    .clock_b(clk), .address_b(tile_ram_a), .q_b(col_d)
);

dpram_dc #(.widthad_a(10)) ram_vid
(
    .clock_a(clk), .address_a(pause ? hs_address[9:0] : cpu_a[9:0]), .data_a(pause ? hs_data_in : cpu_do),
    .wren_a(pause ? hs_vid & hs_write : cs_vid & wr), .q_a(vid_cpu_d),
    .clock_b(clk), .address_b(tile_ram_a), .q_b(vid_d)
);

// Sprite RAM: 2114 x 2 = 1K on A9-A0 (schematic; MAME maps separate RAM at 3A00-3FFF), sprite banks at 3800 / 3900.
// Port B feeds the sprite buffer copy.
logic  [9:0] obj_cp_a;
logic  [7:0] obj_cpu_d, obj_cp_d;
dpram_dc #(.widthad_a(10)) ram_obj
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a(cpu_do), .wren_a(cs_obj & wr), .q_a(obj_cpu_d),
    .clock_b(clk), .address_b(obj_cp_a), .q_b(obj_cp_d)
);

// Work RAM 2000-2FFF; second port for the hiscore system
logic [7:0] ram_cpu_d;
wire        hs_cs = hs_address[15:12] == 4'h2;
dpram_dc #(.widthad_a(12)) ram_work
(
    .clock_a(clk), .address_a(cpu_a[11:0]), .data_a(cpu_do), .wren_a(cs_ram & wr), .q_a(ram_cpu_d),
    .clock_b(clk), .address_b(hs_address[11:0]), .data_b(hs_data_in), .wren_b(hs_cs & hs_write), .q_b(hs_work_d)
);

assign hs_data_out = hs_vid ? vid_cpu_d : hs_work_d;

always_comb begin
    if      (cs_rom)  bus_d = cpu_rom_d;
    else if (cs_in)   case (cpu_a[1:0])
                          2'd0: bus_d = in0;
                          2'd1: bus_d = in1;
                          2'd2: bus_d = in2;
                          2'd3: bus_d = 8'hFF;              // unpopulated DIPSW 3
                      endcase
    else if (cs_dsw1) bus_d = dsw0;
    else if (cs_dsw2) bus_d = dsw1;
    else if (cs_ram)  bus_d = ram_cpu_d;
    else if (cs_col)  bus_d = col_cpu_d;
    else if (cs_vid)  bus_d = vid_cpu_d;
    else if (cs_obj)  bus_d = obj_cpu_d;
    else              bus_d = 8'hFF;
end

logic [7:0] sound_latch = 8'h00;

assign wd_kick = cs_wdog & wr;
logic [7:0] scroll = 8'h00;
logic       son = 1'b0;

always_ff @(posedge clk) begin
    son <= 1'b0;
    if (cpu_rst) begin
        mainlatch <= 8'h00;
    end else if (wr) begin
        if (cs_latch) mainlatch[cpu_a[2:0]] <= cpu_do[0];
        if (cs_slat)  sound_latch <= cpu_do;
        if (cs_son)   son <= 1'b1;
        if (cs_scrl)  scroll <= cpu_do;
    end
end

// IRQ on vblank start while enabled; held until the enable is cleared
always_ff @(posedge clk) begin
    if (cpu_rst || !mainlatch[1]) irq_ff <= 1'b0;
    else if (vblank_start)      irq_ff <= 1'b1;
end

/////////////////////////////  Sprite buffer  /////////////////////////////

// At vblank start the bank chosen by OBJ CHENG (3800 or 3900) is copied to a 0x100 buffer, drawn next frame
// (MAME buffered_spriteram8). The board instead reads sprite n live on line 4n into a DRAM framebuffer shown
// the next frame: same one-frame delay, differs only if the game writes the bank being drawn.
// Read address issued on one clock, data written two clocks later.
logic [8:0] cp_cnt = 9'd256;
logic [7:0] cp_wa[2];
logic       cp_v[2];
logic [7:0] sbuf_a, sbuf_d;

dpram_dc #(.widthad_a(8)) ram_sbuf
(
    .clock_a(clk), .address_a(cp_wa[1]), .data_a(obj_cp_d), .wren_a(cp_v[1]),
    .clock_b(clk), .address_b(sbuf_a), .q_b(sbuf_d)
);

always_ff @(posedge clk) begin
    cp_v[0]  <= ~cp_cnt[8];
    cp_wa[0] <= cp_cnt[7:0];
    cp_v[1]  <= cp_v[0];
    cp_wa[1] <= cp_wa[0];
    if (vblank_start)    cp_cnt <= 9'd0;
    else if (~cp_cnt[8]) cp_cnt <= cp_cnt + 9'd1;
    obj_cp_a <= {1'b0, mainlatch[5], cp_cnt[7:0]};
end

/////////////////////////////  Tile layer  /////////////////////////////

// The next column is fetched while the current one is shown; its data takes over on the last pixel of a column.
// Tiles are drawn in tilemap (unflipped) coordinates: screen x / y XOR 255 when flipped. Tilemap columns 10-31
// scroll vertically by VGAP, columns 0-9 stay fixed (MAME set_scrolly per column).
// Per tile row: 4 bytes of 2 pixels, high nibble first (8x8x4 packed MSB).
logic [7:0] fetch_x;
logic [7:0] fetch_y;
logic [2:0] fetch_row;
logic [3:0] fetch_st = 4'd0;
logic [7:0] nxt_attr, cur_attr;
logic [8:0] nxt_code;
logic [7:0] nxt_d[4], cur_d[4];
logic [2:0] nxt_row;

wire [7:0] scrolled_y = fetch_y + scroll;

always_ff @(posedge clk) begin
    if (ce_pix && hcnt[2:0] == 3'd0) begin
        fetch_x  <= (hcnt[7:0] + 8'd8) ^ {8{flip}};
        fetch_y  <= vcnt[7:0] ^ {8{flip}};
        fetch_st <= 4'd1;
    end else begin
        case (fetch_st)
            4'd1: begin
                if (fetch_x[7:3] >= 5'd10) begin
                    tile_ram_a <= {scrolled_y[7:3], fetch_x[7:3]};
                    fetch_row  <= scrolled_y[2:0];
                end else begin
                    tile_ram_a <= {fetch_y[7:3], fetch_x[7:3]};
                    fetch_row  <= fetch_y[2:0];
                end
                fetch_st <= 4'd2;
            end
            4'd2: fetch_st <= 4'd3;
            4'd3: begin
                nxt_attr <= col_d;
                nxt_code <= {col_d[5], vid_d};
                nxt_row  <= fetch_row ^ {3{col_d[7]}};                  // attr bit 7 = Y flip
                fetch_st <= 4'd4;
            end
            4'd4: begin tile_rom_a <= {nxt_code, nxt_row, 2'd0}; fetch_st <= 4'd5; end
            4'd5: begin tile_rom_a <= {nxt_code, nxt_row, 2'd1}; fetch_st <= 4'd6; end
            4'd6: begin tile_rom_a <= {nxt_code, nxt_row, 2'd2}; nxt_d[0] <= tile_rom_d; fetch_st <= 4'd7; end
            4'd7: begin tile_rom_a <= {nxt_code, nxt_row, 2'd3}; nxt_d[1] <= tile_rom_d; fetch_st <= 4'd8; end
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
wire [2:0] tpx  = hcnt[2:0] ^ {3{flip}} ^ {3{cur_attr[6]}};
wire [7:0] tbyt = cur_d[tpx[2:1]];
wire [3:0] tpen = tpx[0] ? tbyt[3:0] : tbyt[7:4];

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

// Sprite renderer: 64 sprites of 4 bytes (code, attr, X, Y), slot 0 first, later slots drawn over earlier
// ones (MAME draw order). attr: bits 3-0 colour, 5 code bit 8, 6 X flip, 7 Y flip. Drawn in unflipped
// coordinates; the line buffer is written at X XOR 255 when flipped. 16x16x4 packed MSB: 8 bytes per row.
typedef enum logic [3:0] { SP_IDLE, SP_Y0, SP_Y1, SP_Y2, SP_A0, SP_A1, SP_A2, SP_A3, SP_PIX } sp_state_t;
sp_state_t  sp_st = SP_IDLE;
logic [5:0] sp_slot;
logic [7:0] sp_line;
logic [7:0] sp_attr;
logic [8:0] sp_code;
logic [7:0] sp_x;
logic [3:0] sp_row;
logic [4:0] sp_k;

wire [8:0] sp_dy = {1'b0, sp_line} - {1'b0, sbuf_d};                // line - Y

// pixel pipeline: issue (ROM address) -> +2 ROM data, lookup PROM address -> +2 lookup data, line buffer write
wire [3:0] sp_src = sp_attr[6] ? ~sp_k[3:0] : sp_k[3:0];            // attr bit 6 = X flipped
wire [15:0] sp_ra = {sp_code, sp_row, sp_src[3:1]};
logic       p_v[2], q_v[2];
logic       p_lo[2];
logic [1:0] p_sel[2];
logic [3:0] p_col[2];
logic [8:0] p_x[2], q_x[2];

wire [7:0] p_byte = p_sel[1][1] ? sprhi_d : spr_rom_d;               // 0x0000-0x7FFF shared block, 0x8000-0xBFFF here
wire [3:0] p_pen  = p_lo[1] ? p_byte[3:0] : p_byte[7:4];

always_ff @(posedge clk) begin
    // stage 1: one pixel issued per clock in SP_PIX
    p_v[0]   <= sp_st == SP_PIX && sp_ra[15:14] != 2'b11;           // codes past the six ROMs: nothing
    p_lo[0]  <= sp_src[0];
    p_sel[0] <= sp_ra[15:14];
    p_col[0] <= sp_attr[3:0];
    p_x[0]   <= {1'b0, sp_x} + {5'd0, sp_k[3:0]};
    spr_rom_a <= sp_ra[14:0];
    sprhi_a   <= sp_ra[13:0];
    p_v[1] <= p_v[0]; p_lo[1] <= p_lo[0]; p_sel[1] <= p_sel[0]; p_col[1] <= p_col[0]; p_x[1] <= p_x[0];
    // stage 2: ROM data -> lookup PROM
    slut_a <= {p_col[1], p_pen};
    q_v[0] <= p_v[1];
    q_x[0] <= p_x[1];
    q_v[1] <= q_v[0];
    q_x[1] <= q_x[0];
    // stage 3: lookup data -> line buffer, clipped at the right edge, transparent where the lookup is 0
    lb_wr   <= q_v[1] && !q_x[1][8] && slut_d[3:0] != 4'd0;
    lb_wr_a <= q_x[1][7:0] ^ {8{flip}};
    lb_wr_d <= {4'd0, slut_d[3:0]};
end

always_ff @(posedge clk) begin
    case (sp_st)
        SP_IDLE: ;
        SP_Y0: begin sbuf_a <= {sp_slot, 2'd3}; sp_st <= SP_Y1; end
        SP_Y1: sp_st <= SP_Y2;
        SP_Y2: begin
            if (sp_dy[8:4] == 5'd0) begin
                sp_row <= sp_dy[3:0];
                sbuf_a <= {sp_slot, 2'd1};
                sp_st  <= SP_A0;
            end else if (sp_slot == 6'd63)
                sp_st <= SP_IDLE;
            else begin
                sp_slot <= sp_slot + 6'd1;
                sp_st   <= SP_Y0;
            end
        end
        SP_A0: begin sbuf_a <= {sp_slot, 2'd0}; sp_st <= SP_A1; end
        SP_A1: begin sp_attr <= sbuf_d; sbuf_a <= {sp_slot, 2'd2}; sp_st <= SP_A2; end
        SP_A2: begin sp_code <= {sp_attr[5], sbuf_d}; sp_st <= SP_A3; end
        SP_A3: begin
            sp_x <= sbuf_d;
            if (sp_attr[7]) sp_row <= ~sp_row;                           // attr bit 7 = Y flipped
            sp_k  <= 5'd0;
            sp_st <= SP_PIX;
        end
        SP_PIX: begin
            sp_k <= sp_k + 5'd1;
            if (sp_k == 5'd15) begin
                if (sp_slot == 6'd63)
                    sp_st <= SP_IDLE;
                else begin
                    sp_slot <= sp_slot + 6'd1;
                    sp_st   <= SP_Y0;
                end
            end
        end
        default: sp_st <= SP_IDLE;
    endcase

    // a new line starts: draw the line after it
    if (ce_pix && hcnt == 9'd128) begin
        sp_line <= (vcnt[7:0] + 8'd1) ^ {8{flip}};
        sp_buf  <= ~vcnt[0];
        sp_slot <= 6'd0;
        sp_st   <= SP_Y0;
    end
end

/////////////////////////////  Mixer / palette  /////////////////////////////

// Pixel H is captured on its ce_pix edge and leaves as RGB on the next one: line buffer + char lookup PROM, then
// the palette PROM (sprites entries 0-15, chars 16-31). Tiles with attr bit 4 set are drawn behind the sprites,
// the others over them, opaque (MAME draws category 1, sprites, then category 0).
logic [3:0] s1_tcol, s1_tpen;
logic       s1_tcat;
logic       hs_d, vs_d, hb_d, vb_d;
logic [2:0] mix_st = 3'd0;
logic       s2_spr;
logic [3:0] s2_sv;

always_ff @(posedge clk) begin
    clr_wr <= 1'b0;

    if (ce_pix) begin
        s1_tcol <= cur_attr[3:0];
        s1_tcat <= cur_attr[4];
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
                s2_spr <= s1_tcat && lb_q[3:0] != 4'd0;
                s2_sv  <= lb_q[3:0];
                mix_st <= 3'd3;
            end
            3'd3: begin pal_a <= s2_spr ? {1'b0, s2_sv} : {1'b1, clut_d[3:0]}; mix_st <= 3'd4; end
            3'd4: mix_st <= 3'd5;
            3'd5: mix_st <= 3'd0;
            default: mix_st <= 3'd0;
        endcase
    end
end

// Resistor DAC: R/G 1K / 470 / 220, B 470 / 220, 1K pull-down on each output (schematic; MAME has none)
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

/////////////////////////////  Sound board (rtl/sound/circusc_sound.sv)  /////////////////////////////

assign snd_latch = sound_latch;
assign snd_irq   = son;

endmodule
