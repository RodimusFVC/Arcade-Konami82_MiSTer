//============================================================================
//
//  Toshiba TC8830F voice LSI (1-bit ADM playback), Chance Kun
//  Copyright (C) 2026 Rodimus
//
//  Written from MAME tc8830f.cpp (hap). MAME's model is marked preliminary; this follows it as-is:
//  CPU-control play only (no recording, chip read, RAM or manual control).
//
//  Commands are 4-bit nibbles on P0-P3. 1 = no-op, 2 = play, 3 = stop,
//  4 ADLD1 / 5 ADLD2 + 5 nibbles = start / stop address (nibble n -> bits 4n+3..4n),
//  6 CNDT + 1 nibble = bitrate, 7 LABEL + 2 nibbles = phrase: start / stop from the ROM table at
//  phrase * 4 and phrase * 4 + 4 (3 bytes, little endian each), then play.
//  Sample rate = 512 kHz / (16 * (4 - bitrate)); one ROM bit per sample, LSB first.
//
//  The sample ROM (128K) is read a byte at a time through the SDRAM port; the phrase table lookup
//  that MAME does instantly takes a few microseconds here, and a sample waits for its byte.
//
//============================================================================

module tc8830f
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,

    input  logic        p_wr,           // pulse: /W with P0-P3
    input  logic  [3:0] p_data,
    input  logic        acl,            // pulse: /ACL

    output logic        rom_req,        // held until !rom_busy, data valid then
    output logic [16:0] rom_addr,
    input  logic  [7:0] rom_data,
    input  logic        rom_busy,

    output logic signed [15:0] out
);

localparam logic [16:0] MASK = 17'h1FFFF;   // 128K sample ROM

logic        playing;
logic [23:0] address, stop_address;
logic  [2:0] bitcount;
logic  [1:0] bitrate;
logic  [2:0] prevbits;
logic signed [15:0] delta;
logic signed [15:0] level;
logic  [3:0] command;
logic  [2:0] cmd_rw;
logic  [5:0] phrase;

// byte under the play pointer
logic  [7:0] cur_byte;
logic        need_byte;

// phrase table lookup
logic        lbl_run;
logic  [2:0] lbl_i;
logic  [7:0] lbl_offs;
logic [23:0] lbl_start, lbl_stop;

// one command nibble may wait while a lookup runs
logic        pend_wr, pend_acl;
logic  [3:0] pend_data;

