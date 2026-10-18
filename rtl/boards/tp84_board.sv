//============================================================================
//
//  Konami Time Pilot '84 board (GX388)
//  Copyright (C) 2026 Rodimus
//
//  Written from the Time Pilot '84 schematics and MAME tp84.cpp (Aaron Giles). Main and sub CPUs are
//  MC6809E (Greg Miller's mc6809is, unmodified, shared in rtl/konami82_board.sv as m6809_0 / m6809_1).
//  tp84b: the same board with the main CPU's I/O and video RAM moved to 0000-1FFF (b84 = 1).
//
//  ioctl index 0 (MRA), images stored as dumped:
//    0x00000 - 0x07FFF  sprites (shared block 0; second port reads the upper half)
//    0x08000 - 0x0BFFF  (Time Pilot sound board window, unused here)
//    0x0C000 - 0x0FFFF  tiles (shared block 1)
//    0x10000 - 0x11FFF  audiocpu 0000-1FFF (shared block 2, second port: rtl/sound/tp84_sound.sv)
//    0x18000 - 0x1FFFF  cpu1 8000-FFFF (shared block 2)
//    0x20000 - 0x21FFF  sub E000-FFFF (this board)
//    0x22000 - 0x224FF  red 2C, green 2D, blue 1E, char lookup 1F, sprite lookup 16C (0x100 each)
//
//============================================================================

module tp84_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic        b84,            // tp84b memory map
    output logic        ce_pix,

    input  logic  [7:0] in0,            // $2800 system
    input  logic  [7:0] in1,            // $2820 player 1
    input  logic  [7:0] in2,            // $2840 player 2
    input  logic  [7:0] dsw0,           // $2860 DSW1 coinage
    input  logic  [7:0] dsw1,           // $3000 DSW2

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    output logic [14:0] rom0_a,         // shared ROM blocks (rtl/konami82_board.sv): ioctl 0x00000-0x07FFF
    input  logic  [7:0] rom0_d,
    output logic [14:0] rom0b_a,        //                                            (second port)
    input  logic  [7:0] rom0b_d,
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

    output logic  [7:0] snd_latch,      // to rtl/sound/tp84_sound.sv
    output logic        snd_irq,        // one clock per SON write

    output chip_pool_pkg::m6809r_i_t m6809_0_i,          // shared MC6809Es (rtl/konami82_board.sv): main
    input  chip_pool_pkg::m6809r_o_t m6809_0_o,
    output chip_pool_pkg::m6809r_i_t m6809_1_i,          //                                          sub
    input  chip_pool_pkg::m6809r_o_t m6809_1_o,
    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

/////////////////////////////  ROM storage  /////////////////////////////

wire load_sub  = ioctl_wr0 && ioctl_addr[24:13] == 12'h010;     // 0x20000-0x21FFF
wire load_prom = ioctl_wr0 && ioctl_addr[24:11] == 14'h0044;    // 0x22000-0x227FF
wire load_r    = load_prom && ioctl_addr[10:8] == 3'd0;
wire load_g    = load_prom && ioctl_addr[10:8] == 3'd1;
wire load_b    = load_prom && ioctl_addr[10:8] == 3'd2;
wire load_clut = load_prom && ioctl_addr[10:8] == 3'd3;
wire load_slut = load_prom && ioctl_addr[10:8] == 3'd4;

logic [15:0] cpu_rom_a;
logic  [7:0] cpu_rom_d;
assign rom2_a    = cpu_rom_a;                // main CPU ROM in shared block 2
assign cpu_rom_d = rom2_d;

logic [13:0] tile_rom_a;
logic  [7:0] tile_rom_d;
assign rom1_a     = tile_rom_a;              // tiles in shared block 1
assign tile_rom_d = rom1_d;

