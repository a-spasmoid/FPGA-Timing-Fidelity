`timescale 1ns / 1ps
//============================================================================
// ascon_equivalence_tb.sv  -  common cycle-equivalence regression
//
// The ORIGINAL ascon_core (rtl/) is the reference. Every candidate ascon_c0..c4
// is driven with exactly the same stimulus and compared against it on EVERY clock
// cycle: ciphertext_out, tag_out and cipher_done, 4-state exact (!==).
//
// Phases (stimulus is common to all DUTs; only the reference is checked against
// expected values):
//   1 KAT    all official Ascon-AEAD128 KAT vectors (LWC_AEAD_KAT_128_128.txt),
//            reference ciphertext / tag checked against the expected values
//   2 RAND   directed bit-pattern + length-boundary vectors, then seeded random
//            messages (0..70 byte AD / PT), random idle gaps, random garbage on
//            every input that is a don't-care outside its absorb cycle, start held
//            for several cycles, start pulses while busy
//   3 ABORT  an operation is cut by an asynchronous reset at EVERY cycle k of its
//            run, then a full operation must complete correctly
//   4 CHAOS  fully random stimulus on every input incl. illegal sequences
//            (start while busy / while done, has_ad / has_pt / *_last flipping
//            mid-operation, key and nonce changing mid-operation, random
//            asynchronous resets, start held high); 5 knob sets
//
// Outputs are sampled at the falling clock edge, inputs change 1 ns after the
// rising edge, so asynchronous-reset behaviour is compared mid-cycle as well.
//
// Build with  +define+MUTANTS  to add five deliberately broken cores and prove the
// regression catches them (see scripts/run_equivalence.sh --mutants).
//
// plusargs (all optional): +KAT=<file> +RND=<file> +N_KAT=<n> +N_RND=<n>
//                          +CHAOS_X=<n>  chaos length multiplier (default 4 = ~2.6M cycles)
//                          +SEED=<n>
//============================================================================
`ifdef MUTANTS
  `define NMUT_VAL 5
`else
  `define NMUT_VAL 0
`endif

`define DUT_PORTS(CT, TAG, DN) \
    .clk(clk), .rst(rst), .start_cipher(start_cipher), .has_ad(has_ad), .has_pt(has_pt), \
    .ad_last(ad_last), .pt_last(pt_last), .key(key), .nonce(nonce), .data_in(data_in), \
    .data_bytes(data_bytes), .ciphertext_out(CT), .tag_out(TAG), .cipher_done(DN)

module ascon_equivalence_tb;

    localparam integer NC      = 5;                 // candidates c0..c4
    localparam integer NMUT    = `NMUT_VAL;         // optional self-test mutants
    localparam integer NT      = NC + NMUT;         // DUTs compared with the reference (index 0)
    localparam integer KAT_MAX = 1100;
    localparam integer RND_MAX = 8000;
    localparam integer STRIDE  = 32;                // words per vector (see py/ascon_vectors.py)

    // controller state encoding of the reference (rtl/ascon_fsm.sv); used for
    // coverage and for pacing the driver only - never for pass/fail.
    localparam [3:0] ST_IDLE = 4'd0, ST_INIT_LOAD = 4'd1, ST_INIT_WAIT = 4'd2,
                     ST_AD_LOAD = 4'd3, ST_AD_WAIT = 4'd4, ST_PT_LOAD = 4'd5,
                     ST_PT_WAIT = 4'd6, ST_FINAL_LOAD = 4'd7, ST_FINAL_WAIT = 4'd8,
                     ST_DONE = 4'd9;

    localparam integer P_INIT = 0, P_KAT = 1, P_RAND = 2, P_ABORT = 3,
                       P_CHAOS_A = 4, P_CHAOS_B = 5, P_CHAOS_C = 6, P_CHAOS_D = 7, P_CHAOS_E = 8;

    // ------------------------------------------------------------ clock / stimulus
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rst;
    reg         start_cipher, has_ad, has_pt, ad_last, pt_last;
    reg  [4:0]  data_bytes;
    reg  [127:0] key, nonce, data_in;

    // ------------------------------------------------------------ DUTs
    wire [127:0] o_ct  [0:NT];
    wire [127:0] o_tag [0:NT];
    wire         o_dn  [0:NT];
    wire [256:0] obs   [0:NT];

    ascon_core u_ref (`DUT_PORTS(o_ct[0], o_tag[0], o_dn[0]));   // index 0 : reference
    ascon_c0   u_c0  (`DUT_PORTS(o_ct[1], o_tag[1], o_dn[1]));
    ascon_c1   u_c1  (`DUT_PORTS(o_ct[2], o_tag[2], o_dn[2]));
    ascon_c2   u_c2  (`DUT_PORTS(o_ct[3], o_tag[3], o_dn[3]));
    ascon_c3   u_c3  (`DUT_PORTS(o_ct[4], o_tag[4], o_dn[4]));
    ascon_c4   u_c4  (`DUT_PORTS(o_ct[5], o_tag[5], o_dn[5]));
