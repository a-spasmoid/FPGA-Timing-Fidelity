# FPGA Timing Fidelity

Experimental study of how faithfully post-route static timing rankings between
functionally and cycle-equivalent RTL implementations carry over to empirical
timing margins on physical FPGA hardware.

## Research question

> When functionally and cycle-equivalent RTL implementations are ranked using
> post-route timing, how faithfully does that ranking carry over to their
> empirical timing margins on the same physical FPGA under defined workloads?

The study separates two related questions:

1. **Ranking fidelity** — if post-route STA ranks implementation A ahead of B,
   does physical hardware preserve that ordering?
2. **Gain fidelity** — does the magnitude of the STA timing advantage transfer
   proportionally to the measured hardware timing advantage?

The goal is not to show that STA is "wrong". Post-route STA and deliberate
operation near or beyond the nominal timing boundary answer different
engineering questions. The experiment instead evaluates how informative the
STA result is as a comparative signal when selecting between equivalent RTL
implementations.

---

## Platform

- FPGA: Xilinx Zynq-7020, PYNQ-Z2
- Device: `xc7z020clg400-1`
- Tool: Vivado 2026.1
- Primary workload family: sequential 3x3 convolution
- Optional secondary design family: Ascon-AEAD128
- Nominal implementation target: 7.000 ns

---

## Current status

The convolution candidate set and final post-route characterization are
complete.

All seven RTL candidates have passed a common functional and cycle-equivalence
regression. The final routed implementations have also been generated and
archived locally with matching reports and bitstreams.

The hardware measurement apparatus has been validated on the PYNQ-Z2. Final
A0-A6 board sweeps are the next experimental stage.

---

## RTL candidate set

All convolution candidates preserve:

- the same 3x3 convolution function
- the same input and output precision
- the same signed interpretation
- 9 computation cycles
- initiation interval `II = 10`
- the same externally visible cycle-level behavior

Resource usage is allowed to differ.

| Candidate | Structural variation |
|---|---|
| **A0** | Baseline: stationary packed registers with counter-indexed variable part-selects |
| **A1** | Shift-based data movement with fixed low-byte taps |
| **A2** | Stationary registers with explicit 9-way combinational byte selection |
| **A3** | Operands extended before storage, using 81-bit internal packed registers |
| **A4** | One-hot moving selector with stationary operand storage |
| **A5** | Registered product / split multiply-accumulate datapath |
| **A6** | Carry-save accumulation with final carry-propagate addition |

A1 provides a deliberately large timing separation from the baseline, while
A0, A2, A4 and A6 form a close-gap cluster useful for stressing ranking
fidelity.

---

## Functional equivalence

The canonical regression is:

```text
convolution/tb/conv_equivalence_tb.v
