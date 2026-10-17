//============================================================================
//
//  Konami Pooyan board (GX320)
//  Copyright (C) 2026 Rodimus
//
//  Written from the Pooyan schematics and MAME pooyan.cpp (Allard van der Bas).
//  Same timing and sound board as Time Pilot; 4bpp tiles and sprites, one 32x8 palette PROM
//  and two 256x4 lookup PROMs.
//
//  ioctl index 0 (MRA), images stored as dumped, MAME region order:
//    0x00000 - 0x07FFF  maincpu
//    0x08000 - 0x0BFFF  timeplt_audio:tpsound (shared sound board)
//    0x0C000 - 0x0DFFF  tiles   (0x0000 planes 0/1, 0x1000 planes 2/3)
//    0x10000 - 0x11FFF  sprites (0x0000 planes 0/1, 0x1000 planes 2/3)
//    0x14000 - 0x1401F  palette PROM pr1
//    0x14020 - 0x1411F  char lookup pr3     0x14120 - 0x1421F  sprite lookup pr2
//
//============================================================================

module pooyan_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    output logic        ce_pix,

    input  logic  [7:0] in0,            // $A080 system
    input  logic  [7:0] in1,            // $A0A0 player 1
    input  logic  [7:0] in2,            // $A0C0 player 2
    input  logic  [7:0] dsw0,           // $A0E0 coinage
    input  logic  [7:0] dsw1,           // $A000

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

    output logic  [7:0] snd_latch,      // to the shared sound board (rtl/konami82_board.sv)
    output logic        snd_irq,
    output logic        snd_mute,

    output chip_pool_pkg::z80_i_t   z80_0_i,          // shared Z80 (rtl/konami82_board.sv)
    input  chip_pool_pkg::z80_o_t   z80_0_o,
    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

/////////////////////////////  ROM storage  /////////////////////////////

wire load_prom = ioctl_wr0 && ioctl_addr[24:10] == 15'h0050;    // 0x14000-0x143FF
wire load_pal  = load_prom && ioctl_addr[9:5] == 5'd0;          // pr1
wire [9:0] clut_dl = ioctl_addr[9:0] - 10'h020;
wire [9:0] slut_dl = ioctl_addr[9:0] - 10'h120;
wire load_clut = load_prom && ioctl_addr[9:0] >= 10'h020 && ioctl_addr[9:0] < 10'h120;
wire load_slut = load_prom && ioctl_addr[9:0] >= 10'h120 && ioctl_addr[9:0] < 10'h220;

logic [14:0] cpu_rom_a;
logic  [7:0] cpu_rom_d;
assign rom0_a    = cpu_rom_a;                // CPU ROM in shared block 0
assign cpu_rom_d = rom0_d;

