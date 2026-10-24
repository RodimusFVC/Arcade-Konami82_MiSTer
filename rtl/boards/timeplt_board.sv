//============================================================================
//
//  Konami Time Pilot board (Centuri KT-5201-1B CPU board + sound board)
//  Copyright (C) 2026 Rodimus
//
//  Written from the Time Pilot schematics and MAME timeplt.cpp (Nicola Salmoria).
//  The Konami customs (082 sync, 083 shifters, 501 bus, 502/503 sprites) are
//  modelled by function, not by internal structure.
//
//  Same board, runtime-selected by `sub` (MRA variant byte, rtl/konami82_board.sv):
//    0 Time Pilot (timeplt.cpp timeplt_state)
//    1 Power Surge (psurge_state): protection read 6004 = 80, NMI every vblank, no video enable
//    2 Bikkuri Card (bikkuric_state): RAM 6000-67FF, 10-bit tile codes from attr 6-5, no tile flip,
//      tile priority = attr 7, sprite planes swapped, 128 sprites, coin hopper on latch Q5 / IN1 bit 1
//    3 Chance Kun (chkun_state): as Bikkuri Card with 256 sprites
//
//  ROM windows (banked ROM store, rtl/konami82_board.sv; PROMs load from index 0 at their window address),
//  images stored as dumped, MAME region order:
//    0x00000 - 0x07FFF  maincpu
//    0x08000 - 0x0BFFF  timeplt_audio:tpsound
//    0x0C000 - 0x0FFFF  tiles
//    0x10000 - 0x13FFF  sprites
//    0x14000 - 0x1401F  palette PROM B4     0x14020 - 0x1403F  palette PROM B5
//    0x14040 - 0x1413F  sprite lookup E9    0x14140 - 0x1423F  char lookup E12
//
//============================================================================

module timeplt_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic  [1:0] sub,            // 0 Time Pilot, 1 Power Surge, 2 Bikkuri Card, 3 Chance Kun
    output logic        ce_pix,

    input  logic  [7:0] in0,            // $C300 system
    input  logic  [7:0] in1,            // $C320 player 1
    input  logic  [7:0] in2,            // $C340 player 2
    input  logic  [7:0] dsw0,           // $C360 coinage
    input  logic  [7:0] dsw1,           // $C200

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    output logic [14:0] rom0_a,         // banked ROM store (rtl/konami82_board.sv): window 0x00000-0x07FFF
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

    output chip_pool_pkg::z80r_i_t   z80_0_i,          // shared Z80 (rtl/konami82_board.sv)
    input  chip_pool_pkg::z80r_o_t   z80_0_o,
    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write,

    output logic [14:0] fba_wa,         // CRT Flip frame buffer A = the Tutankham bitmap RAM (rtl/konami82_board.sv)
    output logic  [9:0] fba_wd,
    output logic        fba_we,
    output logic [14:0] fba_ra,
    input  logic  [9:0] fba_q
);

/////////////////////////////  ROM storage  /////////////////////////////

wire load_prom = ioctl_wr0 && ioctl_addr[24:10] == 15'h0050;    // 0x14000-0x143FF
wire load_pal0 = load_prom && ioctl_addr[9:5] == 5'd0;          // B4
wire load_pal1 = load_prom && ioctl_addr[9:5] == 5'd1;          // B5
wire [9:0] lut_dl = ioctl_addr[9:0] - 10'h040;
wire load_lut  = load_prom && ioctl_addr[9:0] >= 10'h040 && ioctl_addr[9:0] < 10'h240;

logic [14:0] cpu_rom_a;
logic  [7:0] cpu_rom_d;
assign rom0_a    = cpu_rom_a;                // CPU ROM in ROM window 0
assign cpu_rom_d = rom0_d;

logic [13:0] tile_rom_a;
logic  [7:0] tile_rom_d;
assign rom1_a     = tile_rom_a;              // tiles in ROM window 1
assign tile_rom_d = rom1_d;

