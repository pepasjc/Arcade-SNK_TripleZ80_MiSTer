//============================================================================
//  SNK Triple Z80 (ASO / Alpha Mission) for MiSTer FPGA - RetroAchievements
//  RAM tap
//
//  Turns the memory writes of the three Z80s into the single write port of
//  tz80_ra_mirror, laid out exactly as FinalBurn Neo's "All Ram" block so
//  the ARM region table is the identity.
//
//  RA arcade sets were written against FinalBurn Neo. Its SNK driver
//  (src/burn/drv/pre90s/d_snk.cpp, MemIndex from AllRam; AsoInit maps)
//  exposes:
//      0x0000 DrvFgVRAM    0x0800  (not used by ASO)
//      0x0800 DrvBgVRAM    0x2000  CPU A E800-F7FF, CPU B D800-E7FF (0x1000 used)
//      0x2800 DrvShareRAM  0x1800  CPU A D800-DFFF, CPU B C800-CFFF (0x800 used)
//      0x4000 DrvSprRAM    0x1800  CPU A E000-E7FF, CPU B D000-D7FF (0x800 used)
//      0x5800 DrvTxtRAM    0x0800  CPU A/B F800-FFFF
//      0x6000 DrvZ80RAM2   0x1000  sound CPU C000-C7FF (0x800 used)
//  The shadow covers all of it (AW=15). The Z80 is 8-bit: shadow byte k is
//  RA address k (no byte swap).
//
//  The writes are taken at each CPU's own bus (address as the CPU sees it),
//  which is what FBNeo models, rather than at the time-multiplexed video RAM
//  bus. Every source is a level write strobe (/MREQ & /WR, held for several
//  clocks); each write is reported once, on the clock after its strobe
//  falls, with the address and data of its last clock. The pulses then go
//  through one-deep latches, so two sources ending on the same clock are
//  written on consecutive clocks.
//
//  SPDX-License-Identifier: GPL-2.0-or-later (same terms as the rest of the core)
//============================================================================

module tz80_ra_tap (
    input             clk,

    input             a_wr,     // CPU A (main)
    input      [15:0] a_ad,
    input      [ 7:0] a_do,
    input             b_wr,     // CPU B (sub)
    input      [15:0] b_ad,
    input      [ 7:0] b_do,
    input             s_wr,     // sound CPU
    input      [15:0] s_ad,
    input      [ 7:0] s_do,

    // tz80_ra_mirror write port
    output reg [14:0] ra_wr_word,
    output reg [15:0] ra_wr_din,
    output reg [ 1:0] ra_wr_be
);

// CPU address -> FBNeo All Ram offset, {valid, 15-bit offset}
function automatic [15:0] map_a(input [15:0] a);
    reg [15:0] a_e800;
    a_e800 = a - 16'hE800;
    casez( a[15:11] )
        5'b1101_1: map_a = { 1'b1, 15'h2800 + { 4'd0, a[10:0] } };              // D800-DFFF shared
        5'b1110_0: map_a = { 1'b1, 15'h4000 + { 4'd0, a[10:0] } };              // E000-E7FF sprites
        5'b1110_1,
        5'b1111_0: map_a = { 1'b1, 15'h0800 + { 3'd0, a_e800[11:0] } };        // E800-F7FF bg
        5'b1111_1: map_a = { 1'b1, 15'h5800 + { 4'd0, a[10:0] } };              // F800-FFFF text
        default:   map_a = 16'd0;
    endcase
endfunction

function automatic [15:0] map_b(input [15:0] a);
    reg [15:0] a_d800;
    a_d800 = a - 16'hD800;
    casez( a[15:11] )
        5'b1100_1: map_b = { 1'b1, 15'h2800 + { 4'd0, a[10:0] } };              // C800-CFFF shared
        5'b1101_0: map_b = { 1'b1, 15'h4000 + { 4'd0, a[10:0] } };              // D000-D7FF sprites
        5'b1101_1,
        5'b1110_0: map_b = { 1'b1, 15'h0800 + { 3'd0, a_d800[11:0] } };        // D800-E7FF bg
        5'b1111_1: map_b = { 1'b1, 15'h5800 + { 4'd0, a[10:0] } };              // F800-FFFF text
        default:   map_b = 16'd0;
    endcase
endfunction

function automatic [15:0] map_s(input [15:0] a);
    map_s = a[15:11] == 5'b1100_0 ? { 1'b1, 15'h6000 + { 4'd0, a[10:0] } } : 16'd0; // C000-C7FF
endfunction

// Delayed strobes: capture each clock, report on the falling edge
reg        a_wr_l, b_wr_l, s_wr_l;
reg [15:0] a_ad_l, b_ad_l, s_ad_l;
reg  [7:0] a_do_l, b_do_l, s_do_l;

always_ff @(posedge clk) begin
    a_wr_l <= a_wr;
    b_wr_l <= b_wr;
    s_wr_l <= s_wr;
    if( a_wr ) begin a_ad_l <= a_ad; a_do_l <= a_do; end
    if( b_wr ) begin b_ad_l <= b_ad; b_do_l <= b_do; end
    if( s_wr ) begin s_ad_l <= s_ad; s_do_l <= s_do; end
end

wire [15:0] a_map = map_a(a_ad_l);
wire [15:0] b_map = map_b(b_ad_l);
wire [15:0] s_map = map_s(s_ad_l);

// Source requests: {valid, byte offset, data}; order is the output priority
localparam N = 3;
wire [N-1:0] req;
wire [14:0]  r_addr[0:N-1];
wire [ 7:0]  r_din[0:N-1];

assign req[0]    = a_wr_l && !a_wr && a_map[15];
assign r_addr[0] = a_map[14:0];
assign r_din[0]  = a_do_l;

assign req[1]    = b_wr_l && !b_wr && b_map[15];
assign r_addr[1] = b_map[14:0];
assign r_din[1]  = b_do_l;

assign req[2]    = s_wr_l && !s_wr && s_map[15];
assign r_addr[2] = s_map[14:0];
assign r_din[2]  = s_do_l;

// One-deep latches
reg  [N-1:0] pend = 0;
reg  [14:0]  p_addr[0:N-1];
reg  [ 7:0]  p_din[0:N-1];

// first pending latch
reg [N-1:0] grant;
always_comb begin
    grant = 0;
    for (int i = N-1; i >= 0; i--) if (pend[i]) begin grant = 0; grant[i] = 1'b1; end
end

always_ff @(posedge clk) begin
    ra_wr_be <= 2'b00;
    for (int i = 0; i < N; i++) begin
        if (grant[i]) begin
            ra_wr_word <= { 1'b0, p_addr[i][14:1] };
            ra_wr_din  <= { 2{p_din[i]} };
            ra_wr_be   <= p_addr[i][0] ? 2'b10 : 2'b01;
            pend[i]    <= 0;
        end
        if (req[i]) begin
            pend[i]   <= 1;
            p_addr[i] <= r_addr[i];
            p_din[i]  <= r_din[i];
        end
    end
end

endmodule
