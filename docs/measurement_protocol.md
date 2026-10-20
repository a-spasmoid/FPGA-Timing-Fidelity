# FYP Board Measurement Protocol — Frozen 2026-10-20

## 1. Core empirical question
Measure, for each exact routed candidate bitstream, the workload-conditioned empirical timing margin and compare the hardware ranking with post-route STA ranking.

Primary reported hardware quantity per workload:
- `f_NE`: highest tested frequency with zero observed errors at the stated budget.
- `f_FE`: lowest tested frequency with at least one observed wrong result or a valid candidate timeout.
- Report the bracket; do not call it a universal Fmax.

If PASS appears above FAIL, flag the transition as non-monotonic and expand/repeat locally instead of forcing a conventional bracket.

## 2. Workloads

### Primary workload — deterministic pseudo-random
- Runner mode: `random`.
- Same fixed seed for every candidate and every frequency: `0xF6C71699`.
- Five xorshift32 streams generate the same deterministic input population for every candidate.
- The measurement logic is reset at each frequency so the sequence restarts from the same seed.
- Across software chunks at one frequency, the PRNG stream continues rather than restarting.
- Batch size: 50,000.

This workload defines the primary ranking-fidelity result.

### Secondary workload — six-vector directed cycle
- Runner mode: `directed`.
- Existing frozen six-vector set only; do not add new RTL workload modes before primary measurement.
- Includes selector-position checks, mixed-sign arithmetic, positive/negative extremes, and a mixed-extreme vector.
- Batch size: 60,000 so each full software batch contains an integer number of six-vector cycles.
- Seed field remains `0xF6C71699` for metadata consistency but does not define the directed vectors.

This workload is a workload/path-sensitization check. Repeating the six-vector cycle is deterministic, so random-trial confidence bounds such as `3/N` are not applied to it.

## 3. Frequency search and budgets

### Random primary
1. Coarse sweep: 1,000,000 transactions/frequency; approximately 0.100 ns target-period spacing; ascending frequency.
2. Fine sweep: 10,000,000 transactions/frequency; approximately 0.010 ns target-period spacing; ascending frequency.
3. Reverse-order control: rerun the three boundary points at 10,000,000 transactions/frequency in descending frequency order.
4. Budget sensitivity: rerun the same three boundary points at 100,000,000 transactions/frequency in the same descending order.

The reverse-order 10M pass isolates sweep-order/thermal-hysteresis effects at the same observation budget. Comparing reverse-order 10M with reverse-order 100M isolates observation-budget sensitivity more cleanly.

### Directed secondary
1. Coarse sweep: 1,000,000 transactions/frequency; approximately 0.100 ns target-period spacing; ascending frequency.
2. Fine sweep: 10,000,000 transactions/frequency; approximately 0.010 ns target-period spacing; ascending frequency.
3. Reverse-order boundary control: three boundary points at 10,000,000 transactions/frequency in descending order.
4. No routine 100M directed sweep. Any additional directed follow-up caused by an anomaly is labeled exploratory.

All results use the actual legal MMCM frequency (`M/D/O`) as the measurement coordinate. The nominal period grid is only the target-selection rule.

## 4. Environmental / thermal controls
- Use the same PYNQ-Z2, power source, cables, board orientation and airflow for the complete final campaign.
- Do not add/remove a fan or change cooling during the campaign.
- After board power-up and apparatus validation, warm the board for about 5 minutes at 100 MHz while running random traffic.
- After loading each candidate bitstream, set DUT to 100 MHz, run 1,000,000 random warm-up transactions, discard those results, then wait about 5 seconds before the first measured point.
- Keep point-to-point idle time minimal and consistent.
- Record wall-clock timestamps for every point (already logged).
- If Zynq XADC die temperature is readily accessible on the board image, log it at candidate start/end and around boundary checks. Temperature logging is desirable but inability to expose it must not block the campaign.
- Do not claim voltage droop, crosstalk, or temperature as a causal explanation without instrumentation supporting that claim.

## 5. Candidate order and drift sentinel
Use a fixed candidate order chosen before final hardware results, not an order based on observed margins:

`A2 -> A0 -> A1 -> A4 -> A5 -> A6 -> A3`

The order is a deterministic shuffled order, not STA rank order.

After the first complete A0 random fine sweep establishes its final boundary, save its three boundary clock points as a session sentinel. At the end of the full random campaign, rerun those three A0 points at 10M in descending frequency order.

If the end-of-session A0 classification differs from its earlier reverse-order 10M check by more than one fine step or changes PASS/FAIL at a boundary point, mark session drift and repeat the affected close-ranking candidates after environmental stabilization.

## 6. Board-session gate sequence
Before collecting final results:
1. Known candidate at a safe 100 MHz: short directed + random smoke.
2. Verify PRNG reproducibility and chunk continuity.
3. Verify fractional-MMCM reconfiguration/LOCKED workflow using the final script.
4. Tiny-budget automated sweep; inspect CSV fields and validity classification.
5. Warm-up sequence.
6. Start final candidate campaign.

Discard any point with infrastructure evidence such as `clock_fault_seen`, host timeout, or other invalid-run classification. Candidate timeout without infrastructure fault remains valid candidate failure evidence, though the requested budget is censored.

## 7. Core-vs-exploratory distinction
Core results:
- all seven candidates under random workload;
- all seven candidates under the frozen directed workload;
- random 10M reverse-order check and 100M boundary sensitivity;
- directed 10M reverse-order check.

Anything added after seeing an anomalous result is retained and reported, but explicitly labeled follow-up/exploratory rather than silently folded into the frozen primary protocol.