logic [13:0] spr_rom_a;
logic  [7:0] spr_rom_d;
assign rom2_a    = {2'b00, spr_rom_a};       // sprites in ROM window 2
assign spr_rom_d = rom2_d;

// Lookup PROMs: 0x000-0x0FF sprites (E9), 0x100-0x1FF chars (E12); low nibble used
logic [8:0] lut_a;
logic [7:0] lut_d;
dpram_dc #(.widthad_a(9)) prom_lut
(
    .clock_a(clk), .address_a(lut_dl[8:0]), .data_a(ioctl_dout), .wren_a(load_lut),
    .clock_b(clk), .address_b(lut_a), .q_b(lut_d)
);

logic [4:0] pal_a;
logic [7:0] pal0_d, pal1_d;
dpram_dc #(.widthad_a(5)) prom_pal0
(
    .clock_a(clk), .address_a(ioctl_addr[4:0]), .data_a(ioctl_dout), .wren_a(load_pal0),
    .clock_b(clk), .address_b(pal_a), .q_b(pal0_d)
);

dpram_dc #(.widthad_a(5)) prom_pal1
(
    .clock_a(clk), .address_a(ioctl_addr[4:0]), .data_a(ioctl_dout), .wren_a(load_pal1),
    .clock_b(clk), .address_b(pal_a), .q_b(pal1_d)
);

/////////////////////////////  Clocks  /////////////////////////////

// 18.432 MHz / 3 = 6.144 MHz pixel clock = 49.152 / 8; Z80 3.072 MHz = pixel / 2
logic [3:0] div = 4'd0;
always_ff @(posedge clk) div <= div + 4'd1;

assign ce_pix = (div[2:0] == 3'd7);
// The hiscore system borrows a CPU RAM port while the CPU is paused; pause_x holds the CPU two clocks longer so
// its first read after a pause sees its own address again.
logic [1:0] pause_d = 2'b00;
always_ff @(posedge clk) pause_d <= {pause_d[0], pause};
wire pause_x = pause | (|pause_d);

wire   cpu_ce = (div == 4'd15) & ~pause_x;

/////////////////////////////  Video timing (082)  /////////////////////////////

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

// Watchdog (LS293 G12): counts frames at vblank start (frozen while paused), cleared by a C200 write (C000-CFFF, A9-A8 = 10). QD (8 frames without
// a kick) holds the Z80 and LS259 B3 (and the sound board) in reset for 8 frames, then the count wraps (schematic). Video timing keeps running.
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

// Main latch (LS259 B3): Q0 NMI enable, Q1 /flip, Q2 sound IRQ, Q3 sound mute, Q4 video enable, Q5/Q6 coin counters
logic [7:0] mainlatch = 8'h00;
wire is_ps     = sub == 2'd1;                 // Power Surge
wire is_bk     = sub[1];                       // Bikkuri Card / Chance Kun board
logic hop_status = 1'b0;                       // coin hopper status line (see below)
wire tflip     = ~mainlatch[1];                // MAME flips only the tilemap with the game's flip; CRT Flip = frame buffer below
wire video_en  = mainlatch[4] | is_ps;         // Power Surge has no video enable

/////////////////////////////  Main CPU  /////////////////////////////

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

wire mem    = ~cpu_mreq_n & cpu_rfsh_n;
wire cs_rom = mem && cpu_a < 16'h6000;
wire cs_col = mem && cpu_a[15:10] == 6'b1010_00;                 // A000-A3FF
wire cs_vid = mem && cpu_a[15:10] == 6'b1010_01;                 // A400-A7FF
wire cs_ram = mem && cpu_a[15:11] == 5'b1010_1;                  // A800-AFFF
wire cs_spr = mem && cpu_a[15:12] == 4'hB;                       // B000-BFFF, A10 selects bank
wire cs_io  = mem && cpu_a[15:12] == 4'hC;
wire cs_xram = mem && is_bk && cpu_a[15:11] == 5'b0110_0;         // 6000-67FF (Bikkuri Card / Chance Kun)
wire cs_prot = mem && is_ps && cpu_a == 16'h6004;                // Power Surge protection, reads 80

assign cpu_rom_a = cpu_a[14:0];

wire wr_strobe = ~cpu_wr_n;
logic wr_d = 1'b0;
always_ff @(posedge clk) wr_d <= wr_strobe;
wire wr_edge = wr_strobe & ~wr_d;

// Colour / video RAM (2114 x 4): CPU on port A, tile fetch on port B
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

// Work RAM (2128); second port for the hiscore system
logic [7:0] ram_cpu_d, hs_work_d;
wire        hs_cs  = hs_address[15:11] == 5'b1010_1;
wire        hs_spr = hs_address[15:12] == 4'hB && !hs_address[10];       // sprite bank 1 (Power Surge's table)
dpram_dc #(.widthad_a(11)) ram_work
(
    .clock_a(clk), .address_a(cpu_a[10:0]), .data_a(cpu_do), .wren_a(cs_ram & wr_strobe), .q_a(ram_cpu_d),
    .clock_b(clk), .address_b(hs_address[10:0]), .data_b(hs_data_in), .wren_b(hs_cs & hs_write), .q_b(hs_work_d)
);

logic [7:0] xram_d;
spram #(.ADDR_WIDTH(11)) ram_x
(
    .clk(clk), .addr(cpu_a[10:0]), .data(cpu_do), .we(cs_xram & wr_strobe), .q(xram_d)
);

// Sprite RAM: bank 1 (B000, A10=0) = X / code, bank 2 (B400, A10=1) = attribute / Y. Bank 1 port A is the hiscore
// system's while paused.
logic [7:0] spr_ram_a;
logic [7:0] spr1_cpu_d, spr2_cpu_d, spr1_d, spr2_d;

dpram_dc #(.widthad_a(8)) ram_spr1
(
    .clock_a(clk), .address_a(pause ? hs_address[7:0] : cpu_a[7:0]), .data_a(pause ? hs_data_in : cpu_do),
    .wren_a(pause ? hs_spr & hs_write : cs_spr & ~cpu_a[10] & wr_strobe), .q_a(spr1_cpu_d),
    .clock_b(clk), .address_b(spr_ram_a), .q_b(spr1_d)
);

assign hs_data_out = hs_spr ? spr1_cpu_d : hs_work_d;

dpram_dc #(.widthad_a(8)) ram_spr2
(
    .clock_a(clk), .address_a(cpu_a[7:0]), .data_a(cpu_do), .wren_a(cs_spr & cpu_a[10] & wr_strobe), .q_a(spr2_cpu_d),
    .clock_b(clk), .address_b(spr_ram_a), .q_b(spr2_d)
);

// I/O at C000-CFFF: A9-A8 = 00 scanline / sound latch, 10 DSW1 / watchdog, 11 inputs / main latch
logic [7:0] io_d;
always_comb begin
    case (cpu_a[9:8])
        2'b00:   io_d = vcnt[7:0];
        2'b10:   io_d = dsw1;
        2'b11:   case (cpu_a[6:5])
                     2'b00: io_d = in0;
                     2'b01: io_d = is_bk ? {in1[7:2], ~hop_status, in1[0]} : in1;
                     2'b10: io_d = in2;
                     2'b11: io_d = dsw0;
                 endcase
        default: io_d = 8'hFF;
    endcase
end

always_comb begin
    if      (cs_rom) cpu_di = cpu_rom_d;
    else if (cs_col) cpu_di = col_cpu_d;
    else if (cs_vid) cpu_di = vid_cpu_d;
    else if (cs_ram) cpu_di = ram_cpu_d;
    else if (cs_spr) cpu_di = cpu_a[10] ? spr2_cpu_d : spr1_cpu_d;
    else if (cs_io)  cpu_di = io_d;
    else if (cs_xram) cpu_di = xram_d;
    else if (cs_prot) cpu_di = 8'h80;
    else             cpu_di = 8'hFF;
end

logic [7:0] sound_latch = 8'h00;

assign wd_kick  = cs_io && wr_edge && cpu_a[9:8] == 2'b10;
assign wd_reset = wd_rst;

always_ff @(posedge clk) begin
    if (cpu_rst) begin
        mainlatch <= 8'h00;
    end else if (cs_io && wr_edge) begin
        if (cpu_a[9:8] == 2'b00) sound_latch <= cpu_do;
        if (cpu_a[9:8] == 2'b11 && cpu_a[7:4] == 4'h0) mainlatch[cpu_a[3:1]] <= cpu_do[0];
    end
end

// NMI on vblank start (line 240) while enabled; clearing the enable releases it.
// Power Surge: NMI follows vblank every frame (MAME set_inputline on screen_vblank), no enable.
wire vblank_start = ce_pix && hcnt == 9'd128 && vcnt == 9'd496;
wire vblank_end   = ce_pix && hcnt == 9'd128 && vcnt == 9'd272;
always_ff @(posedge clk) begin
    if (cpu_rst)                   nmi_ff <= 1'b0;
    else if (is_ps) begin
        if (vblank_start)          nmi_ff <= 1'b1;
        else if (vblank_end)       nmi_ff <= 1'b0;
    end
    else if (!mainlatch[0])        nmi_ff <= 1'b0;
    else if (vblank_start)         nmi_ff <= 1'b1;
end

// Coin hopper (Bikkuri Card / Chance Kun), motor = latch Q5. MAME hopper_device, 100 ms period: the status
// line toggles each period while the motor runs; switched off mid-coin, it finishes that coin.
localparam logic [22:0] HOP_LAST = 23'd4915199;    // 100 ms at 49.152 MHz, minus 1
logic        hop_power = 1'b0, hop_run = 1'b0, hop_motor_d = 1'b0;
logic [22:0] hop_cnt = 23'd0;
always_ff @(posedge clk) begin
    hop_motor_d <= mainlatch[5];
    if (reset || !is_bk) begin
        hop_power <= 1'b0; hop_status <= 1'b0; hop_run <= 1'b0;
    end else begin
        if (hop_run && !pause) hop_cnt <= hop_cnt + 23'd1;
        if (mainlatch[5] && !hop_motor_d && !hop_power) begin
            hop_power <= 1'b1; hop_status <= 1'b0; hop_run <= 1'b1; hop_cnt <= 23'd0;
        end else if (!mainlatch[5] && hop_motor_d && hop_power) begin
            hop_power <= 1'b0;
            if (!hop_status) hop_run <= 1'b0;
        end else if (hop_run && hop_cnt == HOP_LAST) begin
            hop_status <= ~hop_status;
            hop_cnt    <= 23'd0;
            if (!hop_power) hop_run <= 1'b0;
        end
    end
end

/////////////////////////////  Tile layer  /////////////////////////////

// The next column is fetched while the current one is shown; its data takes over on the last pixel of a column
logic [7:0] fetch_x;
logic [7:0] fetch_y;
logic [3:0] fetch_st = 4'd0;
logic [7:0] nxt_attr, nxt_d0, nxt_d1, cur_attr, cur_d0, cur_d1;
logic [9:0] nxt_code;
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
                nxt_attr   <= col_d;
                nxt_code   <= is_bk ? {col_d[6:5], vid_d} : {1'b0, col_d[5], vid_d};
                nxt_row    <= fetch_y[2:0] ^ {3{col_d[7] & ~is_bk}};
                fetch_st   <= 4'd4;
            end
            4'd4: begin tile_rom_a <= {nxt_code, 1'b0, nxt_row}; fetch_st <= 4'd5; end
            4'd5: begin tile_rom_a <= {nxt_code, 1'b1, nxt_row}; fetch_st <= 4'd6; end
            4'd6: begin nxt_d0 <= tile_rom_d; fetch_st <= 4'd7; end
            4'd7: begin nxt_d1 <= tile_rom_d; fetch_st <= 4'd0; end
            default: fetch_st <= 4'd0;
        endcase
    end

    if (ce_pix && hcnt[2:0] == 3'd7) begin
        cur_attr <= nxt_attr;
        cur_d0   <= nxt_d0;
        cur_d1   <= nxt_d1;
    end
end

// Pixel within the tile: screen flip, then the tile's own X flip (attr bit 6; none on Bikkuri Card)
wire [2:0] tpx   = hcnt[2:0] ^ {3{tflip}} ^ {3{cur_attr[6] & ~is_bk}};
wire [7:0] tbyte = tpx[2] ? cur_d1 : cur_d0;
wire [1:0] tpen  = {tbyte[3 - tpx[1:0]], tbyte[7 - tpx[1:0]]};

/////////////////////////////  Sprites (502 / 503)  /////////////////////////////

// Two line buffers of {colour[5:0], pen[1:0]}: one is shown (and cleared behind the beam) while the other is
// drawn with the next line. Sprite RAM is read during the line, so mid-frame rewrites (the cloud multiplex) land.
// Buffer vcnt[0] is shown on line vcnt; the selects are registered with the addresses that use them
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

// Sprite renderer: slots 31 down to 8 (MAME offs 0x3E..0x10), later slots drawn over earlier ones
typedef enum logic [3:0] { SP_IDLE, SP_Y0, SP_Y1, SP_Y2, SP_A0, SP_A1, SP_A2, SP_A3, SP_R0, SP_R1, SP_PIX } sp_state_t;
sp_state_t  sp_st = SP_IDLE;
logic [4:0] sp_slot;
logic [7:0] sp_line;
logic [7:0] sp_x, sp_code, sp_attr;
logic [3:0] sp_row;
logic [1:0] sp_grp;
logic [1:0] sp_k;
logic [7:0] sp_byte;

wire [9:0] sp_dy = {2'b00, sp_line} + {2'b00, spr2_d} - 10'd241;    // line - (241 - y)
wire [3:0] sp_srcx  = {sp_grp, sp_k};
wire [3:0] sp_dx    = sp_attr[6] ? sp_srcx : ~sp_srcx;              // attr bit 6 clear = X flipped
wire [8:0] sp_px    = {1'b0, sp_x} + {5'd0, sp_dx};
wire [1:0] sp_pen   = is_bk ? {sp_byte[7 - sp_k], sp_byte[3 - sp_k]}      // chkun_spritelayout planes { 0, 4 }
                            : {sp_byte[3 - sp_k], sp_byte[7 - sp_k]};

always_ff @(posedge clk) begin
    lb_wr <= 1'b0;
    case (sp_st)
        SP_IDLE: ;
        SP_Y0: begin spr_ram_a <= {2'b00, sp_slot, 1'b1}; sp_st <= SP_Y1; end
        SP_Y1: sp_st <= SP_Y2;
        SP_Y2: begin
            if (sp_dy[9:4] == 6'd0) begin
                sp_row    <= sp_dy[3:0];
                spr_ram_a <= {2'b00, sp_slot, 1'b0};
                sp_st     <= SP_A0;
            end else if (sp_slot == 5'd8)
                sp_st <= SP_IDLE;
            else begin
                sp_slot <= sp_slot - 5'd1;
                sp_st   <= SP_Y0;
            end
        end
        SP_A0: begin spr_ram_a <= {2'b00, sp_slot, 1'b1}; sp_st <= SP_A1; end
        SP_A1: begin sp_x <= spr1_d; sp_attr <= spr2_d; sp_st <= SP_A2; end
        SP_A2: begin
            sp_code <= {spr1_d[7] & (sub != 2'd2), spr1_d[6:0]};        // Bikkuri Card: 128 sprites, codes wrap
            if (sp_attr[7]) sp_row <= ~sp_row;                           // Y flip
            sp_grp  <= 2'd0;
            sp_st   <= SP_A3;
        end
        SP_A3: begin spr_rom_a <= {sp_code, sp_row[3], sp_grp, sp_row[2:0]}; sp_st <= SP_R0; end
        SP_R0: sp_st <= SP_R1;
        SP_R1: begin sp_byte <= spr_rom_d; sp_k <= 2'd0; sp_st <= SP_PIX; end
        SP_PIX: begin
            if (!sp_px[8] && sp_pen != 2'd0) begin
                lb_wr_a <= sp_px[7:0];
                lb_wr_d <= {sp_attr[5:0], sp_pen};
                lb_wr   <= 1'b1;
            end
            sp_k <= sp_k + 2'd1;
            if (sp_k == 2'd3) begin
                sp_grp <= sp_grp + 2'd1;
                if (sp_grp != 2'd3)
                    sp_st <= SP_A3;
                else if (sp_slot == 5'd8)
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
        sp_line <= vcnt[7:0] + 8'd1;
        sp_buf  <= ~vcnt[0];
        sp_slot <= 5'd31;
        sp_st   <= SP_Y0;
    end
end

/////////////////////////////  Mixer / palette  /////////////////////////////

// The 2-stage pixel pipeline: stage 1 = tile pen + line buffer read, stage 2 = lookup PROM + palette PROM
// Pixel H is captured on its ce_pix edge and leaves as RGB on the next one
logic [4:0] s1_tcol;
logic       s1_pri;
logic [1:0] s1_tpen;
logic       hs_d, vs_d, hb_d, vb_d;
logic [2:0] mix_st = 3'd0;
logic       s2_spr;
logic [4:0] fb_pix;                             // CRT Flip: pixel of the shown frame buffer (below)
wire  [4:0] pal_live = {~s2_spr, lut_d[3:0]};

always_ff @(posedge clk) begin
    clr_wr <= 1'b0;

    if (ce_pix) begin
        s1_tcol <= cur_attr[4:0];
        s1_pri  <= is_bk ? cur_attr[7] : cur_attr[4];
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
                // char priority (attr bit 4, bit 7 on Bikkuri Card) covers sprites; sprite pen 0 is transparent
                s2_spr <= ~s1_pri && lb_q[1:0] != 2'd0;
                lut_a  <= (~s1_pri && lb_q[1:0] != 2'd0) ? {1'b0, lb_q} : {2'b10, s1_tcol, s1_tpen};
                mix_st <= 3'd3;
            end
            3'd3: mix_st <= 3'd4;
            3'd4: begin pal_a <= crt_flip ? fb_pix : pal_live; mix_st <= 3'd5; end
            3'd5: mix_st <= 3'd6;
            3'd6: mix_st <= 3'd0;
            default: mix_st <= 3'd0;
        endcase
    end
end

/////////////////////////////  CRT Flip frame buffer  /////////////////////////////

// The game multiplexes the cloud sprites off the beam (C000 read), so the board must draw in its own line order.
// CRT Flip draws unflipped into one of two frame buffers (256 x 224 visible, 5-bit palette index, 2 pixels per
// 10-bit word) and shows the other read back rotated 180: one frame of delay, only while CRT Flip is on.
// Buffer A is the Tutankham bitmap RAM (rtl/konami82_board.sv); buffer B is here, 16K + 8K + 4K words = rows 0-223.
logic        fb_w = 1'b0;                       // buffer being written (0 = A); the other is shown
logic  [1:0] fb_ok = 2'd0;                      // frame starts since CRT Flip came on; shown from 2 (a whole frame)
logic  [7:0] px_h, px_v;                        // raster position of the pixel in the mixer pipeline
logic  [4:0] fb_even;                           // even pixel, written with its odd neighbour
logic [14:0] fb_wa, fb_ra;
logic  [9:0] fb_wd;
logic        fb_we = 1'b0;
logic        fb_rbuf, fb_rhalf;
wire   [7:0] px_row = px_v - 8'd16;             // visible line 0..223 (vcnt 272..495)
wire   [7:0] rd_row = 8'd239 - vcnt[7:0];       // line shown here, rotated
wire   [7:0] rd_col = ~hcnt[7:0];

always_ff @(posedge clk) begin
    fb_we <= 1'b0;
    if (vblank_start) begin
        fb_w <= ~fb_w;
        if (fb_ok != 2'd2) fb_ok <= fb_ok + 2'd1;
    end
    if (!crt_flip) fb_ok <= 2'd0;
    if (ce_pix) begin
        px_h     <= hcnt[7:0];
        px_v     <= vcnt[7:0];
        fb_ra    <= {rd_row, rd_col[7:1]};
        fb_rhalf <= rd_col[0];
        fb_rbuf  <= ~fb_w;
    end else if (mix_st == 3'd4 && !hb_d && !vb_d && crt_flip) begin
        if (!px_h[0]) fb_even <= pal_live;
        else begin
            fb_wa <= {px_row, px_h[7:1]};
            fb_wd <= {pal_live, fb_even};
            fb_we <= 1'b1;
        end
    end
end

assign fba_wa = fb_wa;
assign fba_wd = fb_wd;
assign fba_we = fb_we & ~fb_w;
assign fba_ra = fb_ra;

logic [9:0] fbb_q0, fbb_q1, fbb_q2;
wire        fbb_we = fb_we & fb_w;
dpram_dc #(.widthad_a(14), .width_a(10)) fbb0        // rows 0-127
(
    .clock_a(clk), .address_a(fb_wa[13:0]), .data_a(fb_wd), .wren_a(fbb_we & ~fb_wa[14]),
    .clock_b(clk), .address_b(fb_ra[13:0]), .q_b(fbb_q0)
);
dpram_dc #(.widthad_a(13), .width_a(10)) fbb1        // rows 128-191
(
    .clock_a(clk), .address_a(fb_wa[12:0]), .data_a(fb_wd), .wren_a(fbb_we & fb_wa[14:13] == 2'b10),
    .clock_b(clk), .address_b(fb_ra[12:0]), .q_b(fbb_q1)
);
dpram_dc #(.widthad_a(12), .width_a(10)) fbb2        // rows 192-223
(
    .clock_a(clk), .address_a(fb_wa[11:0]), .data_a(fb_wd), .wren_a(fbb_we & fb_wa[14:12] == 3'b110),
    .clock_b(clk), .address_b(fb_ra[11:0]), .q_b(fbb_q2)
);
wire [9:0] fbb_q = ~fb_ra[14] ? fbb_q0 : ~fb_ra[13] ? fbb_q1 : fbb_q2;
wire [9:0] fb_q  = fb_rbuf ? fbb_q : fba_q;
assign fb_pix = fb_rhalf ? fb_q[9:5] : fb_q[4:0];

// Resistor DAC: 1.2K / 820 / 560 / 470 / 390 per gun (MAME weights 0x19, 0x24, 0x35, 0x40, 0x4D)
function automatic [7:0] dac5(input [4:0] b);
    dac5 = (b[0] ? 8'h19 : 8'h00) + (b[1] ? 8'h24 : 8'h00) + (b[2] ? 8'h35 : 8'h00) +
           (b[3] ? 8'h40 : 8'h00) + (b[4] ? 8'h4D : 8'h00);
endfunction

always_ff @(posedge clk) begin
    if (ce_pix) begin
        video_hblank <= hb_d;
        video_vblank <= vb_d;
        video_hs     <= hs_d;
        video_vs     <= vs_d;
        if (hb_d | vb_d | ~video_en | (crt_flip & ~fb_ok[1])) begin
            video_r <= 8'd0;
            video_g <= 8'd0;
            video_b <= 8'd0;
        end else begin
            video_r <= dac5(pal1_d[5:1]);
            video_g <= dac5({pal0_d[2:0], pal1_d[7:6]});
            video_b <= dac5(pal0_d[7:3]);
        end
    end
end

/////////////////////////////  Sound board (shared, in konami82_board)  /////////////////////////////

assign snd_latch = sound_latch;
assign snd_irq   = mainlatch[2];
assign snd_mute  = mainlatch[3];

endmodule