logic [12:0] tile_rom_a;
logic  [7:0] tile_rom_d;
assign rom1_a     = {1'b0, tile_rom_a};      // tiles in shared block 1
assign tile_rom_d = rom1_d;

logic [12:0] spr_rom_a;
logic  [7:0] spr_rom_d;
assign rom2_a    = {3'b000, spr_rom_a};      // sprites in shared block 2
assign spr_rom_d = rom2_d;

logic [7:0] clut_a, clut_d;
dpram_dc #(.widthad_a(8)) prom_clut
(
    .clock_a(clk), .address_a(clut_dl[7:0]), .data_a(ioctl_dout), .wren_a(load_clut),
    .clock_b(clk), .address_b(clut_a), .q_b(clut_d)
);

logic [7:0] slut_a, slut_d;
dpram_dc #(.widthad_a(8)) prom_slut
(
    .clock_a(clk), .address_a(slut_dl[7:0]), .data_a(ioctl_dout), .wren_a(load_slut),
    .clock_b(clk), .address_b(slut_a), .q_b(slut_d)
);

logic [4:0] pal_a;
logic [7:0] pal_d;
dpram_dc #(.widthad_a(5)) prom_pal
(
    .clock_a(clk), .address_a(ioctl_addr[4:0]), .data_a(ioctl_dout), .wren_a(load_pal),
    .clock_b(clk), .address_b(pal_a), .q_b(pal_d)
);

/////////////////////////////  Clocks  /////////////////////////////

// 18.432 MHz / 3 = 6.144 MHz pixel clock = 49.152 / 8; Z80 3.072 MHz = pixel / 2
logic [3:0] div = 4'd0;
always_ff @(posedge clk) div <= div + 4'd1;

assign ce_pix = (div[2:0] == 3'd7);
wire   cpu_ce = (div == 4'd15) & ~pause;

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
wire raw_hs     = ~((hcnt >= hs_on) && (hcnt < hs_on + 9'd32));
wire raw_vs     = (vs_dist >= 10'd3);

// Main latch (LS259 B2): Q0 NMI enable, Q1 sound IRQ, Q2 sound mute, Q3/Q4 coin counters, Q5 pay out, Q7 /flip
logic [7:0] mainlatch = 8'h00;
wire tflip = ~mainlatch[7] ^ crt_flip;         // MAME flips only the tilemap with the game's flip

/////////////////////////////  Main CPU  /////////////////////////////

logic [15:0] cpu_a;
logic  [7:0] cpu_do, cpu_di;
logic        cpu_mreq_n, cpu_rd_n, cpu_wr_n, cpu_rfsh_n;
logic        nmi_ff = 1'b0;

// Main CPU: the shared T80 in rtl/konami82_board.sv
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
wire cs_rom = mem && ~cpu_a[15];                                 // 0000-7FFF
wire cs_col = mem && cpu_a[15:10] == 6'b1000_00;                 // 8000-83FF
wire cs_vid = mem && cpu_a[15:10] == 6'b1000_01;                 // 8400-87FF
wire cs_ram = mem && cpu_a[15:11] == 5'b1000_1;                  // 8800-8FFF
wire cs_spr = mem && cpu_a[15:12] == 4'h9;                       // 9000-9FFF, A10 selects bank
wire cs_io  = mem && cpu_a[15] && cpu_a[13];                     // A000-BFFF, E000-FFFF

assign cpu_rom_a = cpu_a[14:0];

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

// Work RAM; second port for the hiscore system
logic [7:0] ram_cpu_d;
wire        hs_cs = hs_address[15:11] == 5'b1000_1;
dpram_dc #(.widthad_a(11)) ram_work
(
    .clock_a(clk), .address_a(cpu_a[10:0]), .data_a(cpu_do), .wren_a(cs_ram & wr_strobe), .q_a(ram_cpu_d),
    .clock_b(clk), .address_b(hs_address[10:0]), .data_b(hs_data_in), .wren_b(hs_cs & hs_write), .q_b(hs_data_out)
);

// Sprite RAM: bank 1 (9000, A10=0) = X / code, bank 2 (9400, A10=1) = attribute / Y
logic [7:0] spr_ram_a;
logic [7:0] spr1_cpu_d, spr2_cpu_d, spr1_d, spr2_d;

dpram_dc #(.widthad_a(8)) ram_spr1
(
    .clock_a(clk), .address_a(cpu_a[7:0]), .data_a(cpu_do), .wren_a(cs_spr & ~cpu_a[10] & wr_strobe), .q_a(spr1_cpu_d),
    .clock_b(clk), .address_b(spr_ram_a), .q_b(spr1_d)
);

dpram_dc #(.widthad_a(8)) ram_spr2
(
    .clock_a(clk), .address_a(cpu_a[7:0]), .data_a(cpu_do), .wren_a(cs_spr & cpu_a[10] & wr_strobe), .q_a(spr2_cpu_d),
    .clock_b(clk), .address_b(spr_ram_a), .q_b(spr2_d)
);

// I/O: A8-A7 = 00 DSW1 / watchdog, 01 inputs by A6-A5, 10 sound latch, 11 main latch (bit = A2-A0)
logic [7:0] io_d;
always_comb begin
    case (cpu_a[8:7])
        2'b00:   io_d = dsw1;
        2'b01:   case (cpu_a[6:5])
                     2'b00: io_d = in0;
                     2'b01: io_d = in1;
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
    else             cpu_di = 8'hFF;
end

logic [7:0] sound_latch = 8'h00;

always_ff @(posedge clk) begin
    if (reset) begin
        mainlatch <= 8'h00;
    end else if (cs_io && wr_edge) begin
        if (cpu_a[8:7] == 2'b10) sound_latch <= cpu_do;
        if (cpu_a[8:7] == 2'b11) mainlatch[cpu_a[2:0]] <= cpu_do[0];
    end
end

// NMI on vblank start (line 240) while enabled; clearing the enable releases it
wire vblank_start = ce_pix && hcnt == 9'd128 && vcnt == 9'd496;
always_ff @(posedge clk) begin
    if (reset || !mainlatch[0]) nmi_ff <= 1'b0;
    else if (vblank_start)      nmi_ff <= 1'b1;
end

/////////////////////////////  Tile layer  /////////////////////////////

// The next column is fetched while the current one is shown; its data takes over on the last pixel of a column.
// Per column: planes 0/1 bytes for pixels 0-3 and 4-7, then planes 2/3 (second half of the ROM).
logic [7:0] fetch_x;
logic [7:0] fetch_y;
logic [3:0] fetch_st = 4'd0;
logic [7:0] nxt_attr, nxt_code, cur_attr;
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
                nxt_code <= vid_d;
                nxt_row  <= fetch_y[2:0] ^ {3{col_d[7]}};
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

// Sprite renderer: slots 8 up to 31 (MAME offs 0x10..0x3E), later slots drawn over earlier ones
typedef enum logic [3:0] { SP_IDLE, SP_Y0, SP_Y1, SP_Y2, SP_A0, SP_A1, SP_A2, SP_G0, SP_G1, SP_G2, SP_G3,
                           SP_P0, SP_P1, SP_P2 } sp_state_t;
sp_state_t  sp_st = SP_IDLE;
logic [4:0] sp_slot;
logic [7:0] sp_line;
logic [7:0] sp_x, sp_code, sp_attr;
logic [3:0] sp_row;
logic [1:0] sp_grp;
logic [1:0] sp_k;
logic [7:0] sp_lo, sp_hi;
logic [8:0] sp_wpx;

wire [9:0] sp_dy  = {2'b00, sp_line} + {2'b00, spr2_d} - 10'd240;   // line - (240 - y)
wire [3:0] sp_srcx = {sp_grp, sp_k};
wire [3:0] sp_dx   = sp_attr[6] ? sp_srcx : ~sp_srcx;               // attr bit 6 clear = X flipped
wire [8:0] sp_px   = {1'b0, sp_x} + {5'd0, sp_dx};
wire [3:0] sp_pen  = {sp_hi[3 - sp_k], sp_hi[7 - sp_k], sp_lo[3 - sp_k], sp_lo[7 - sp_k]};
wire [12:0] sp_rom = {1'b0, sp_code[5:0], sp_row[3], sp_grp, sp_row[2:0]};

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
            end else if (sp_slot == 5'd31)
                sp_st <= SP_IDLE;
            else begin
                sp_slot <= sp_slot + 5'd1;
                sp_st   <= SP_Y0;
            end
        end
        SP_A0: begin spr_ram_a <= {2'b00, sp_slot, 1'b1}; sp_st <= SP_A1; end
        SP_A1: begin sp_x <= spr1_d; sp_attr <= spr2_d; sp_st <= SP_A2; end
        SP_A2: begin
            sp_code <= spr1_d;
            if (sp_attr[7]) sp_row <= ~sp_row;                           // Y flip
            sp_grp  <= 2'd0;
            sp_st   <= SP_G0;
        end
        SP_G0: begin spr_rom_a <= sp_rom; sp_st <= SP_G1; end
        SP_G1: begin spr_rom_a <= sp_rom | 13'h1000; sp_st <= SP_G2; end
        SP_G2: begin sp_lo <= spr_rom_d; sp_st <= SP_G3; end
        SP_G3: begin sp_hi <= spr_rom_d; sp_k <= 2'd0; sp_st <= SP_P0; end
        // per pixel: lookup PROM address, wait, write if the lookup is not 0
        SP_P0: begin slut_a <= {sp_attr[3:0], sp_pen}; sp_wpx <= sp_px; sp_st <= SP_P1; end
        SP_P1: sp_st <= SP_P2;
        SP_P2: begin
            if (!sp_wpx[8] && slut_d[3:0] != 4'd0) begin
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
                else if (sp_slot == 5'd31)
                    sp_st <= SP_IDLE;
                else begin
                    sp_slot <= sp_slot + 5'd1;
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
        sp_slot <= 5'd8;
        sp_st   <= SP_Y0;
    end
end

/////////////////////////////  Mixer / palette  /////////////////////////////

// Pixel H is captured on its ce_pix edge and leaves as RGB on the next one:
// line buffer + char lookup PROM, then the palette PROM (sprites 0-15, chars 16-31)
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
            3'd3: begin pal_a <= s2_spr ? {1'b0, s2_sv} : {1'b1, clut_d[3:0]}; mix_st <= 3'd4; end
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
