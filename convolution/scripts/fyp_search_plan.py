#!/usr/bin/env python3
"""
Generate staged clock-sweep configs for the FYP timing-fidelity experiment.

Stages
------
coarse:
    Generate a 1M-transaction coarse period sweep from candidate + T_EDA.
fine:
    Read a completed coarse frequencies.csv and generate a 10M local sweep
    at ~10 ps target-period spacing.
reversecheck:
    Read a completed fine frequencies.csv and generate a 10M reverse-order
    boundary check at:
      (1) f_FE,
      (2) f_NE,
      (3) one tested point slower than f_NE.
    This is the same-budget sweep-order / thermal-drift control.
sensitivity:
    Read a completed fine frequencies.csv and generate 100M checks at the
    same three boundary points, also in descending frequency order.
summary:
    Summarize any frequencies.csv using the experiment's pass/fail rules.

This script does not touch hardware. It only writes measurement JSON configs.
It expects mmcm_grid.py to be in the same directory (or importable via PYTHONPATH).
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

from mmcm_grid import ClockPoint, enumerate_points, nearest_point

# Frozen protocol defaults.
F_MIN_MHZ = 100.0
F_MAX_MHZ = 250.0
VCO_MIN_MHZ = 900.0
VCO_MAX_MHZ = 1100.0
MMCM_D = 1

COARSE_BUDGET = 1_000_000
FINE_BUDGET = 10_000_000
REVERSE_CHECK_BUDGET = 10_000_000
SENSITIVITY_BUDGET = 100_000_000

COARSE_PERIOD_STEP_NS = 0.100
FINE_PERIOD_STEP_NS = 0.010
FINE_MARGIN_NS = 0.050

# Use T_EDA only to choose a broad coarse search band, never as a result.
COARSE_START_FACTOR = 1.10   # slower/larger period side
COARSE_STOP_FACTOR = 0.60    # faster/smaller period side
PERIOD_MIN_NS = 1000.0 / F_MAX_MHZ  # 4 ns
PERIOD_MAX_NS = 1000.0 / F_MIN_MHZ  # 10 ns

DEFAULT_SEED = "0xF6C71699"
DEFAULT_BATCH = 50_000


@dataclass(frozen=True)
class ResultRow:
    actual_mhz: float
    period_ns: float
    total_wrong: int
    measurement_valid: bool
    budget_complete: bool
    run_status: str
    clock_fault_seen: bool
    timeout_seen: bool
    raw: Dict[str, str]

    @property
    def outcome(self) -> str:
        """Return PASS, FAIL, or INVALID under the frozen protocol."""
        if not self.measurement_valid or self.clock_fault_seen:
            return "INVALID"

        # Candidate timeout is scientifically usable failure evidence even
        # though the requested transaction budget is censored/incomplete.
        if self.run_status == "candidate_timeout":
            return "FAIL"

        # Wrong arithmetic/computation result is failure evidence.
        if self.total_wrong > 0:
            return "FAIL"

        # A no-error point is a PASS only if the full requested budget ran.
        if (
            self.run_status == "complete"
            and self.budget_complete
            and self.total_wrong == 0
            and not self.timeout_seen
        ):
            return "PASS"

        return "INVALID"


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def as_bool(v: object) -> bool:
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    return s in {"1", "true", "yes", "y"}


def legal_grid() -> List[ClockPoint]:
    return enumerate_points(
        F_MIN_MHZ,
        F_MAX_MHZ,
        VCO_MIN_MHZ,
        VCO_MAX_MHZ,
        d=MMCM_D,
    )


def descending_period_targets(start_ns: float, stop_ns: float, step_ns: float) -> List[float]:
    """Generate start, start-step, ... >= stop with stable decimal behavior."""
    if step_ns <= 0:
        raise ValueError("period step must be positive")
    if start_ns < stop_ns:
        raise ValueError("start period must be >= stop period")

    nmax = int(math.floor((start_ns - stop_ns) / step_ns + 1e-9))
    vals = [start_ns - i * step_ns for i in range(nmax + 1)]
    if vals[-1] > stop_ns + 1e-9:
        vals.append(stop_ns)
    return vals


def map_period_targets(periods_ns: Sequence[float]) -> List[dict]:
    """Map target periods to nearest preferred-VCO legal MMCM points and dedupe."""
    grid = legal_grid()
    chosen: List[dict] = []
    seen = set()

    for target_period in periods_ns:
        target_mhz = 1000.0 / target_period
        cp = nearest_point(grid, target_mhz)
        # Exact MMCM identity for our purpose.
        key = (round(cp.m * 8), cp.d, round(cp.o * 8))
        if key in seen:
            continue
        seen.add(key)
        chosen.append({
            "requested_mhz": target_mhz,
            "m": cp.m,
            "d": cp.d,
            "o": cp.o,
        })

    # Safety: measurement order must be ascending frequency / descending period.
    chosen.sort(key=lambda x: 100.0 * float(x["m"]) / (int(x["d"]) * float(x["o"])))
    return chosen


def point_actual_mhz(p: dict) -> float:
    return 100.0 * float(p["m"]) / (int(p["d"]) * float(p["o"]))


def point_period_ns(p: dict) -> float:
    return 1000.0 / point_actual_mhz(p)


def read_results(path: Path) -> List[ResultRow]:
    rows: List[ResultRow] = []
    with path.open(newline="") as f:
        for r in csv.DictReader(f):
            rows.append(ResultRow(
                actual_mhz=float(r["frequency_actual_mhz"]),
                period_ns=float(r["period_ns"]),
                total_wrong=int(r["total_wrong"] or 0),
                measurement_valid=as_bool(r["measurement_valid"]),
                budget_complete=as_bool(r["budget_complete"]),
                run_status=(r["run_status"] or "").strip(),
                clock_fault_seen=as_bool(r["clock_fault_seen"]),
                timeout_seen=as_bool(r["timeout_seen"]),
                raw=r,
            ))
    if not rows:
        raise ValueError(f"no rows in {path}")
    return rows


def analyze(rows: Sequence[ResultRow]) -> dict:
    classified = [(r, r.outcome) for r in rows]
    valid = [(r, o) for r, o in classified if o != "INVALID"]
    passes = [r for r, o in valid if o == "PASS"]
    fails = [r for r, o in valid if o == "FAIL"]
    invalid = [r for r, o in classified if o == "INVALID"]

    sorted_valid = sorted(valid, key=lambda ro: ro[0].actual_mhz)
    fail_seen = False
    nonmonotonic = False
    for _, outcome in sorted_valid:
        if outcome == "FAIL":
            fail_seen = True
        elif outcome == "PASS" and fail_seen:
            nonmonotonic = True

    f_ne = max((r.actual_mhz for r in passes), default=None)
    f_fe = min((r.actual_mhz for r in fails), default=None)
    p_ne = min((r.period_ns for r in passes), default=None)  # fastest PASS
    p_fe = max((r.period_ns for r in fails), default=None)   # slowest FAIL

    bracket_ordered = (
        f_ne is not None
        and f_fe is not None
        and f_ne < f_fe
        and not nonmonotonic
    )

    return {
        "n_rows": len(rows),
        "n_pass": len(passes),
        "n_fail": len(fails),
        "n_invalid": len(invalid),
        "nonmonotonic": nonmonotonic,
        "f_NE_mhz": f_ne,
        "f_FE_mhz": f_fe,
        "T_NE_ns": p_ne,
        "T_FE_ns": p_fe,
        "ordered_transition": bracket_ordered,
    }


def print_analysis(a: dict) -> None:
    print(f"rows={a['n_rows']} pass={a['n_pass']} fail={a['n_fail']} invalid={a['n_invalid']}")
    print(f"nonmonotonic={a['nonmonotonic']}")
    if a["f_NE_mhz"] is not None:
        print(f"f_NE={a['f_NE_mhz']:.9f} MHz  T_NE={a['T_NE_ns']:.9f} ns")
    else:
        print("f_NE=NONE")
    if a["f_FE_mhz"] is not None:
        print(f"f_FE={a['f_FE_mhz']:.9f} MHz  T_FE={a['T_FE_ns']:.9f} ns")
    else:
        print("f_FE=NONE")
    print(f"ordered_transition={a['ordered_transition']}")


def inherited_config_from_csv(freq_csv: Path) -> dict:
    cfg_path = freq_csv.parent / "config_used.json"
    if not cfg_path.is_file():
        raise FileNotFoundError(f"expected {cfg_path} next to frequencies.csv")
    return json.loads(cfg_path.read_text())


def base_config_from_args(args, stage: str, budget: int, clock_points: Sequence[dict]) -> dict:
    candidate = args.candidate
    route_id = args.route_id
    workload = args.workload
    artifact_dir = Path(args.artifact_dir)

    experiment_id = args.experiment_id or f"{candidate}_{route_id}_{workload}_{stage}_{utc_stamp()}"

    return {
        "experiment_id": experiment_id,
        "candidate": candidate,
        "route_id": route_id,
        "board": "PYNQ-Z2",
        "device": "xc7z020clg400-1",
        "vivado_version": "2026.1",
        "rtl_git_commit": args.rtl_git_commit,
        "bitstream": str(artifact_dir / f"{candidate}.bit"),
        "timing_report": str(artifact_dir / f"{candidate}_timing_summary.rpt"),
        "utilization_report": str(artifact_dir / f"{candidate}_utilization.rpt"),
        "routed_dcp": str(artifact_dir / f"{candidate}_routed.dcp"),
        "T_EDA_ns": args.t_eda,
        "program_bitstream": not args.no_program,
        "workload": workload,
        "prng": "5x xorshift32 continuous across batches",
        "seed": args.seed,
        "batch_size": args.batch_size,
        "test_budget": budget,
        "host_timeout_s": args.host_timeout_s,
        "clock_points": list(clock_points),
        "output_root": args.output_root,
        "notes": args.notes or (
            f"Frozen staged timing-search protocol; stage={stage}; "
            f"coarse={COARSE_BUDGET}, fine={FINE_BUDGET}, reversecheck={REVERSE_CHECK_BUDGET}, sensitivity={SENSITIVITY_BUDGET}."
        ),
    }


def inherited_stage_config(parent: dict, stage: str, budget: int, clock_points: Sequence[dict], experiment_id: Optional[str]) -> dict:
    cfg = dict(parent)
    candidate = cfg["candidate"]
    route_id = cfg.get("route_id", "R00")
    workload = cfg.get("workload", "random")
    cfg["experiment_id"] = experiment_id or f"{candidate}_{route_id}_{workload}_{stage}_{utc_stamp()}"
    cfg["test_budget"] = budget
    cfg["clock_points"] = list(clock_points)
    cfg["program_bitstream"] = True
    cfg["notes"] = (
        f"Inherited from {parent.get('experiment_id', 'prior stage')}; "
        f"frozen staged timing-search protocol; stage={stage}."
    )
    return cfg


def write_config(cfg: dict, out: Path) -> None:
    out.write_text(json.dumps(cfg, indent=2, sort_keys=True) + "\n")
    print(f"Wrote {out}")
    print(f"experiment_id={cfg['experiment_id']}")
    print(f"budget={cfg['test_budget']:,} transactions/frequency")
    print(f"points={len(cfg['clock_points'])}")
    if cfg["clock_points"]:
        ps = [point_period_ns(p) for p in cfg["clock_points"]]
        fs = [point_actual_mhz(p) for p in cfg["clock_points"]]
        print(
            f"actual range: {min(fs):.6f}..{max(fs):.6f} MHz "
            f"({max(ps):.6f}..{min(ps):.6f} ns)"
        )


def cmd_coarse(args) -> None:
    t = float(args.t_eda)
    start_ns = min(PERIOD_MAX_NS, COARSE_START_FACTOR * t)
    stop_ns = max(PERIOD_MIN_NS, COARSE_STOP_FACTOR * t)
    if start_ns <= stop_ns:
        raise ValueError(f"invalid coarse range {start_ns}..{stop_ns} ns")

    targets = descending_period_targets(start_ns, stop_ns, COARSE_PERIOD_STEP_NS)
    points = map_period_targets(targets)
    cfg = base_config_from_args(args, "coarse", COARSE_BUDGET, points)
    write_config(cfg, Path(args.out))
    print(
        f"coarse target-period rule: {start_ns:.3f} -> {stop_ns:.3f} ns "
        f"in {COARSE_PERIOD_STEP_NS:.3f} ns steps"
    )


def cmd_fine(args) -> None:
    csv_path = Path(args.from_csv)
    rows = read_results(csv_path)
    a = analyze(rows)
    print("Coarse analysis:")
    print_analysis(a)

    passes = [r for r in rows if r.outcome == "PASS"]
    fails = [r for r in rows if r.outcome == "FAIL"]
    if not passes:
        raise RuntimeError("coarse sweep has no valid full-budget PASS; extend to slower/larger periods")
    if not fails:
        raise RuntimeError("coarse sweep has no valid FAIL; extend to faster/smaller periods")

    # This formulation also expands sensibly if the coarse result is non-monotonic:
    # span the fastest PASS through the slowest FAIL, then add margin both sides.
    p_fastest_pass = min(r.period_ns for r in passes)
    p_slowest_fail = max(r.period_ns for r in fails)
    upper_ns = min(PERIOD_MAX_NS, max(p_fastest_pass, p_slowest_fail) + FINE_MARGIN_NS)
    lower_ns = max(PERIOD_MIN_NS, min(p_fastest_pass, p_slowest_fail) - FINE_MARGIN_NS)

    targets = descending_period_targets(upper_ns, lower_ns, FINE_PERIOD_STEP_NS)
    points = map_period_targets(targets)

    parent = inherited_config_from_csv(csv_path)
    cfg = inherited_stage_config(parent, "fine", FINE_BUDGET, points, args.experiment_id)
    write_config(cfg, Path(args.out))
    print(
        f"fine target-period rule: {upper_ns:.3f} -> {lower_ns:.3f} ns "
        f"in {FINE_PERIOD_STEP_NS:.3f} ns steps"
    )
    if a["nonmonotonic"]:
        print("WARNING: coarse outcomes were non-monotonic; fine sweep spans the full mixed region.")


def row_to_clock_point(r: ResultRow) -> dict:
    return {
        "requested_mhz": float(r.raw.get("frequency_requested_mhz") or r.actual_mhz),
        "m": float(r.raw["clock_m"]),
        "d": int(float(r.raw["clock_d"])),
        "o": float(r.raw["clock_o"]),
    }


def select_boundary_rows(rows: Sequence[ResultRow]) -> Tuple[ResultRow, ResultRow, ResultRow]:
    passes = sorted((r for r in rows if r.outcome == "PASS"), key=lambda r: r.actual_mhz)
    fails = sorted((r for r in rows if r.outcome == "FAIL"), key=lambda r: r.actual_mhz)
    if not passes or not fails:
        raise RuntimeError("fine sweep must contain at least one PASS and one FAIL")

    ne = max(passes, key=lambda r: r.actual_mhz)
    fe = min(fails, key=lambda r: r.actual_mhz)

    slower_passes = [r for r in passes if r.actual_mhz < ne.actual_mhz - 1e-12]
    if slower_passes:
        below_ne = max(slower_passes, key=lambda r: r.actual_mhz)
    else:
        slower_rows = [r for r in rows if r.actual_mhz < ne.actual_mhz - 1e-12]
        if not slower_rows:
            raise RuntimeError("no tested point exists below f_NE for the boundary check")
        below_ne = max(slower_rows, key=lambda r: r.actual_mhz)

    return below_ne, ne, fe


def unique_rows(rows: Sequence[ResultRow]) -> List[ResultRow]:
    uniq: List[ResultRow] = []
    seen = set()
    for r in rows:
        key = round(r.actual_mhz, 9)
        if key not in seen:
            seen.add(key)
            uniq.append(r)
    return uniq


def print_boundary_rows(rows: Sequence[ResultRow], below_ne: ResultRow, ne: ResultRow, fe: ResultRow) -> None:
    for r in rows:
        tag = []
        if math.isclose(r.actual_mhz, below_ne.actual_mhz, abs_tol=1e-9):
            tag.append("below_f_NE")
        if math.isclose(r.actual_mhz, ne.actual_mhz, abs_tol=1e-9):
            tag.append("f_NE")
        if math.isclose(r.actual_mhz, fe.actual_mhz, abs_tol=1e-9):
            tag.append("f_FE")
        print(f"  {r.actual_mhz:.9f} MHz  {r.period_ns:.9f} ns  {'/'.join(tag)}")


def cmd_reversecheck(args) -> None:
    csv_path = Path(args.from_csv)
    rows = read_results(csv_path)
    a = analyze(rows)
    print("Fine analysis:")
    print_analysis(a)

    below_ne, ne, fe = select_boundary_rows(rows)
    # Deliberately reverse the main fine-sweep order: fastest -> slowest.
    ordered = sorted(unique_rows([below_ne, ne, fe]), key=lambda r: r.actual_mhz, reverse=True)
    points = [row_to_clock_point(r) for r in ordered]

    parent = inherited_config_from_csv(csv_path)
    cfg = inherited_stage_config(parent, "reversecheck10M", REVERSE_CHECK_BUDGET, points, args.experiment_id)
    cfg["notes"] += " Same-budget reverse-order boundary control (fastest to slowest)."
    write_config(cfg, Path(args.out))

    print("10M reverse-order boundary points:")
    print_boundary_rows(ordered, below_ne, ne, fe)

    if not a["ordered_transition"]:
        print("WARNING: fine transition is non-monotonic/unordered; reverse check is still useful but the bracket is not conventional.")


def cmd_sensitivity(args) -> None:
    csv_path = Path(args.from_csv)
    rows = read_results(csv_path)
    a = analyze(rows)
    print("Fine analysis:")
    print_analysis(a)

    below_ne, ne, fe = select_boundary_rows(rows)
    # Keep the same fastest->slowest order as reversecheck so the 10M vs 100M
    # comparison changes observation budget, not sweep direction.
    ordered = sorted(unique_rows([below_ne, ne, fe]), key=lambda r: r.actual_mhz, reverse=True)
    points = [row_to_clock_point(r) for r in ordered]

    parent = inherited_config_from_csv(csv_path)
    cfg = inherited_stage_config(parent, "sensitivity100M", SENSITIVITY_BUDGET, points, args.experiment_id)
    cfg["notes"] += " 100M boundary sensitivity in same fastest-to-slowest order as reversecheck10M."
    write_config(cfg, Path(args.out))

    print("100M sensitivity points:")
    print_boundary_rows(ordered, below_ne, ne, fe)

    if not a["ordered_transition"]:
        print("WARNING: fine transition is non-monotonic/unordered; do not interpret f_NE..f_FE as a conventional bracket.")


def cmd_summary(args) -> None:
    rows = read_results(Path(args.from_csv))
    a = analyze(rows)
    print_analysis(a)

    print("\nfrequency classification (ascending frequency):")
    for r in sorted(rows, key=lambda x: x.actual_mhz):
        print(
            f"  {r.actual_mhz:12.9f} MHz  {r.period_ns:11.9f} ns  "
            f"{r.outcome:7s}  wrong={r.total_wrong} status={r.run_status}"
        )


def add_common_coarse_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--candidate", required=True)
    p.add_argument("--t-eda", type=float, required=True, dest="t_eda")
    p.add_argument("--artifact-dir", required=True,
                   help="Directory containing <A#>.bit and matching archived reports/DCP")
    p.add_argument("--route-id", default="R00")
    p.add_argument("--workload", default="random", choices=["random", "directed"])
    p.add_argument("--seed", default=DEFAULT_SEED)
    p.add_argument("--batch-size", type=int, default=DEFAULT_BATCH)
    p.add_argument("--host-timeout-s", type=float, default=10.0)
    p.add_argument("--output-root", default="results")
    p.add_argument("--rtl-git-commit", default=None)
    p.add_argument("--experiment-id", default=None)
    p.add_argument("--notes", default=None)
    p.add_argument("--no-program", action="store_true",
                   help="Do not ask fyp_measure_fractional_m.py to program the bitstream")
    p.add_argument("--out", required=True)


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Generate coarse/fine/reverse-check/100M timing-search configs for the FYP board experiment."
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("coarse", help="Generate 1M coarse sweep from candidate + T_EDA")
    add_common_coarse_args(p)
    p.set_defaults(func=cmd_coarse)

    p = sub.add_parser("fine", help="Generate 10M fine sweep from coarse frequencies.csv")
    p.add_argument("--from-csv", required=True)
    p.add_argument("--experiment-id", default=None)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_fine)

    p = sub.add_parser("reversecheck", help="Generate 10M reverse-order boundary control from fine frequencies.csv")
    p.add_argument("--from-csv", required=True)
    p.add_argument("--experiment-id", default=None)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_reversecheck)

    p = sub.add_parser("sensitivity", help="Generate 100M boundary checks from fine frequencies.csv")
    p.add_argument("--from-csv", required=True)
    p.add_argument("--experiment-id", default=None)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_sensitivity)

    p = sub.add_parser("summary", help="Summarize/classify any frequencies.csv")
    p.add_argument("--from-csv", required=True)
    p.set_defaults(func=cmd_summary)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