// sample clock: 512 kHz / 16 = 32 kHz = 1536 clocks, times (4 - bitrate)
logic [12:0] smp_cnt;
logic        smp_due;
wire  [12:0] smp_last = (13'd1536 * (13'd4 - {11'd0, bitrate})) - 13'd1;

// ROM port: one fetch at a time, for the lookup or for the play pointer
logic        f_lbl;
wire  [7:0]  lbl_a = (lbl_i < 3'd3) ? lbl_offs | {6'd0, lbl_i[1:0]}
                                    : (lbl_offs + 8'd4) | {6'd0, lbl_i[1:0] - 2'd3};

assign out = playing ? level : 16'sd0;

// ADM step: after 000 or 111 the step doubles (up to 0x2000), otherwise it shrinks by 8; never below 1
function automatic logic signed [15:0] adm_step(input logic [2:0] pb, input logic signed [15:0] d);
    logic signed [15:0] n;
    if (pb == 3'b111 || pb == 3'b000) n = (d < 16'sh2000) ? d <<< 1 : d;
    else                              n = d - 16'sd8;
    adm_step = (n <= 16'sd0) ? 16'sd1 : n;
endfunction

function automatic logic signed [15:0] sat16(input logic signed [15:0] l, input logic signed [15:0] d, input logic up);
    logic signed [16:0] s;
    s = up ? {l[15], l} + {d[15], d} : {l[15], l} - {d[15], d};
    if      (s > 17'sd32767)  sat16 = 16'sd32767;
    else if (s < -17'sd32768) sat16 = -16'sd32768;
    else                      sat16 = s[15:0];
endfunction


always_ff @(posedge clk) begin
    if (reset) begin
        playing <= 1'b0; address <= 24'h100; stop_address <= 24'd0; bitcount <= 3'd0; bitrate <= 2'd0;
        prevbits <= 3'd0; delta <= 16'sd1; level <= 16'sd0; command <= 4'd0; cmd_rw <= 3'd0; phrase <= 6'd0;
        need_byte <= 1'b1; lbl_run <= 1'b0; lbl_i <= 3'd0; rom_req <= 1'b0; f_lbl <= 1'b0;
        pend_wr <= 1'b0; pend_acl <= 1'b0; smp_cnt <= 13'd0; smp_due <= 1'b0;
    end else begin
        // ---- sample clock (the stream runs whether or not the chip is playing)
        if (!pause) begin
            if (smp_cnt >= smp_last) begin smp_cnt <= 13'd0; smp_due <= 1'b1; end
            else smp_cnt <= smp_cnt + 13'd1;
        end

        if (p_wr)  begin pend_wr  <= 1'b1; pend_data <= p_data; end
        if (acl)   pend_acl <= 1'b1;

        // ---- ROM fetch
        if (rom_req) begin
            if (!rom_busy) begin
                rom_req <= 1'b0;
                if (f_lbl) begin
                    case (lbl_i)
                        3'd0: lbl_start[7:0]   <= rom_data;
                        3'd1: lbl_start[15:8]  <= rom_data;
                        3'd2: lbl_start[23:16] <= rom_data;
                        3'd3: lbl_stop[7:0]    <= rom_data;
                        3'd4: lbl_stop[15:8]   <= rom_data;
                        default: lbl_stop[23:16] <= rom_data;
                    endcase
                    lbl_i <= lbl_i + 3'd1;
                end else begin
                    cur_byte  <= rom_data;
                    need_byte <= 1'b0;
                end
            end
        end
        else if (lbl_run && lbl_i != 3'd6) begin
            rom_req <= 1'b1; f_lbl <= 1'b1; rom_addr <= {9'd0, lbl_a};
        end
        else if (lbl_run) begin
            // LABEL done: load the addresses and start
            address      <= {7'd0, lbl_start[16:0] & MASK};
            stop_address <= {7'd0, lbl_stop[16:0] & MASK};
            bitcount <= 3'd0; prevbits <= 3'd0; delta <= 16'sd1; level <= 16'sd0;
            playing  <= 1'b1; need_byte <= 1'b1; lbl_run <= 1'b0;
        end
        else if (need_byte) begin
            rom_req <= 1'b1; f_lbl <= 1'b0; rom_addr <= address[16:0] & MASK;
        end

        // ---- /ACL: reset, then CPU-control play mode at bitrate 0 (MAME reset(): write_p 1, 6, 0)
        else if (pend_acl) begin
            pend_acl <= 1'b0;
            playing <= 1'b0; address <= 24'h100; bitcount <= 3'd0; prevbits <= 3'd0;
            delta <= 16'sd1; level <= 16'sd0; cmd_rw <= 3'd0; bitrate <= 2'd0; command <= 4'd6;
            need_byte <= 1'b1;
        end

        // ---- command nibble
        else if (pend_wr) begin
            pend_wr <= 1'b0;
            if (cmd_rw == 3'd0) begin
                command <= pend_data;
                case (pend_data)
                    4'h2: playing <= 1'b1;
                    4'h3: playing <= 1'b0;
                    4'h4, 4'h5, 4'h6, 4'h7: cmd_rw <= 3'd1;
                    default: ;
                endcase
            end else begin
                case (command)
                    4'h4: begin                                      // ADLD1: start address
                        case (cmd_rw)
                            3'd1: address[7:4]   <= pend_data;
                            3'd2: address[11:8]  <= pend_data;
                            3'd3: address[15:12] <= pend_data;
                            3'd4: address[19:16] <= pend_data;
                            default: begin
                                address  <= {7'd0, address[16:0] & MASK};
                                bitcount <= 3'd0;
                            end
                        endcase
                        need_byte <= 1'b1;
                        cmd_rw <= (cmd_rw == 3'd5) ? 3'd0 : cmd_rw + 3'd1;
                    end
                    4'h5: begin                                      // ADLD2: stop address
                        case (cmd_rw)
                            3'd1: stop_address[7:4]   <= pend_data;
                            3'd2: stop_address[11:8]  <= pend_data;
                            3'd3: stop_address[15:12] <= pend_data;
                            3'd4: stop_address[19:16] <= pend_data;
                            default: stop_address <= {7'd0, stop_address[16:0] & MASK};
                        endcase
                        cmd_rw <= (cmd_rw == 3'd5) ? 3'd0 : cmd_rw + 3'd1;
                    end
                    4'h6: begin                                      // CNDT: bitrate
                        bitrate <= pend_data[1:0];
                        cmd_rw  <= 3'd0;
                    end
                    4'h7: begin                                      // LABEL: phrase
                        if (cmd_rw == 3'd1) begin
                            phrase <= {phrase[5:4], pend_data};
                            cmd_rw <= 3'd2;
                        end else begin
                            phrase   <= {pend_data[1:0], phrase[3:0]};
                            lbl_offs <= {pend_data[1:0], phrase[3:0], 2'b00};
                            lbl_i    <= 3'd0;
                            lbl_run  <= 1'b1;
                            cmd_rw   <= 3'd0;
                        end
                    end
                    default: cmd_rw <= 3'd0;
                endcase
            end
        end

        // ---- one sample (waits for its byte, and for a running lookup)
        else if (smp_due && !rom_req) begin
            smp_due <= 1'b0;
            if (playing) begin
                bitcount <= bitcount + 3'd1;
                if (bitcount == 3'd7) begin
                    address   <= {7'd0, (address[16:0] + 17'd1) & MASK};
                    need_byte <= 1'b1;
                    if ({7'd0, (address[16:0] + 17'd1) & MASK} == stop_address) playing <= 1'b0;
                end

                // ADM: after 000 or 111 the step doubles (up to 0x2000), otherwise it shrinks by 8
                level <= sat16(level, adm_step(prevbits, delta), cur_byte[bitcount]);
                delta <= adm_step(prevbits, delta);
                prevbits <= {prevbits[1:0], cur_byte[bitcount]};
            end
        end
    end
end

endmodule
