# FPGA Timing Fidelity

Experimental study of how faithfully post-route static timing rankings
between functionally and cycle-equivalent RTL implementations carry over
to empirical timing margins on physical FPGA hardware.

## Platform

- FPGA: Xilinx Zynq-7020 (PYNQ-Z2)
- Tool: Vivado 2026.1
- Primary workload: sequential 3x3 convolution
- Secondary/optional workload family: Ascon-AEAD128

## Research question

When functionally and cycle-equivalent RTL implementations are ranked using
post-route timing, how faithfully does that ranking carry over to their
empirical timing margins on the same physical FPGA under defined workloads?

## Repository structure

- `convolution/rtl/` — equivalent convolution RTL candidates
- `convolution/tb/` — functional and cycle-equivalence regression
- `convolution/harness/` — PYNQ hardware measurement apparatus
- `convolution/constraints/` — timing and CDC constraints
- `convolution/scripts/` — Vivado and Python experiment automation
- `convolution/results/` — compact archived experiment summaries
- `ascon_aead/` — Ascon implementation used for possible extension
- `docs/` — methodology and measurement protocol

Large generated Vivado artifacts and bitstreams are intentionally not stored
in normal Git history.
