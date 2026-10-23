`timescale 1ns / 1ps
// =============================================================================
// ascon_c3 : load-path restructure: shared pad/mask decode + gated-XOR state load
// Ascon-AEAD128 (NIST SP 800-232) encrypt-only core, candidate 3.
//
// Candidate boundary : module ascon_c3  (ports identical to ascon_core)
// Differs from c0 in : ascon_top (module ascon_dp_c3); the other four modules are the baseline, renamed
// Contract           : identical external cycle-by-cycle behaviour to c0 / ascon_core
//                      (checked by tb/ascon_equivalence_tb.sv).
// Self-contained     : this file defines every module it uses; nothing is shared
//                      with any other candidate.
// =============================================================================

module ascon_c3 (
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
    input  wire [4:0]   data_bytes, 

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
    ascon_fsm_c3 controller (
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
    ascon_dp_c3 datapath (
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


module ascon_fsm_c3 (
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
    reg [3:0] prev_state; 
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

// ---------------------------------------------------------------------------
// c3 : load-path restructure (datapath wrapper around the permutation engine)
//
//   Same function as c0's ascon_top, written differently:
//     * the 10* pad and the ciphertext mask share one thermometer / one-hot
//       decode of `data_bytes` (lt[j] = j < n, eq[j] = j == n) instead of two
//       per-byte compare loops;
//     * the 5-way priority if/else mux is replaced by gated-XOR terms
//         S0,S1 ^= data      (AD / PT blocks)
//         S3,S4 ^= K         (first absorb after P12)
//         S2,S3 ^= K         (last PT block, finalization)
//         S4    ^= 1<<63     (domain separation)
//       with a single 2-way select against the init state. The start_* strobes
//       come from the FSM one at a time, so the terms never overlap.
//   Only the cycles in which the permutation engine actually loads (perm_start)
//   consume `mux_s*`; outside those cycles its value is irrelevant, exactly as in c0.
// ---------------------------------------------------------------------------
module ascon_dp_c3 (
    input  wire clk,
    input  wire rst,

    input  wire start_init,
    input  wire start_ad,
    input  wire start_pt,
    input  wire start_final,
    input  wire rounds_8,           // 1 = P8 (AD / non-last PT), 0 = P12 (init / final / last PT)
    input  wire en_domain_sep,
    input  wire en_post_init_xor,

    input  wire        ad_last, 
    input  wire        pt_last,     
    input  wire [4:0]  data_bytes, 

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
    // final-block decode shared by the 10* pad and the ciphertext mask
    //   busbyte j lives at bit 64+8j of word0 for j<8 and at bit 8(j-8)
    //   of word1 for j>=8 (little-endian word load).
    // ---------------------------------------------------------------
    wire        pad_now = (start_ad & ad_last) | (start_pt & pt_last);

    wire [15:0] lt;                       // lt[j] : byte j is a real message byte
    wire [15:0] eq;                       // eq[j] : byte j is the pad byte position
    wire [127:0] keep_mask;               // all-ones on bytes that survive
    wire [127:0] pad_bits;                // 0x01 at the pad byte position

    genvar j;
    generate
        for (j = 0; j < 16; j = j + 1) begin : g_dec
            localparam [4:0]   J  = j;
            localparam integer LO = (j < 8) ? (64 + 8 * j) : (8 * (j - 8));
            assign lt[j] = (data_bytes > J);
            assign eq[j] = (data_bytes == J);
            // not a padded block: every byte passes, no pad byte
            assign keep_mask[LO +: 8] = {8{lt[j] | ~pad_now}};
            assign pad_bits [LO +: 8] = {7'd0, eq[j] & pad_now};
        end
    endgenerate

    wire [127:0] blk_eff = (data_in & keep_mask) | pad_bits;
    wire [63:0]  d0      = blk_eff[127:64];
    wire [63:0]  d1      = blk_eff[63:0];

    wire [63:0] init_s0, init_s1, init_s2, init_s3, init_s4;
    wire [63:0] perm_s0, perm_s1, perm_s2, perm_s3, perm_s4;
    wire        perm_start;

    iv_key_nonce_c3 loader (
        .key(key),
        .nonce(nonce),
        .s0(init_s0),
        .s1(init_s1),
        .s2(init_s2),
        .s3(init_s3),
        .s4(init_s4)
    );

    // ---------------------------------------------------------------
    // state load value
    // ---------------------------------------------------------------
    wire absorb = start_ad | start_pt;                        // XOR data into the rate
    wire key_a  = en_post_init_xor;                           // S3 ^= K0, S4 ^= K1 (after P12)
    wire key_f  = (start_pt & ~rounds_8) | start_final;       // S2 ^= K0, S3 ^= K1 (before final P12)
    wire dsep   = (start_pt | start_final) & en_domain_sep;   // S4 ^= 1<<63

    wire [63:0] n_s0 = perm_s0 ^ ({64{absorb}} & d0);
    wire [63:0] n_s1 = perm_s1 ^ ({64{absorb}} & d1);
    wire [63:0] n_s2 = perm_s2 ^ ({64{key_f}}  & K0);
    wire [63:0] n_s3 = perm_s3 ^ ({64{key_a}}  & K0) ^ ({64{key_f}} & K1);
    wire [63:0] n_s4 = perm_s4 ^ ({64{key_a}}  & K1) ^ ({64{dsep}}  & DSEP);

    wire [63:0] mux_s0 = start_init ? init_s0 : n_s0;
    wire [63:0] mux_s1 = start_init ? init_s1 : n_s1;
    wire [63:0] mux_s2 = start_init ? init_s2 : n_s2;
    wire [63:0] mux_s3 = start_init ? init_s3 : n_s3;
    wire [63:0] mux_s4 = start_init ? init_s4 : n_s4;

    assign perm_start = start_init | start_ad | start_pt | start_final;

    permutation_c3 engine (
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
    reg [127:0] ciphertext_reg;
    always @(posedge clk or posedge rst) begin
        if (rst)
            ciphertext_reg <= 128'd0;
        else if (start_pt)
            ciphertext_reg <= {perm_s0 ^ d0, perm_s1 ^ d1} & keep_mask;
    end

    assign ciphertext_out = ciphertext_reg;

    // Tag = S[3] ^ K0 || S[4] ^ K1  (post final P12)
    assign tag_out = {perm_s3 ^ K0, perm_s4 ^ K1};
endmodule

module permutation_c3 (
    input clk,
    input rst,
    input start,
    input [63:0] s0, s1, s2, s3, s4,
    input rounds_8,  // 1 = P8 (AD/PT, SP 800-232 b-rounds), 0 = P12 (init/final)
    output reg [63:0] s0_out, s1_out, s2_out, s3_out, s4_out,
    output reg done
);

    // round constants for p_C
    reg [7:0] RC [0:11];
    initial begin
        RC[0]  = 8'hf0; RC[1]  = 8'he1;
        RC[2]  = 8'hd2; RC[3]  = 8'hc3;
        RC[4]  = 8'hb4; RC[5]  = 8'ha5;
        RC[6]  = 8'h96; RC[7]  = 8'h87;
        RC[8]  = 8'h78; RC[9]  = 8'h69;
        RC[10] = 8'h5a; RC[11] = 8'h4b;
    end

    reg [63:0] x0, x1, x2, x3, x4;
    reg [3:0]  round;
    reg        active;


    wire [63:0] pc_x2 = x2 ^ {56'd0, RC[round]};


    wire [63:0] ps_a0, ps_a1, ps_a2, ps_a3, ps_a4;
    wire [63:0] ps_t0, ps_t1, ps_t2, ps_t3, ps_t4;
    wire [63:0] ps_b0, ps_b1, ps_b2, ps_b3, ps_b4;
    wire [63:0] s_x0,  s_x1,  s_x2,  s_x3,  s_x4;

    // step 1: initial XORs - pre processing
    assign ps_a0 = x0    ^ x4;
    assign ps_a1 = x1;
    assign ps_a2 = pc_x2 ^ x1;
    assign ps_a3 = x3;
    assign ps_a4 = x4    ^ x3;

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
    assign s_x0 = ps_b0 ^ ps_b4;
    assign s_x1 = ps_b1 ^ ps_b0;
    assign s_x2 = ~ps_b2;
    assign s_x3 = ps_b3 ^ ps_b2;
    assign s_x4 = ps_b4;

    // -------------------------------------------------------
    // p_L: linear diffusion layer
    // rotr(x, n) = (x >> n) | (x << (64-n))
    // -------------------------------------------------------
    wire [63:0] l_x0, l_x1, l_x2, l_x3, l_x4;

    assign l_x0 = s_x0 ^ ((s_x0 >> 19) | (s_x0 << 45))
                        ^ ((s_x0 >> 28) | (s_x0 << 36));

    assign l_x1 = s_x1 ^ ((s_x1 >> 61) | (s_x1 << 3))
                        ^ ((s_x1 >> 39) | (s_x1 << 25));

    assign l_x2 = s_x2 ^ ((s_x2 >> 1)  | (s_x2 << 63))
                        ^ ((s_x2 >> 6)  | (s_x2 << 58));

    assign l_x3 = s_x3 ^ ((s_x3 >> 10) | (s_x3 << 54))
                        ^ ((s_x3 >> 17) | (s_x3 << 47));

    assign l_x4 = s_x4 ^ ((s_x4 >> 7)  | (s_x4 << 57))
                        ^ ((s_x4 >> 41) | (s_x4 << 23));

    // -------------------------------------------------------
    // Sequential: one full round per clock
    // -------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x0     <= 64'd0;
            x1     <= 64'd0;
            x2     <= 64'd0;
            x3     <= 64'd0;
            x4     <= 64'd0;
            round  <= 4'd0;
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

            if (start && !active) begin
                x0     <= s0;
                x1     <= s1;
                x2     <= s2;
                x3     <= s3;
                x4     <= s4;
                round  <= rounds_8 ? 4'd4:4'd0;
                active <= 1'b1;
            end
            else if (active) begin
                x0    <= l_x0;
                x1    <= l_x1;
                x2    <= l_x2;
                x3    <= l_x3;
                x4    <= l_x4;
                round <= round + 4'd1;

                if (round == 4'd11) begin
                    s0_out <= l_x0;
                    s1_out <= l_x1;
                    s2_out <= l_x2;
                    s3_out <= l_x3;
                    s4_out <= l_x4;
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
module iv_key_nonce_c3(
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