`ifdef MUTANTS
    ascon_m1   u_m1  (`DUT_PORTS(o_ct[6],  o_tag[6],  o_dn[6]));
    ascon_m2   u_m2  (`DUT_PORTS(o_ct[7],  o_tag[7],  o_dn[7]));
    ascon_m3   u_m3  (`DUT_PORTS(o_ct[8],  o_tag[8],  o_dn[8]));
    ascon_m4   u_m4  (`DUT_PORTS(o_ct[9],  o_tag[9],  o_dn[9]));
    ascon_m5   u_m5  (`DUT_PORTS(o_ct[10], o_tag[10], o_dn[10]));
`endif

    genvar gi;
    generate
        for (gi = 0; gi <= NT; gi = gi + 1) begin : g_obs
            assign obs[gi] = {o_dn[gi], o_tag[gi], o_ct[gi]};
        end
    endgenerate

    function string dut_name;
        input integer i;
        begin
            if (i == 0)       dut_name = "ref (ascon_core)";
            else if (i <= NC) dut_name = $sformatf("ascon_c%0d", i - 1);
            else              dut_name = $sformatf("mutant m%0d", i - NC);
        end
    endfunction

    function [8*9-1:0] phase_name;
        input integer p;
        begin
            case (p)
                P_INIT:    phase_name = "init     ";
                P_KAT:     phase_name = "KAT      ";
                P_RAND:    phase_name = "RAND     ";
                P_ABORT:   phase_name = "ABORT    ";
                P_CHAOS_A: phase_name = "CHAOS-A  ";
                P_CHAOS_B: phase_name = "CHAOS-B  ";
                P_CHAOS_C: phase_name = "CHAOS-C  ";
                P_CHAOS_D: phase_name = "CHAOS-D  ";
                P_CHAOS_E: phase_name = "CHAOS-E  ";
                default:   phase_name = "?        ";
            endcase
        end
    endfunction

    // ------------------------------------------------------------ vectors
    reg [127:0] kat_mem [0:KAT_MAX*STRIDE-1];
    reg [127:0] rnd_mem [0:RND_MAX*STRIDE-1];
    reg [127:0] cur     [0:STRIDE-1];
    integer     cur_ad_len, cur_pt_len, n_ad, n_pt;

    // ------------------------------------------------------------ bookkeeping
    integer phase;
    reg     cmp_en;
    integer n_cmp;
    integer mism       [0:NT];
    integer first_t    [0:NT];
    integer first_ph   [0:NT];
    reg [256:0] first_diff [0:NT];
    integer ci;

    integer exp_ops, exp_ct_bad, exp_tag_bad, timeouts, ops_aborted;
    integer first_bad_vec, first_bad_phase;

    // coverage of the reference, sampled every compared cycle
    integer cov_state   [0:15];
    integer cov_ptlast  [0:31];
    integer cov_adlast  [0:31];
    integer cov_done, cov_start_busy, cov_start_done, cov_rst_busy, cov_tag_chg, cov_ct_chg;
    reg [127:0] prev_tag, prev_ct;
    reg         prev_done;

    wire [3:0] r_state    = u_ref.controller.state;
    wire       r_start_ad = u_ref.controller.start_ad;
    wire       r_start_pt = u_ref.controller.start_pt;

    // ------------------------------------------------------------ the comparator
    always @(negedge clk) begin
        if (cmp_en) begin
            n_cmp = n_cmp + 1;
            for (ci = 1; ci <= NT; ci = ci + 1) begin
                if (obs[ci] !== obs[0]) begin
                    mism[ci] = mism[ci] + 1;
                    if (first_t[ci] < 0) begin
                        first_t[ci]    = $time;
                        first_ph[ci]   = phase;
                        first_diff[ci] = obs[ci] ^ obs[0];
                    end
                end
            end
            // coverage (reference only)
            cov_state[r_state] = cov_state[r_state] + 1;
            if (r_start_pt && pt_last) cov_ptlast[data_bytes] = cov_ptlast[data_bytes] + 1;
            if (r_start_ad && ad_last) cov_adlast[data_bytes] = cov_adlast[data_bytes] + 1;
            if (o_dn[0] === 1'b1 && prev_done !== 1'b1) cov_done = cov_done + 1;
            if (start_cipher && r_state != ST_IDLE && r_state != ST_DONE) cov_start_busy = cov_start_busy + 1;
            if (start_cipher && r_state == ST_DONE) cov_start_done = cov_start_done + 1;
            if (o_tag[0] !== prev_tag) cov_tag_chg = cov_tag_chg + 1;
            if (o_ct[0]  !== prev_ct)  cov_ct_chg  = cov_ct_chg + 1;
            prev_tag  = o_tag[0];
            prev_ct   = o_ct[0];
            prev_done = o_dn[0];
        end
    end

    // ------------------------------------------------------------ random numbers
    reg [63:0] rng_s;
    task rng_next;
        output [63:0] r;
        reg [63:0] x;
        begin                              // xorshift64*
            x = rng_s;
            x = x ^ (x >> 12);
            x = x ^ (x << 25);
            x = x ^ (x >> 27);
            rng_s = x;
            r = x * 64'h2545F4914F6CDD1D;
        end
    endtask

    // ------------------------------------------------------------ driver helpers
    reg [3:0]   s_st, s_ns;
    reg         s_start_ad, s_start_pt, s_done;
    reg [127:0] s_ct, s_tag;

    // sample the reference mid-cycle, then advance to 1 ns after the next rising edge
    task step;
        begin
            @(negedge clk);
            s_st       = u_ref.controller.state;
            s_ns       = u_ref.controller.next_state;
            s_start_ad = u_ref.controller.start_ad;
            s_start_pt = u_ref.controller.start_pt;
            s_done     = o_dn[0];
            s_ct       = o_ct[0];
            s_tag      = o_tag[0];
            @(posedge clk);
            #1;
        end
    endtask

    // inputs that are don't-care outside their absorb cycle
    task drive_garbage;
        reg [63:0] a, b, c;
        begin
            rng_next(a); rng_next(b); rng_next(c);
            data_in    = {a, b};
            data_bytes = c[4:0];
            ad_last    = c[8];
            pt_last    = c[9];
        end
    endtask

    task drive_ad_block;
        input integer b;
        reg [63:0] c;
        begin
            rng_next(c);
            data_in    = cur[3 + b];
            ad_last    = (b == n_ad - 1);
            data_bytes = (b == n_ad - 1) ? (cur_ad_len - 16 * (n_ad - 1)) : c[4:0];
            pt_last    = c[9];
        end
    endtask

    task drive_pt_block;
        input integer b;
        reg [63:0] c;
        begin
            rng_next(c);
            data_in    = cur[9 + b];
            pt_last    = (b == n_pt - 1);
            data_bytes = (b == n_pt - 1) ? (cur_pt_len - 16 * (n_pt - 1)) : c[4:0];
            ad_last    = c[8];
        end
    endtask

    task load_vec;
        input integer which;      // 0 = KAT memory, 1 = RAND memory
        input integer idx;
        integer w;
        begin
            for (w = 0; w < STRIDE; w = w + 1)
                cur[w] = (which == 0) ? kat_mem[idx * STRIDE + w] : rnd_mem[idx * STRIDE + w];
            cur_ad_len = cur[2][31:16];
            cur_pt_len = cur[2][15:0];
            n_ad = (cur_ad_len > 0) ? (cur_ad_len / 16 + 1) : 0;
            n_pt = cur_pt_len / 16 + 1;
        end
    endtask

    // wait until the reference is back in IDLE
    task settle;
        integer n;
        begin
            n = 0;
            step;
            while (s_st != ST_IDLE && n < 40) begin
                drive_garbage;
                step;
                n = n + 1;
            end
        end
    endtask

    reg op_complete;
    integer op_vec_id;

    // One AEAD operation for the vector in `cur`.
    //   hold     : cycles start_cipher is held high at the beginning (>= 1)
    //   busy_at  : cycle at which start_cipher is pulsed again while busy (0 = never)
    //   busy_len : length of that pulse
    //   abort_at : cycle at which an asynchronous reset is asserted (0 = never)
    //   rst_len  : length of that reset
    task run_op;
        input integer hold;
        input integer busy_at;
        input integer busy_len;
        input integer abort_at;
        input integer rst_len;
        integer cyc, ad_i, pt_i, ct_idx, k;
        reg ct_pend, finished;
        begin
            key  = cur[0];
            nonce = cur[1];
            has_ad = (n_ad > 0);
            has_pt = 1'b1;
            drive_garbage;
            start_cipher = 1'b1;                 // cycle 0
            op_complete = 1'b0;
            cyc = 0; ad_i = 0; pt_i = 0; ct_idx = 0; ct_pend = 1'b0; finished = 1'b0;
            step;                                // samples cycle 0, now in cycle 1
            while (!finished) begin
                cyc = cyc + 1;
                // ---- events of the cycle that just ended
                if (ct_pend) begin
                    if (s_ct !== cur[15 + ct_idx]) begin
                        exp_ct_bad = exp_ct_bad + 1;
                        if (first_bad_vec < 0) begin first_bad_vec = op_vec_id; first_bad_phase = phase; end
                    end
                    ct_pend = 1'b0;
                end
                if (s_start_ad) ad_i = ad_i + 1;
                if (s_start_pt) begin ct_idx = pt_i; pt_i = pt_i + 1; ct_pend = 1'b1; end
                if (s_done) begin
                    exp_ops = exp_ops + 1;
                    if (s_tag !== cur[21]) begin
                        exp_tag_bad = exp_tag_bad + 1;
                        if (first_bad_vec < 0) begin first_bad_vec = op_vec_id; first_bad_phase = phase; end
                    end
                    op_complete = 1'b1;
                    finished = 1'b1;
                    start_cipher = 1'b0;
                end else if (cyc > 3000) begin
                    timeouts = timeouts + 1;
                    finished = 1'b1;
                    start_cipher = 1'b0;
                end else if (abort_at > 0 && cyc == abort_at) begin
                    // ---- asynchronous reset in the middle of the operation
                    if (s_st != ST_IDLE) cov_rst_busy = cov_rst_busy + 1;
                    ops_aborted = ops_aborted + 1;
                    start_cipher = 1'b0;
                    rst = 1'b1;
                    for (k = 0; k < rst_len; k = k + 1) begin
                        drive_garbage;
                        step;
                    end
                    rst = 1'b0;
                    finished = 1'b1;
                end else begin
                    // ---- inputs for cycle `cyc`
                    if (s_ns == ST_AD_LOAD)      drive_ad_block(ad_i);
                    else if (s_ns == ST_PT_LOAD) drive_pt_block(pt_i);
                    else                         drive_garbage;
                    if (cyc < hold)                                              start_cipher = 1'b1;
                    else if (busy_at > 0 && cyc >= busy_at && cyc < busy_at + busy_len) start_cipher = 1'b1;
                    else                                                         start_cipher = 1'b0;
                    step;
                end
            end
        end
    endtask

    // ------------------------------------------------------------ chaos
    task chaos;
        input integer ncyc;
        input integer p_flag;     // /65536 per cycle: one flag changes
        input integer p_data;     // /65536 per cycle: data_in / data_bytes change
        input integer p_key;      // /65536 per cycle: key and nonce change
        input integer p_start;    // /65536 : start probability (or drop probability if sticky)
        input integer p_rst;      // /65536 per cycle: asynchronous reset starts
        input integer sticky;     // 1 = start_cipher is held high, dropping with p_start
        integer n, rcnt;
        reg [63:0] r1, r2, r3, r4, r5, r6, r7;
        begin
            rcnt = 0;
            rst = 1'b0;
            for (n = 0; n < ncyc; n = n + 1) begin
                rng_next(r1); rng_next(r2); rng_next(r3); rng_next(r4); rng_next(r5);
                if (r1[15:0] < p_flag) begin
                    case (r1[17:16])
                        2'd0: has_ad  = r1[18];
                        2'd1: has_pt  = (r1[20:19] != 2'b00);
                        2'd2: ad_last = r1[21];
                        2'd3: pt_last = r1[22];
                    endcase
                end
                if (r2[15:0] < p_data) begin
                    data_in    = {r3, r4};
                    data_bytes = r2[20:16];
                end else if (r2[31:21] < 11'd40) begin
                    data_bytes = r2[36:32];
                end
                if (r5[15:0] < p_key) begin
                    rng_next(r6); rng_next(r7); key   = {r6, r7};
                    rng_next(r6); rng_next(r7); nonce = {r6, r7};
                end
                if (sticky) start_cipher = (r5[47:32] >= p_start);
                else        start_cipher = (r5[47:32] <  p_start);
                if (rst) begin
                    if (rcnt <= 1) begin rst = 1'b0; rcnt = 0; end
                    else rcnt = rcnt - 1;
                end else if (r5[63:48] < p_rst) begin
                    rst  = 1'b1;
                    rcnt = 1 + r4[1:0];
                    if (u_ref.controller.state != ST_IDLE) cov_rst_busy = cov_rst_busy + 1;
                end
                @(posedge clk);
                #1;
            end
            rst = 1'b0;
            start_cipher = 1'b0;
        end
    endtask

    // ------------------------------------------------------------ main
    integer dummy, v, k, i, s, b;
    integer n_kat, n_rnd, chaos_x, seed_arg, abort_vec, abort_max;
    reg [63:0] rr1, rr2, rr3;
    reg all_ok, cov_ok;
    integer mut_detected;
    string kat_file, rnd_file;

    task ph;
        input integer p;
        begin
            phase = p;
            $display("[%0t ns] phase %0s  (compared cycles so far: %0d)", $time, phase_name(p), n_cmp);
        end
    endtask

    initial begin
        kat_file = "vectors/kat.mem";
        rnd_file = "vectors/rand.mem";
        n_kat = 1089; n_rnd = 3130; chaos_x = 4; seed_arg = 0;
        dummy = $value$plusargs("KAT=%s", kat_file);
        dummy = $value$plusargs("RND=%s", rnd_file);
        dummy = $value$plusargs("N_KAT=%d", n_kat);
        dummy = $value$plusargs("N_RND=%d", n_rnd);
        dummy = $value$plusargs("CHAOS_X=%d", chaos_x);
        dummy = $value$plusargs("SEED=%d", seed_arg);
        if (n_kat > KAT_MAX || n_rnd > RND_MAX) begin
            $display("ERROR: vector count exceeds the testbench memory size");
            $finish;
        end
        $readmemh(kat_file, kat_mem);
        $readmemh(rnd_file, rnd_mem);
        rng_s = 64'hD1B54A32D192ED03 ^ {32'd0, seed_arg[31:0]};

        for (i = 0; i <= NT; i = i + 1) begin mism[i] = 0; first_t[i] = -1; first_ph[i] = 0; first_diff[i] = 0; end
        for (i = 0; i < 16; i = i + 1) cov_state[i] = 0;
        for (i = 0; i < 32; i = i + 1) begin cov_ptlast[i] = 0; cov_adlast[i] = 0; end
        cov_done = 0; cov_start_busy = 0; cov_start_done = 0; cov_rst_busy = 0; cov_tag_chg = 0; cov_ct_chg = 0;
        prev_tag = 0; prev_ct = 0; prev_done = 1'b0;
        n_cmp = 0; cmp_en = 1'b0; phase = P_INIT;
        exp_ops = 0; exp_ct_bad = 0; exp_tag_bad = 0; timeouts = 0; ops_aborted = 0;
        first_bad_vec = -1; first_bad_phase = 0; op_vec_id = 0; op_complete = 1'b0;

        // ---- power-up reset
        rst = 1'b1; start_cipher = 1'b0; has_ad = 1'b0; has_pt = 1'b1;
        key = 128'd0; nonce = 128'd0;
        drive_garbage;
        @(posedge clk); #1;
        @(posedge clk); #1;
        cmp_en = 1'b1;
        @(posedge clk); #1;
        rst = 1'b0;
        step; step; step;

        // ---- phase 1: official KAT vectors
        ph(P_KAT);
        for (v = 0; v < n_kat; v = v + 1) begin
            load_vec(0, v);
            op_vec_id = v;
            run_op(1, 0, 0, 0, 0);
            settle;
        end

        // ---- phase 2: directed + seeded random vectors, random pacing / abuse
        ph(P_RAND);
        for (v = 0; v < n_rnd; v = v + 1) begin
            load_vec(1, v);
            op_vec_id = 100000 + v;
            rng_next(rr1); rng_next(rr2); rng_next(rr3);
            run_op( (rr1[2:0] == 3'd0) ? (2 + rr1[6:4]) : 1,                                  // hold start 1..9 cycles
                    (rr2[1:0] == 2'd0) ? (1 + rr2[9:4]) : 0,                                  // start pulse while busy
                    1 + rr2[12:11],
                    0, 0);
            settle;
            for (k = 0; k < rr3[1:0]; k = k + 1) begin drive_garbage; step; end              // idle gap 0..3
        end

        // ---- phase 3: asynchronous reset at every cycle of an operation
        ph(P_ABORT);
        abort_vec = 0;
        for (v = n_rnd - 1; v >= 0; v = v - 1) begin
            load_vec(1, v);
            if (cur_ad_len >= 17 && cur_pt_len >= 17 && cur_ad_len < 40 && cur_pt_len < 40) abort_vec = v;
        end
        abort_max = 150;
        for (k = 1; k <= abort_max; k = k + 1) begin
            load_vec(1, abort_vec);
            op_vec_id = 200000 + k;
            run_op(1, 0, 0, k, 1 + (k % 3));            // cut at cycle k
            settle;
            run_op(1, 0, 0, 0, 0);                      // must now complete correctly
            settle;
        end

        // ---- phase 4: chaos
        // knob sets:        cycles       flag   data   key   start  rst   sticky
        ph(P_CHAOS_A); chaos(chaos_x * 150000, 32768, 32768, 2048, 10000,   22, 0);
        ph(P_CHAOS_B); chaos(chaos_x * 200000,  1365, 16384,  256,  2730,   16, 0);
        ph(P_CHAOS_C); chaos(chaos_x *  75000,  8192, 16384, 2048,  8192,  819, 0);
        ph(P_CHAOS_D); chaos(chaos_x *  75000,  2048,  8192,  512,   330,   13, 1);
        ph(P_CHAOS_E); chaos(chaos_x * 150000,   110, 32768,  128,  4096,    5, 0);
        step; step; step;

        // ---- verdict
        cov_ok = 1'b1;
        for (s = 0; s <= 9; s = s + 1) if (cov_state[s] == 0) cov_ok = 1'b0;
        for (b = 0; b < 16; b = b + 1) if (cov_ptlast[b] == 0 || cov_adlast[b] == 0) cov_ok = 1'b0;
        if (cov_done < 1000 || cov_start_busy < 100 || cov_start_done < 10 || cov_rst_busy < 50) cov_ok = 1'b0;

        all_ok = 1'b1;
        for (i = 1; i <= NC; i = i + 1) if (mism[i] != 0) all_ok = 1'b0;
        if (exp_ct_bad != 0 || exp_tag_bad != 0 || timeouts != 0) all_ok = 1'b0;
        if (!cov_ok) all_ok = 1'b0;

        $display("");
        $display("=====================================================================");
        $display(" ASCON EQUIVALENCE REGRESSION  -  %0d cycles compared on every DUT", n_cmp);
        $display("=====================================================================");
        $display(" %-18s  mismatching cycles   first mismatch", "DUT");
        for (i = 1; i <= NT; i = i + 1) begin
            if (mism[i] == 0) $display(" %-18s %10d   -", dut_name(i), mism[i]);
            else $display(" %-18s %10d   t=%0d ns, phase %0s, diff=%h", dut_name(i), mism[i],
                          first_t[i], phase_name(first_ph[i]), first_diff[i]);
        end
        $display("---------------------------------------------------------------------");
        $display(" reference vs expected values : %0d operations completed, %0d ciphertext errors, %0d tag errors",
                 exp_ops, exp_ct_bad, exp_tag_bad);
        if (first_bad_vec >= 0) $display("   first bad vector id %0d in phase %0s", first_bad_vec, phase_name(first_bad_phase));
        $display(" operations cut by reset       : %0d   driver timeouts: %0d", ops_aborted, timeouts);
        $display("---------------------------------------------------------------------");
        $write(" coverage, cycles per controller state:");
        for (s = 0; s <= 9; s = s + 1) $write(" %0d", cov_state[s]);
        $write("\n");
        $write(" coverage, final PT blocks by data_bytes 0..15:");
        for (b = 0; b < 16; b = b + 1) $write(" %0d", cov_ptlast[b]);
        $write("\n");
        $write(" coverage, final AD blocks by data_bytes 0..15:");
        for (b = 0; b < 16; b = b + 1) $write(" %0d", cov_adlast[b]);
        $write("\n");
        $display(" coverage, done pulses %0d | start while busy %0d cycles | start while done %0d cycles | reset while busy %0d",
                 cov_done, cov_start_busy, cov_start_done, cov_rst_busy);
        $display(" activity, tag_out changed %0d times, ciphertext_out changed %0d times", cov_tag_chg, cov_ct_chg);
        $display(" coverage gate: %0s", cov_ok ? "OK" : "LOW");
        if (NMUT > 0) begin
            mut_detected = 0;
            for (i = NC + 1; i <= NT; i = i + 1) if (mism[i] != 0) mut_detected = mut_detected + 1;
            $display("=====================================================================");
            $display("MUTANT_RESULT: %0d of %0d deliberately broken cores detected", mut_detected, NMUT);
        end
        $display("=====================================================================");
        if (all_ok)
            $display("EQUIV_RESULT: PASS  (c0..c4 identical to ascon_core on %0d cycles; KAT + random + reset sweep + chaos)", n_cmp);
        else
            $display("EQUIV_RESULT: FAIL");
        $finish;
    end

    // safety net
    initial begin
        #1500000000;
        $display("EQUIV_RESULT: FAIL  (global timeout)");
        $finish;
    end

endmodule
