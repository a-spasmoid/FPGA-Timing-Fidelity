`timescale 1ns / 1ps
// =============================================================================
// ascon_c4 : round register placed after the S-box (retimed round)
//
// Ascon-AEAD128 (NIST SP 800-232) encrypt-only core, candidate 4.
//
// Candidate boundary : module ascon_c4  (ports identical to ascon_core)
// Differs from c0 in : permutation_12 (module permutation_c4); the other four modules are the baseline, renamed
// Contract           : identical external cycle-by-cycle behaviour to c0 / ascon_core
//                      (checked by tb/ascon_equivalence_tb.sv).
// Self-contained     : this file defines every module it uses; nothing is shared
//                      with any other candidate.
// =============================================================================

module ascon_c4 (
    input  wire clk,
    input  wire rst,

    // System-Level Commands
    input  wire start_cipher,
    input  wire has_ad,
    input  wire has_pt,
    input  wire ad_last,
    input  wire pt_last,

    // Raw Data Inputs
    input  wire [127:0] key,
    input  wire [127:0] nonce,
    input  wire [127:0] data_in, 
    input  wire [4:0]   data_bytes
    // System-Level Outputs
    output wire [127:0] ciphertext_out,
    output wire [127:0] tag_out,
    output wire         cipher_done
);
    // Internal Interconnect Wires
    wire ctrl_start_init;
    wire ctrl_start_ad;
    wire ctrl_start_pt;
    wire ctrl_start_final;
    wire ctrl_rounds_8;
    wire ctrl_en_domain_sep;
    wire ctrl_en_post_init_xor;
    wire status_perm_done;
    // 1. Control Path
    ascon_fsm_c4 controller (
        .clk(clk),
        .rst(rst),
        .start_cipher(start_cipher),
        .has_ad(has_ad),
        .has_pt(has_pt),
        .ad_last(ad_last),
        .pt_last(pt_last),
        .perm_done(status_perm_done), 

        .start_init(ctrl_start_init),
        .start_ad(ctrl_start_ad),
        .start_pt(ctrl_start_pt),
        .start_final(ctrl_start_final),
        .rounds_8(ctrl_rounds_8),
        .en_domain_sep(ctrl_en_domain_sep),
        .en_post_init_xor(ctrl_en_post_init_xor), 
        .cipher_done(cipher_done)
    );
    // 2. Datapath
    ascon_dp_c4 datapath (
        .clk(clk),
        .rst(rst),

        .start_init(ctrl_start_init),
        .start_ad(ctrl_start_ad),
        .start_pt(ctrl_start_pt),
        .start_final(ctrl_start_final),
        .rounds_8(ctrl_rounds_8),
        .en_domain_sep(ctrl_en_domain_sep),
        .en_post_init_xor(ctrl_en_post_init_xor),

        .ad_last(ad_last),
        .pt_last(pt_last),
        .data_bytes(data_bytes),

        .key(key),
        .nonce(nonce),
        .data_in(data_in),

        .ciphertext_out(ciphertext_out),
        .tag_out(tag_out),
        .perm_done(status_perm_done) 
    );
endmodule


module ascon_fsm_c4 (
    input  wire clk,
    input  wire rst,
    
    input  wire start_cipher,
    input  wire has_ad,    
    input  wire has_pt,    
    input  wire ad_last,     
    input  wire pt_last,      
    
    input  wire perm_done,
    
    output reg  start_init,
    output reg  start_ad,
    output reg  start_pt,
    output reg  start_final,
    output reg  rounds_8,
    output reg  en_domain_sep,
    output reg  en_post_init_xor, 
    output reg  cipher_done
);

    localparam [3:0] 
        ST_IDLE       = 4'd0,
        ST_INIT_LOAD  = 4'd1,
        ST_INIT_WAIT  = 4'd2,
        ST_AD_LOAD    = 4'd3,
        ST_AD_WAIT    = 4'd4,
        ST_PT_LOAD    = 4'd5,
        ST_PT_WAIT    = 4'd6,
        ST_FINAL_LOAD = 4'd7,
        ST_FINAL_WAIT = 4'd8,
        ST_DONE       = 4'd9;

    reg [3:0] state, next_state;
    reg [3:0] prev_state; // FIXED: Added history tracking
    // FIXED: latches ad_last as it was when the current AD block was loaded.
    // ST_AD_WAIT decides "was that block the last one" only after the block's
    // P8 rounds finish, several cycles later - by then the caller has already
    // moved ad_last/data_in on to the next block (see ascon_tb.v's own
    // "pre-load onto the wire NOW" pattern), so reading the live signal there
    // would sample the wrong block's flag.
    reg       ad_last_latched;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= ST_IDLE;
            prev_state      <= ST_IDLE;
            ad_last_latched <= 1'b0;
        end else begin
            state      <= next_state;
            prev_state <= state;
            if (state == ST_AD_LOAD) ad_last_latched <= ad_last;
        end
    end

    always @(*) begin
        next_state       = state;
        start_init       = 1'b0;
        start_ad         = 1'b0;
        start_pt         = 1'b0;
        start_final      = 1'b0;
        rounds_8       = 1'b0;
        en_domain_sep    = 1'b0;
        cipher_done      = 1'b0;
        
        en_post_init_xor = (prev_state == ST_INIT_WAIT); 

        case (state)
            ST_IDLE: begin
                if (start_cipher) next_state = ST_INIT_LOAD;
            end

            ST_INIT_LOAD: begin
                start_init = 1'b1;
                rounds_8 = 1'b0; 
                next_state = ST_INIT_WAIT;
            end

            ST_INIT_WAIT: begin
                if (perm_done) begin
                    if (has_ad) next_state = ST_AD_LOAD;
                    else if (has_pt) next_state = ST_PT_LOAD;
                    else next_state = ST_FINAL_LOAD;
                end
            end

            ST_AD_LOAD: begin
                start_ad   = 1'b1;
                rounds_8 = 1'b1; 
                next_state = ST_AD_WAIT;
            end

            ST_AD_WAIT: begin
                rounds_8 = 1'b1;
                if (perm_done) begin
                    if (!ad_last_latched) next_state = ST_AD_LOAD;
                    else if (has_pt) next_state = ST_PT_LOAD;
                    else next_state = ST_FINAL_LOAD;
                end
            end
            ST_PT_LOAD: begin
                start_pt   = 1'b1;
                // FIXED: domain separation must fire exactly once, on the
                // first entry into the PT phase, not on every PT block.
                en_domain_sep = (prev_state == ST_INIT_WAIT) || (prev_state == ST_AD_WAIT);

                if (pt_last) begin
                    rounds_8 = 1'b0; // Force 12-rounds for finalization
                    next_state = ST_FINAL_WAIT; // Jump straight to finalization
                end else begin
                    rounds_8 = 1'b1; // Standard P8 PT phase
                    next_state = ST_PT_WAIT;
                end
            end
            
            ST_PT_WAIT: begin
                rounds_8 = 1'b1;

                if (perm_done)
                    next_state = ST_PT_LOAD;
            end
            ST_FINAL_LOAD: begin
                start_final = 1'b1;
                rounds_8  = 1'b0; // 12 rounds for finalization
                if (!has_pt) begin
                   en_domain_sep = 1'b1;
                end

                 next_state = ST_FINAL_WAIT; 
                 end

            ST_FINAL_WAIT: begin
                if (perm_done) next_state = ST_DONE;
            end

            ST_DONE: begin
                cipher_done = 1'b1;
                if (!start_cipher) next_state = ST_IDLE;
            end

            default: next_state = ST_IDLE;
        endcase
    end
endmodule

// Ascon-AEAD128 datapath (NIST SP 800-232).
//
// 128-bit rate: data is absorbed into state words s0 (bits [127:64] of the bus)
// and s1 (bits [63:0]). See iv_key_nonce_c4 for the key/nonce bus convention.
//
// HARDWARE PADDING (added 2026-09-10):
//   The last AD block (start_ad & ad_last) and the last PT block
//   (start_pt & pt_last) are 10*-padded in hardware using `data_bytes`, the
//   number of real message bytes in that final block (0..15). Byte `data_bytes`
//   is forced to 0x01 and every byte above it to 0x00. Non-final blocks ignore
//   `data_bytes` and absorb all 16 bytes. For a message whose length is an
//   exact multiple of 16 (including 0), the caller feeds one extra final block
//   with data_bytes = 0 -> hardware emits 0x01,00..00. Callers no longer pad.
//   Ciphertext of a partial final PT block is masked to `data_bytes` bytes.
module ascon_dp_c4 (
    input  wire clk,
    input  wire rst,

    input  wire start_init,
    input  wire start_ad,
    input  wire start_pt,
    input  wire start_final,
    input  wire rounds_8,           // 1 = P8 (AD / non-last PT), 0 = P12 (init / final / last PT)
    input  wire en_domain_sep,
    input  wire en_post_init_xor,

    input  wire        ad_last,     // this AD block is the final one -> 10* pad it
    input  wire        pt_last,     // this PT block is the final one -> 10* pad it
    input  wire [4:0]  data_bytes,  // real message bytes in the final block (0..15)

    input  wire [127:0] key,
    input  wire [127:0] nonce,
    input  wire [127:0] data_in,    // {block_word0[127:64], block_word1[63:0]}, UNPADDED

    output wire [127:0] ciphertext_out,
    output wire [127:0] tag_out,
    output wire perm_done
);
    // SP 800-232 domain-separation constant: S[4] ^= 1<<63
    localparam [63:0] DSEP = 64'h8000000000000000;

    wire [63:0] K0 = key[127:64];
    wire [63:0] K1 = key[63:0];

    // ---------------------------------------------------------------
    // 10* padding of the final block.
    //   busbyte j (j = 0..15) lives at bit 64+8j of word0 for j<8,
    //   and at bit 8(j-8) of word1 for j>=8 (little-endian word load).
    // ---------------------------------------------------------------
    function [127:0] ascon_pad10;
        input [127:0] blk;
        input [4:0]   nbytes;
        integer j;
        reg [127:0] r;
        begin
            r = 128'd0;
            for (j = 0; j < 16; j = j + 1) begin
                if (j < 8)
                    r[64 + 8*j +: 8] = (j <  nbytes) ? blk[64 + 8*j +: 8] :
                                       (j == nbytes) ? 8'h01 : 8'h00;
                else
                    r[8*(j-8) +: 8]  = (j <  nbytes) ? blk[8*(j-8) +: 8] :
                                       (j == nbytes) ? 8'h01 : 8'h00;
            end
            ascon_pad10 = r;
        end
    endfunction

    // keep only the low `nbytes` message bytes, zero the rest
    function [127:0] ascon_mask;
        input [127:0] v;
        input [4:0]   nbytes;
        integer j;
        reg [127:0] r;
        begin
            r = 128'd0;
            for (j = 0; j < 16; j = j + 1) begin
                if (j < 8) r[64 + 8*j +: 8] = (j < nbytes) ? v[64 + 8*j +: 8] : 8'h00;
                else       r[8*(j-8) +: 8]  = (j < nbytes) ? v[8*(j-8) +: 8] : 8'h00;
            end
            ascon_mask = r;
        end
    endfunction

    wire        pad_now   = (start_ad & ad_last) | (start_pt & pt_last);
    wire [4:0]  eff_bytes = pad_now ? data_bytes : 5'd16;
    wire [127:0] blk_eff  = pad_now ? ascon_pad10(data_in, data_bytes) : data_in;
    wire [63:0] d0 = blk_eff[127:64];
    wire [63:0] d1 = blk_eff[63:0];

    wire [63:0] init_s0, init_s1, init_s2, init_s3, init_s4;
    wire [63:0] perm_s0, perm_s1, perm_s2, perm_s3, perm_s4;
    reg  [63:0] mux_s0, mux_s1, mux_s2, mux_s3, mux_s4;
    wire perm_start;

    iv_key_nonce_c4 loader (
        .key(key),
        .nonce(nonce),
        .s0(init_s0),
        .s1(init_s1),
        .s2(init_s2),
        .s3(init_s3),
        .s4(init_s4)
    );

    // Post-initialization key XOR (s3 ^= K0, s4 ^= K1), applied once on the
    // first absorb after P12 regardless of whether that is an AD or PT block.
    wire [63:0] s3_routed = en_post_init_xor ? (perm_s3 ^ K0) : perm_s3;
    wire [63:0] s4_routed = en_post_init_xor ? (perm_s4 ^ K1) : perm_s4;

    always @(*) begin
        if (start_init) begin
            mux_s0 = init_s0;
            mux_s1 = init_s1;
            mux_s2 = init_s2;
            mux_s3 = init_s3;
            mux_s4 = init_s4;
        end
        else if (start_ad) begin
            mux_s0 = perm_s0 ^ d0;
            mux_s1 = perm_s1 ^ d1;
            mux_s2 = perm_s2;
            mux_s3 = s3_routed;
            mux_s4 = s4_routed;
        end
        else if (start_pt) begin
            mux_s0 = perm_s0 ^ d0;
            mux_s1 = perm_s1 ^ d1;
            mux_s4 = en_domain_sep ? (s4_routed ^ DSEP) : s4_routed;

            if (!rounds_8) begin
                // LAST plaintext block: absorb, then fold in the finalization
                // pre-P12 key XOR (S[2] ^= K0, S[3] ^= K1) and run P12.
                mux_s2 = perm_s2   ^ K0;
                mux_s3 = s3_routed ^ K1;
            end else begin
                mux_s2 = perm_s2;
                mux_s3 = s3_routed;
            end
        end
        else if (start_final) begin
            // Unused in the current FSM (plaintext phase always runs, even for
            // empty PT, so finalization is fused into the last-PT-block path).
            // Kept spec-correct for completeness.
            mux_s0 = perm_s0;
            mux_s1 = perm_s1;
            mux_s2 = perm_s2   ^ K0;
            mux_s3 = s3_routed ^ K1;
            mux_s4 = en_domain_sep ? (s4_routed ^ DSEP) : s4_routed;
        end
        else begin
            mux_s0 = perm_s0;
            mux_s1 = perm_s1;
            mux_s2 = perm_s2;
            mux_s3 = perm_s3;
            mux_s4 = perm_s4;
        end
    end

    assign perm_start = start_init | start_ad | start_pt | start_final;

    permutation_c4 engine (
        .clk(clk),
        .rst(rst),
        .start(perm_start),
        .rounds_8(rounds_8),
        .s0(mux_s0),
        .s1(mux_s1),
        .s2(mux_s2),
        .s3(mux_s3),
        .s4(mux_s4),
        .s0_out(perm_s0),
        .s1_out(perm_s1),
        .s2_out(perm_s2),
        .s3_out(perm_s3),
        .s4_out(perm_s4),
        .done(perm_done)
    );

    // Ciphertext block = (state XOR plaintext) captured at absorb time, masked
    // to the real byte count for a partial final block.
    // Bus layout matches data_in: word0 in [127:64], word1 in [63:0].
    reg [127:0] ciphertext_reg;
    always @(posedge clk or posedge rst) begin
        if (rst)
            ciphertext_reg <= 128'd0;
        else if (start_pt)
            ciphertext_reg <= ascon_mask({perm_s0 ^ d0, perm_s1 ^ d1}, eff_bytes);
    end

    assign ciphertext_out = ciphertext_reg;

    // Tag = S[3] ^ K0 || S[4] ^ K1  (post final P12)
    assign tag_out = {perm_s3 ^ K0, perm_s4 ^ K1};
endmodule

// ---------------------------------------------------------------------------
// c4 : register placed after the S-box (retimed round)
//
//   c0 stores the state at the START of a round (x) and computes
//       x' = L(S(C_r(x)))                         in one cycle.
//   c4 stores the S-box OUTPUT of the round in flight (z = S(C_r(x))) and computes
//       n  = L(z)                    (state entering the next round)
//       z' = S(C_{r+1}(n))           in one cycle.
//   The loop through the register has the same logic as c0, but the first S-box
//   now sits on the load path (the engine input mux feeds it) and the result capture
//   (s_out <= n) is one S-box shallower.
//
//   rn is the index of the constant used for the NEXT S-box (= current round + 1),
//   so a P12 runs rn = 1..12 and a P8 runs rn = 5..12: still 12 / 8 active cycles,
//   with the same start / done / result-capture cycles as c0.
// ---------------------------------------------------------------------------
module permutation_c4 (
    input clk,
    input rst,
    input start,
    input [63:0] s0, s1, s2, s3, s4,
    input rounds_8,  // 1 = P8 (AD/PT, SP 800-232 b-rounds), 0 = P12 (init/final)
    output reg [63:0] s0_out, s1_out, s2_out, s3_out, s4_out,
    output reg done
);

    reg [63:0] z0, z1, z2, z3, z4;   // S-box output of the round in flight
    reg [3:0]  rn;                   // index of the next round constant
    reg        active;

    wire load = start && !active;

    // p_L of the registered S-box output = state entering the next round
    wire [63:0] n0, n1, n2, n3, n4;

    assign n0 = z0 ^ ((z0 >> 19) | (z0 << 45))
                   ^ ((z0 >> 28) | (z0 << 36));

    assign n1 = z1 ^ ((z1 >> 61) | (z1 << 3))
                   ^ ((z1 >> 39) | (z1 << 25));

    assign n2 = z2 ^ ((z2 >> 1)  | (z2 << 63))
                   ^ ((z2 >> 6)  | (z2 << 58));

    assign n3 = z3 ^ ((z3 >> 10) | (z3 << 54))
                   ^ ((z3 >> 17) | (z3 << 47));

    assign n4 = z4 ^ ((z4 >> 7)  | (z4 << 57))
                   ^ ((z4 >> 41) | (z4 << 23));

    // S-box input: the loaded state (round 0 / 4 of a fresh permutation) or the next-round state
    wire [63:0] i0 = load ? s0 : n0;
    wire [63:0] i1 = load ? s1 : n1;
    wire [63:0] i2 = load ? s2 : n2;
    wire [63:0] i3 = load ? s3 : n3;
    wire [63:0] i4 = load ? s4 : n4;

    // p_C: constant of the round whose S-box is being evaluated
    wire [7:0]  rc    = load ? (rounds_8 ? 8'hb4 : 8'hf0) : {~rn, rn};
    wire [63:0] pc_x2 = i2 ^ {56'd0, rc};

    wire [63:0] ps_a0, ps_a1, ps_a2, ps_a3, ps_a4;
    wire [63:0] ps_t0, ps_t1, ps_t2, ps_t3, ps_t4;
    wire [63:0] ps_b0, ps_b1, ps_b2, ps_b3, ps_b4;
    wire [63:0] q0, q1, q2, q3, q4;

    // step 1: initial XORs - pre processing
    assign ps_a0 = i0    ^ i4;
    assign ps_a1 = i1;
    assign ps_a2 = pc_x2 ^ i1;
    assign ps_a3 = i3;
    assign ps_a4 = i4    ^ i3;

    // step 2: AND-NOT terms the nonlinear stage
    assign ps_t0 = (~ps_a0) & ps_a1;
    assign ps_t1 = (~ps_a1) & ps_a2;
    assign ps_t2 = (~ps_a2) & ps_a3;
    assign ps_t3 = (~ps_a3) & ps_a4;
    assign ps_t4 = (~ps_a4) & ps_a0;

    // step 3: XOR back the mixing stage
    assign ps_b0 = ps_a0 ^ ps_t1;
    assign ps_b1 = ps_a1 ^ ps_t2;
    assign ps_b2 = ps_a2 ^ ps_t3;
    assign ps_b3 = ps_a3 ^ ps_t4;
    assign ps_b4 = ps_a4 ^ ps_t0;

    // step 4: final XORs + invert x2
    assign q0 = ps_b0 ^ ps_b4;
    assign q1 = ps_b1 ^ ps_b0;
    assign q2 = ~ps_b2;
    assign q3 = ps_b3 ^ ps_b2;
    assign q4 = ps_b4;

    // Sequential: one full round per clock
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            z0     <= 64'd0;
            z1     <= 64'd0;
            z2     <= 64'd0;
            z3     <= 64'd0;
            z4     <= 64'd0;
            rn     <= 4'd0;
            active <= 1'b0;
            done   <= 1'b0;
            s0_out <= 64'd0;
            s1_out <= 64'd0;
            s2_out <= 64'd0;
            s3_out <= 64'd0;
            s4_out <= 64'd0;
        end
        else begin
            done <= 1'b0;

            if (load) begin
                z0     <= q0;
                z1     <= q1;
                z2     <= q2;
                z3     <= q3;
                z4     <= q4;
                rn     <= rounds_8 ? 4'd5 : 4'd1;
                active <= 1'b1;
            end
            else if (active) begin
                z0 <= q0;
                z1 <= q1;
                z2 <= q2;
                z3 <= q3;
                z4 <= q4;
                rn <= rn + 4'd1;

                if (rn == 4'd12) begin
                    s0_out <= n0;
                    s1_out <= n1;
                    s2_out <= n2;
                    s3_out <= n3;
                    s4_out <= n4;
                    active <= 1'b0;
                    done   <= 1'b1;
                end
            end
        end
    end

endmodule

// Ascon-AEAD128 (NIST SP 800-232) initial state loader.
//
// Bus convention: key/nonce are {word0, word1} with word0 in bits [127:64],
// where word0 = little-endian load of the first 8 key/nonce bytes (= K0/N0 in
// the spec) and word1 = little-endian load of the last 8 bytes (K1/N1).
module iv_key_nonce_c4(
    input [127:0] key, nonce,
    output [63:0] s0,s1,s2,s3,s4
    );
    // IV = version(1) || 0 || (b<<4|a)=0x8c || taglen=128 (LE 16b) || rate=16 || 0 || 0
    // loaded little-endian into one 64-bit word:
    localparam [63:0] ascon_iv = 64'h00001000808c0001;
    assign s0 = ascon_iv;
    assign s1 = key[127:64];   // K0
    assign s2 = key[63:0];     // K1
    assign s3 = nonce[127:64]; // N0
    assign s4 = nonce[63:0];   // N1

endmodule