logic [13:0] spr_rom_a;                      // sprites: planes 0-1 at 0x0000, planes 2-3 at 0x4000 (shared block 0)
assign rom0_a  = {1'b0, spr_rom_a};
assign rom0b_a = {1'b1, spr_rom_a};

logic [12:0] sub_rom_a;
logic  [7:0] sub_rom_d;
dpram_dc #(.widthad_a(13)) rom_sub
(
    .clock_a(clk), .address_a(ioctl_addr[12:0]), .data_a(ioctl_dout), .wren_a(load_sub),
    .clock_b(clk), .address_b(sub_rom_a), .q_b(sub_rom_d)
);

logic [7:0] pal_a, pal_r, pal_g, pal_b;
dpram_dc #(.widthad_a(8)) prom_r
(
    .clock_a(clk), .address_a(ioctl_addr[7:0]), .data_a(ioctl_dout), .wren_a(load_r),
    .clock_b(clk), .address_b(pal_a), .q_b(pal_r)
);

dpram_dc #(.widthad_a(8)) prom_g
(
    .clock_a(clk), .address_a(ioctl_addr[7:0]), .data_a(ioctl_dout), .wren_a(load_g),
    .clock_b(clk), .address_b(pal_a), .q_b(pal_g)
);

dpram_dc #(.widthad_a(8)) prom_b
(
    .clock_a(clk), .address_a(ioctl_addr[7:0]), .data_a(ioctl_dout), .wren_a(load_b),
    .clock_b(clk), .address_b(pal_a), .q_b(pal_b)
);

logic [7:0] clut_a, clut_d;
dpram_dc #(.widthad_a(8)) prom_clut
(
    .clock_a(clk), .address_a(ioctl_addr[7:0]), .data_a(ioctl_dout), .wren_a(load_clut),
    .clock_b(clk), .address_b(clut_a), .q_b(clut_d)
);

logic [7:0] slut_a, slut_d;
dpram_dc #(.widthad_a(8)) prom_slut
(
    .clock_a(clk), .address_a(ioctl_addr[7:0]), .data_a(ioctl_dout), .wren_a(load_slut),
    .clock_b(clk), .address_b(slut_a), .q_b(slut_d)
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
wire   sfall_q = (div == 5'd7)  & ~pause_x;   // sub CPU: E / Q inverted (schematic), shared RAM in its own E-high half
wire   sfall_e = (div == 5'd15) & ~pause_x;

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

// Watchdog (LS293 14H): counts frames at vblank end (frozen while paused). It clears only when the main CPU writes
// 2000-27FF (tp84b 1800) after the sub CPU has written 0000-1FFF (LS74 14J): both CPUs must run. QD (8 frames without
// a kick) holds both CPUs and the main latch in reset for 8 frames, then the count wraps (schematic; MAME models the
// main CPU only). Video timing keeps running.
logic       wd_vb = 1'b0, wd_arm = 1'b0, wd_main, wd_sub;
logic [3:0] wd_cnt = 4'd0;
always_ff @(posedge clk) begin
    if (ce_pix) wd_vb <= raw_vblank;
    if (reset || (wd_main && wd_arm))                  wd_cnt <= 4'd0;
    else if (ce_pix && !raw_vblank && wd_vb && !pause) wd_cnt <= wd_cnt + 4'd1;
    if (reset || wd_main)                              wd_arm <= 1'b0;
    else if (wd_sub)                                   wd_arm <= 1'b1;
end
wire wd_rst  = wd_cnt[3];
wire cpu_rst = reset | wd_rst;
wire raw_hs     = ~((hcnt >= hs_on) && (hcnt < hs_on + 9'd32));
wire raw_vs     = (vs_dist >= 10'd3);

wire vblank_start = ce_pix && hcnt == 9'd128 && vcnt == 9'd496;

// Main latch (LS259): Q0 IRQ enable, Q1 / Q2 coin counters, Q3 MUT, Q4 HREV, Q5 VREV, Q7 GMED
logic [7:0] mainlatch = 8'h00;
wire flipx = mainlatch[4] ^ crt_flip;
wire flipy = mainlatch[5] ^ crt_flip;

/////////////////////////////  Main CPU  /////////////////////////////

logic [15:0] cpu_a;
logic  [7:0] cpu_do, cpu_di;
logic        cpu_rw;
logic        irq_ff = 1'b0;

assign m6809_0_i.reset_n = ~wd_rst;
assign m6809_0_i.fall_e = fall_e;
assign m6809_0_i.fall_q = fall_q;
assign m6809_0_i.irq_n  = ~irq_ff;
assign m6809_0_i.firq_n = 1'b1;
assign m6809_0_i.nmi_n  = 1'b1;
assign m6809_0_i.d      = cpu_di;
assign cpu_a  = m6809_0_o.a;
assign cpu_do = m6809_0_o.dout;
assign cpu_rw = m6809_0_o.rw;

// tp84: I/O 2000-3FFF, video RAM 4000-4FFF, shared RAM 5000-57FF. tp84b: video RAM 0000-0FFF, shared RAM 1000-17FF,
// I/O 1800-1FFF (the same decode on A8-A5 with A12-A9 squeezed)
wire io_sys  = b84 ? cpu_a[15:5] == 11'b0001_1010_000 : cpu_a[15:5] == 11'b0010_1000_000;   // 2800 / 1A00
wire io_p1   = b84 ? cpu_a[15:5] == 11'b0001_1010_001 : cpu_a[15:5] == 11'b0010_1000_001;   // 2820 / 1A20
wire io_p2   = b84 ? cpu_a[15:5] == 11'b0001_1010_010 : cpu_a[15:5] == 11'b0010_1000_010;   // 2840 / 1A40
wire io_dsw1 = b84 ? cpu_a[15:5] == 11'b0001_1010_011 : cpu_a[15:5] == 11'b0010_1000_011;   // 2860 / 1A60
wire io_pal  = io_sys;                                                                       // write: palette bank
wire io_lat  = b84 ? cpu_a[15:3] == 13'h0380 : cpu_a[15:3] == 13'h0600;                     // 3000-3007 / 1C00-1C07
wire io_son  = b84 ? cpu_a[15:7] == 9'h03C   : cpu_a[15:9] == 7'h1C;                        // 3800 / 1E00
wire io_sda  = b84 ? cpu_a[15:7] == 9'h03D   : cpu_a[15:9] == 7'h1D;                        // 3A00 / 1E80
wire io_scx  = b84 ? cpu_a[15:7] == 9'h03E   : cpu_a[15:9] == 7'h1E;                        // 3C00 / 1F00
wire io_scy  = b84 ? cpu_a[15:7] == 9'h03F   : cpu_a[15:9] == 7'h1F;                        // 3E00 / 1F80
wire cs_vid  = b84 ? cpu_a[15:11] == 5'b0000_0 : cpu_a[15:11] == 5'b0100_0;                 // bg 4000 / fg 4400 code
wire cs_col  = b84 ? cpu_a[15:11] == 5'b0000_1 : cpu_a[15:11] == 5'b0100_1;                 // bg 4800 / fg 4C00 attr
wire cs_shr  = b84 ? cpu_a[15:11] == 5'b0001_0 : cpu_a[15:11] == 5'b0101_0;                 // 5000-57FF / 1000-17FF
wire cs_rom  = cpu_a[15];

assign cpu_rom_a = {1'b1, cpu_a[14:0]};

// one write per bus cycle, at the end of E
wire wr = fall_e & ~cpu_rw;

// Video RAM: CPU on port A, tile fetch on port B. A10 = bg / fg.
logic [10:0] tile_ram_a;
logic  [7:0] vid_cpu_d, col_cpu_d, vid_d, col_d;

dpram_dc #(.widthad_a(11)) ram_vid
(
    .clock_a(clk), .address_a(cpu_a[10:0]), .data_a(cpu_do), .wren_a(cs_vid & wr), .q_a(vid_cpu_d),
    .clock_b(clk), .address_b(tile_ram_a), .q_b(vid_d)
);

dpram_dc #(.widthad_a(11)) ram_col
(
    .clock_a(clk), .address_a(cpu_a[10:0]), .data_a(cpu_do), .wren_a(cs_col & wr), .q_a(col_cpu_d),
    .clock_b(clk), .address_b(tile_ram_a), .q_b(col_d)
);

// Shared RAM: main CPU on port A (the hiscore system's while paused), sub CPU on port B
logic [15:0] sub_a;
logic  [7:0] sub_do;
logic        sub_rw;
logic  [7:0] shr_cpu_d, shr_sub_d;
wire         sub_wr  = sfall_e & ~sub_rw;
wire         scs_shr = sub_a[15:11] == 5'b1000_0;                                            // 8000-87FF
wire         hs_shr  = b84 ? hs_address[15:11] == 5'b0001_0 : hs_address[15:11] == 5'b0101_0; // 1000 / 5000

dpram_dc #(.widthad_a(11)) ram_shr
(
    .clock_a(clk), .address_a(pause ? hs_address[10:0] : cpu_a[10:0]), .data_a(pause ? hs_data_in : cpu_do),
    .wren_a(pause ? hs_shr & hs_write : cs_shr & wr), .q_a(shr_cpu_d),
    .clock_b(clk), .address_b(sub_a[10:0]), .data_b(sub_do), .wren_b(scs_shr & sub_wr), .q_b(shr_sub_d)
);

assign hs_data_out = shr_cpu_d;

always_comb begin
    if      (cs_rom)  cpu_di = cpu_rom_d;
    else if (io_sys)  cpu_di = in0;
    else if (io_p1)   cpu_di = in1;
    else if (io_p2)   cpu_di = in2;
    else if (io_dsw1) cpu_di = dsw0;
    else if (io_lat)  cpu_di = dsw1;
    else if (cs_vid)  cpu_di = vid_cpu_d;
    else if (cs_col)  cpu_di = col_cpu_d;
    else if (cs_shr)  cpu_di = shr_cpu_d;
    else              cpu_di = 8'hFF;
end

logic [7:0] sound_latch = 8'h00;
logic [7:0] scroll_x = 8'h00, scroll_y = 8'h00;
logic [4:0] pal_bank = 5'd0;
logic       son = 1'b0;

always_ff @(posedge clk) begin
    son <= 1'b0;
    if (cpu_rst) begin
        mainlatch <= 8'h00;
        pal_bank  <= 5'd0;
    end else if (wr) begin
        if (io_lat) mainlatch[cpu_a[2:0]] <= cpu_do[0];
        if (io_pal) pal_bank <= cpu_do[4:0];
        if (io_sda) sound_latch <= cpu_do;
        if (io_son) son <= 1'b1;
        if (io_scx) scroll_x <= cpu_do;
        if (io_scy) scroll_y <= cpu_do;
    end
end

// IRQ on vblank start while enabled; held until the enable is cleared
always_ff @(posedge clk) begin
    if (cpu_rst || !mainlatch[0]) irq_ff <= 1'b0;
    else if (vblank_start)      irq_ff <= 1'b1;
end

/////////////////////////////  Sub CPU  /////////////////////////////

logic [7:0] sub_di;
logic       sirq_ff = 1'b0, sirq_en = 1'b0;

assign m6809_1_i.reset_n = ~wd_rst;
assign m6809_1_i.fall_e = sfall_e;
assign m6809_1_i.fall_q = sfall_q;
assign m6809_1_i.irq_n  = ~sirq_ff;
assign m6809_1_i.firq_n = 1'b1;
assign m6809_1_i.nmi_n  = 1'b1;
assign m6809_1_i.d      = sub_di;
assign sub_a  = m6809_1_o.a;
assign sub_do = m6809_1_o.dout;
assign sub_rw = m6809_1_o.rw;

wire scs_beam = sub_a[15:13] == 3'b001;                                     // 2000 beam position
wire scs_irq  = sub_a[15:13] == 3'b010;                                     // 4000 IRQ enable
wire scs_ram  = sub_a[15:11] == 5'b0110_0;                                  // 6000-67FF (sprites 67A0-67FF)
wire scs_rom  = sub_a[15:13] == 3'b111;                                     // E000-FFFF

assign sub_rom_a = sub_a[12:0];

// Sub RAM: sub CPU on port A, sprite engine on port B
logic [10:0] obj_a;
logic  [7:0] obj_d, sram_sub_d;
dpram_dc #(.widthad_a(11)) ram_sub
(
    .clock_a(clk), .address_a(sub_a[10:0]), .data_a(sub_do), .wren_a(scs_ram & sub_wr), .q_a(sram_sub_d),
    .clock_b(clk), .address_b(obj_a), .q_b(obj_d)
);

always_comb begin
    if      (scs_rom)  sub_di = sub_rom_d;
    else if (scs_shr)  sub_di = shr_sub_d;
    else if (scs_ram)  sub_di = sram_sub_d;
    else if (scs_beam) sub_di = vcnt[7:0];                                  // 1V-128V
    else               sub_di = 8'hFF;
end

assign wd_main = wr && (b84 ? cpu_a[15:9] == 7'h0C : cpu_a[15:11] == 5'b0010_0);     // 1800 / 2000-27FF
assign wd_sub  = sub_wr && sub_a[15:13] == 3'b000;                                          // 0000-1FFF

always_ff @(posedge clk) begin
    if (cpu_rst)                    sirq_en <= 1'b0;
    else if (scs_irq & sub_wr)      sirq_en <= sub_do[0];
    if (cpu_rst || !sirq_en)        sirq_ff <= 1'b0;
    else if (vblank_start)          sirq_ff <= 1'b1;
end

/////////////////////////////  Tile layer  /////////////////////////////

// One pixel per ce_pix, looked up in the eight clocks it is shown: video RAM, char ROM, char lookup PROM.
// Logical (unflipped) coordinates = screen XOR 255 per flipped axis. Screen columns 0-15 and 240-255 show the
// fixed fg tilemap (status area), the rest the bg tilemap scrolled by 3C00 / 3E00 (MAME draws fg there only).
// 8x8x2: 16 bytes per char, bytes 0-7 = rows of pixels 0-3, 8-15 = pixels 4-7; pixel p: bit 0 = D(7-p), bit 1 = D(3-p).
wire [2:0] ph = div[2:0];
logic       t_fg;
logic [7:0] t_x, t_y, t_attr;
logic [1:0] t_p;
logic [3:0] t_col;

wire [1:0] t_pix = {tile_rom_d[3 - t_p], tile_rom_d[7 - t_p]};
wire       in_fg = hcnt[7:4] == 4'h0 || hcnt[7:4] == 4'hF;
wire [7:0] lx    = hcnt[7:0] ^ {8{flipx}};
wire [7:0] ly    = vcnt[7:0] ^ {8{flipy}};
wire [7:0] tx    = in_fg ? lx : lx + scroll_x;
wire [7:0] ty    = in_fg ? ly : ly + scroll_y;

always_ff @(posedge clk) begin
    case (ph)
        3'd0: begin
            tile_ram_a <= {in_fg, ty[7:3], tx[7:3]};
            t_fg <= in_fg;
            t_x  <= tx;
            t_y  <= ty;
        end
        3'd2: begin
            tile_rom_a <= {col_d[5:4], vid_d, t_x[2] ^ col_d[6], t_y[2:0] ^ {3{col_d[7]}}};     // attr 6 X flip, 7 Y flip
            t_attr <= col_d;
            t_p    <= t_x[1:0] ^ {2{col_d[6]}};
        end
        3'd4: clut_a <= {pal_bank[4:3], t_attr[3:0], t_pix};
        3'd6: t_col <= clut_d[3:0];
        default: ;
    endcase
end

/////////////////////////////  Sprites  /////////////////////////////

// Two line buffers of the sprite lookup PROM output (0 = transparent): one is shown (and cleared behind the
// beam) while the other is drawn with the next line. Buffer vcnt[0] is shown on line vcnt.
logic       rd_sel;
logic       sp_buf;
logic [7:0] lb_rd_a;
logic [7:0] lb_q0, lb_q1;
logic [7:0] lb_wr_a;
logic [3:0] lb_wr_d;
logic       lb_wr;
logic [7:0] clr_a;
logic       clr_wr;

wire clr0 = clr_wr & ~rd_sel, clr1 = clr_wr & rd_sel;
wire wr0  = lb_wr  & ~sp_buf, wr1  = lb_wr  & sp_buf;

dpram_dc #(.widthad_a(8)) lbuf0
(
    .clock_a(clk), .address_a(clr0 ? clr_a : lb_wr_a), .data_a(clr0 ? 8'h00 : {4'h0, lb_wr_d}), .wren_a(clr0 | wr0),
    .clock_b(clk), .address_b(lb_rd_a), .q_b(lb_q0)
);

dpram_dc #(.widthad_a(8)) lbuf1
(
    .clock_a(clk), .address_a(clr1 ? clr_a : lb_wr_a), .data_a(clr1 ? 8'h00 : {4'h0, lb_wr_d}), .wren_a(clr1 | wr1),
    .clock_b(clk), .address_b(lb_rd_a), .q_b(lb_q1)
);

wire [3:0] lb_q = rd_sel ? lb_q1[3:0] : lb_q0[3:0];

// Sprite renderer: 24 sprites of 4 bytes (X, code, attr, Y) at sub RAM 67A0, read live for each line (the sub CPU
// rewrites them mid-frame). Slot 23 first, so slot 0 ends on top (MAME draw order; the 502's order is unknown). HREV /
// VREV do not reach the sprite path (schematic); only the OSD CRT flip turns sprites. attr: bits 3-0 colour,
// 6 X not flipped, 7 Y flipped. Screen Y = 240 - byte 3. 16x16x4: 64 bytes per sprite and plane pair, byte =
// {code, row[3], col[3:2], row[2:0]}; planes 0-1 in the lower ROM half, 2-3 in the upper (same address).
typedef enum logic [3:0] { SP_IDLE, SP_Y0, SP_Y1, SP_Y2, SP_A0, SP_A1, SP_A2, SP_A3, SP_PIX } sp_state_t;
sp_state_t  sp_st = SP_IDLE;
logic [4:0] sp_slot;
logic [7:0] sp_line;
logic [7:0] sp_attr;
logic [7:0] sp_code;
logic [7:0] sp_x;
logic [3:0] sp_row;
logic [4:0] sp_k;

wire [7:0] sp_dy = sp_line + obj_d + 8'd16;                         // line - (240 - Y)

// pixel pipeline: issue (ROM address) -> +2 ROM data, lookup PROM address -> +2 lookup data, line buffer write
wire [3:0] sp_src = sp_attr[6] ? sp_k[3:0] : ~sp_k[3:0];            // attr bit 6 = 0: X flipped
logic       p_v[2], q_v[2];
logic [1:0] p_p[2];
logic [3:0] p_col[2];
logic [8:0] p_x[2], q_x[2];

wire [1:0] pp    = p_p[1];
wire [3:0] p_pen = {rom0b_d[3 - pp], rom0b_d[7 - pp], rom0_d[3 - pp], rom0_d[7 - pp]};

always_ff @(posedge clk) begin
    // stage 1: one pixel issued per clock in SP_PIX
    p_v[0]   <= sp_st == SP_PIX;
    p_p[0]   <= sp_src[1:0];
    p_col[0] <= sp_attr[3:0];
    p_x[0]   <= {1'b0, sp_x} + {5'd0, sp_k[3:0]};
    spr_rom_a <= {sp_code, sp_row[3], sp_src[3:2], sp_row[2:0]};
    p_v[1] <= p_v[0]; p_p[1] <= p_p[0]; p_col[1] <= p_col[0]; p_x[1] <= p_x[0];
    // stage 2: ROM data -> lookup PROM
    slut_a <= {p_col[1], p_pen};
    q_v[0] <= p_v[1];
    q_x[0] <= p_x[1];
    q_v[1] <= q_v[0];
    q_x[1] <= q_x[0];
    // stage 3: lookup data -> line buffer, clipped at the right edge, transparent where the lookup is 0
    lb_wr   <= q_v[1] && !q_x[1][8] && slut_d[3:0] != 4'd0;
    lb_wr_a <= q_x[1][7:0] ^ {8{crt_flip}};
    lb_wr_d <= slut_d[3:0];
end

always_ff @(posedge clk) begin
    case (sp_st)
        SP_IDLE: ;
        SP_Y0: begin obj_a <= {6'b111_101, 5'd0} + {4'd0, sp_slot, 2'd3}; sp_st <= SP_Y1; end   // 67A0 + 4n + 3
        SP_Y1: sp_st <= SP_Y2;
        SP_Y2: begin
            if (sp_dy[7:4] == 4'd0) begin
                sp_row <= sp_dy[3:0];
                obj_a  <= {6'b111_101, 5'd0} + {4'd0, sp_slot, 2'd2};
                sp_st  <= SP_A0;
            end else if (sp_slot == 5'd0)
                sp_st <= SP_IDLE;
            else begin
                sp_slot <= sp_slot - 5'd1;
                sp_st   <= SP_Y0;
            end
        end
        SP_A0: begin obj_a <= {6'b111_101, 5'd0} + {4'd0, sp_slot, 2'd1}; sp_st <= SP_A1; end
        SP_A1: begin sp_attr <= obj_d; obj_a <= {6'b111_101, 5'd0} + {4'd0, sp_slot, 2'd0}; sp_st <= SP_A2; end
        SP_A2: begin sp_code <= obj_d; sp_st <= SP_A3; end
        SP_A3: begin
            sp_x <= obj_d;
            if (sp_attr[7]) sp_row <= ~sp_row;                           // attr bit 7 = Y flipped
            sp_k  <= 5'd0;
            sp_st <= SP_PIX;
        end
        SP_PIX: begin
            sp_k <= sp_k + 5'd1;
            if (sp_k == 5'd15) begin
                if (sp_slot == 5'd0)
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

// Pixel H is looked up while H is on the counters, captured on its last ce_pix and leaves as RGB on the next one.
// Palette PROM address: bit 7 = char (1) / sprite (0), bits 6-4 = palette bank 2-0, bits 3-0 = lookup PROM output.
// Sprites show over the bg tilemap where their lookup is not 0; the fg status columns cover them.
logic [3:0] s1_tcol, s1_spr, lb_hold;
logic       s1_fg;
logic       hs_d, vs_d, hb_d, vb_d;

always_ff @(posedge clk) begin
    clr_wr <= 1'b0;
    if (ph == 3'd0) begin
        lb_rd_a <= hcnt[7:0];
        clr_a   <= hcnt[7:0];
        rd_sel  <= vcnt[0];
    end
    if (ph == 3'd3) lb_hold <= lb_q;                                 // read before the erase below reaches the port
    if (ph == 3'd3 && !raw_hblank) clr_wr <= 1'b1;                   // erase behind the beam (visible pixels only)

    if (ce_pix) begin
        s1_tcol <= t_col;
        s1_fg   <= t_fg;
        s1_spr  <= lb_hold;
        hb_d    <= raw_hblank;
        vb_d    <= raw_vblank;
        hs_d    <= raw_hs;
        vs_d    <= raw_vs;
    end
    if (ph == 3'd0)
        pal_a <= (!s1_fg && s1_spr != 4'd0) ? {1'b0, pal_bank[2:0], s1_spr} : {1'b1, pal_bank[2:0], s1_tcol};
end

// Resistor DAC: 1K / 470 / 220 / 100 per gun (470 pull-down only scales)
function automatic [7:0] dac4(input [3:0] b);
    case (b)
        4'd0:  dac4 = 8'd0;   4'd1:  dac4 = 8'd14;  4'd2:  dac4 = 8'd31;  4'd3:  dac4 = 8'd45;
        4'd4:  dac4 = 8'd66;  4'd5:  dac4 = 8'd80;  4'd6:  dac4 = 8'd96;  4'd7:  dac4 = 8'd111;
        4'd8:  dac4 = 8'd144; 4'd9:  dac4 = 8'd159; 4'd10: dac4 = 8'd175; 4'd11: dac4 = 8'd189;
        4'd12: dac4 = 8'd210; 4'd13: dac4 = 8'd224; 4'd14: dac4 = 8'd241; default: dac4 = 8'd255;
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
            video_r <= dac4(pal_r[3:0]);
            video_g <= dac4(pal_g[3:0]);
            video_b <= dac4(pal_b[3:0]);
        end
    end
end

/////////////////////////////  Sound board (rtl/sound/tp84_sound.sv)  /////////////////////////////

assign snd_latch = sound_latch;
assign snd_irq   = son;

endmodule
