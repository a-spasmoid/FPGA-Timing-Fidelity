#!/usr/bin/env python3
"""
Enumerate/select legal Clocking-Wizard MMCM points for the FYP timing sweep.

Project assumptions:
  - Zynq-7020 (-1 speed grade)
  - Clock Wizard input/reference = 100 MHz
  - D fixed at 1 for the experiment
  - MMCM M and CLKOUT0 O may use 0.125 steps
  - device-legal VCO range = 600..1200 MHz
  - preferred experimental VCO band defaults to 900..1100 MHz
  - output range is user-selected (default 100..250 MHz)

The register encoders intentionally preserve the convention already exercised
on the project's AXI Clock Wizard:
  0x200: D[7:0], M integer[15:8], M frac*1000[25:16], frac enable bit 26
  0x208: O integer[7:0], O frac*1000[17:8], frac enable bit 18

This tool does NOT touch hardware. It only generates reproducible legal points.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Sequence


FIN_MHZ = 100.0

# 7-series MMCM / XC7Z020-1 constraints relevant to this experiment.
M_MIN = 2.0
M_MAX = 64.0
M_STEP = 0.125

D_MIN = 1
D_MAX = 106

O_MIN_FRAC = 2.0
O_MAX = 128.0
O_STEP = 0.125

VCO_LEGAL_MIN_MHZ = 600.0
VCO_LEGAL_MAX_MHZ = 1200.0
PFD_MIN_MHZ = 10.0
PFD_MAX_MHZ = 450.0
FOUT_MAX_MHZ = 800.0


def _eighth_step(value: float, name: str) -> int:
    """Return value*8 as an integer, rejecting non-0.125 values."""
    n = round(value * 8)
    if not math.isclose(value, n / 8.0, abs_tol=1e-12):
        raise ValueError(f"{name}={value} is not on a 0.125 grid")
    return n


def _split_frac_thousandths(value: float, name: str) -> tuple[int, int]:
    """
    Split an eighth-step value into integer and fractional-thousandths fields.
    Fraction is one of 0,125,250,...,875.
    """
    _eighth_step(value, name)
    whole = int(math.floor(value))
    frac_milli = int(round((value - whole) * 1000))
    if frac_milli not in (0, 125, 250, 375, 500, 625, 750, 875):
        raise ValueError(f"{name}={value}: unexpected fractional field {frac_milli}")
    return whole, frac_milli


def encode_md_compat(m: float, d: int) -> int:
    """
    Project-compatible AXI Clock Wizard 0x200 encoding.

    Matches the previously exercised fractional-M convention:
      M=24.125, D=5 -> 0x047D1805
    """
    if not (D_MIN <= d <= D_MAX):
        raise ValueError(f"D={d} outside primitive range {D_MIN}..{D_MAX}")
    if not (M_MIN <= m <= M_MAX):
        raise ValueError(f"M={m} outside primitive range {M_MIN}..{M_MAX}")

    whole, frac = _split_frac_thousandths(m, "M")
    reg = (d & 0xFF) | ((whole & 0xFF) << 8) | ((frac & 0x3FF) << 16)
    if frac:
        reg |= 1 << 26
    return reg


def encode_o_compat(o: float) -> int:
    """
    Project-compatible AXI Clock Wizard 0x208 encoding.

    Preserves the same fractional-O convention as the current fyp_measure.py.
    """
    if not (o == 1.0 or O_MIN_FRAC <= o <= O_MAX):
        raise ValueError(f"O={o} outside legal CLKOUT0 range")

    whole, frac = _split_frac_thousandths(o, "O")
    reg = (whole & 0xFF) | ((frac & 0x3FF) << 8)
    if frac:
        reg |= 1 << 18
    return reg


@dataclass(frozen=True)
class ClockPoint:
    m: float
    d: int
    o: float

    @property
    def pfd_mhz(self) -> float:
        return FIN_MHZ / self.d

    @property
    def vco_mhz(self) -> float:
        return FIN_MHZ * self.m / self.d

    @property
    def actual_mhz(self) -> float:
        return self.vco_mhz / self.o

    @property
    def period_ns(self) -> float:
        return 1000.0 / self.actual_mhz

    @property
    def md_reg(self) -> int:
        return encode_md_compat(self.m, self.d)

    @property
    def o_reg(self) -> int:
        return encode_o_compat(self.o)

    def legal(self) -> bool:
        if not (M_MIN <= self.m <= M_MAX):
            return False
        if not (D_MIN <= self.d <= D_MAX):
            return False
        if not (self.o == 1.0 or O_MIN_FRAC <= self.o <= O_MAX):
            return False
        if not (PFD_MIN_MHZ <= self.pfd_mhz <= PFD_MAX_MHZ):
            return False
        if not (VCO_LEGAL_MIN_MHZ <= self.vco_mhz <= VCO_LEGAL_MAX_MHZ):
            return False
        if self.actual_mhz > FOUT_MAX_MHZ:
            return False
        return True

    def to_row(self, requested_mhz: Optional[float] = None) -> dict:
        req = self.actual_mhz if requested_mhz is None else requested_mhz
        return {
            "requested_mhz": req,
            "actual_mhz": self.actual_mhz,
            "period_ns": self.period_ns,
            "m": self.m,
            "d": self.d,
            "o": self.o,
            "pfd_mhz": self.pfd_mhz,
            "vco_mhz": self.vco_mhz,
            "md_reg_hex": f"0x{self.md_reg:08X}",
            "o_reg_hex": f"0x{self.o_reg:08X}",
        }


def enumerate_points(
    f_min: float,
    f_max: float,
    vco_min: float,
    vco_max: float,
    d: int = 1,
) -> List[ClockPoint]:
    """
    Enumerate unique output frequencies, choosing one M/O realization per
    frequency.

    Duplicate frequencies are resolved deterministically by preferring:
      1) VCO closest to 1000 MHz,
      2) integer M,
      3) integer O,
      4) lower M,
      5) lower O.
    """
    if vco_min < VCO_LEGAL_MIN_MHZ or vco_max > VCO_LEGAL_MAX_MHZ:
        raise ValueError(
            f"VCO band {vco_min}..{vco_max} exceeds legal "
            f"{VCO_LEGAL_MIN_MHZ}..{VCO_LEGAL_MAX_MHZ} MHz"
        )
    if vco_min > vco_max:
        raise ValueError("vco_min > vco_max")
    if f_min <= 0 or f_min > f_max:
        raise ValueError("invalid output-frequency range")

    pfd = FIN_MHZ / d
    if not (PFD_MIN_MHZ <= pfd <= PFD_MAX_MHZ):
        raise ValueError(f"D={d} gives illegal PFD {pfd} MHz")

    candidates = {}

    m_lo = max(M_MIN, vco_min * d / FIN_MHZ)
    m_hi = min(M_MAX, vco_max * d / FIN_MHZ)
    mi0 = math.ceil((m_lo - 1e-12) * 8)
    mi1 = math.floor((m_hi + 1e-12) * 8)

    for mi in range(mi0, mi1 + 1):
        m = mi / 8.0
        vco = FIN_MHZ * m / d
        if not (vco_min - 1e-12 <= vco <= vco_max + 1e-12):
            continue

        # Our experimental output range is far below VCO, so O >= 2.
        for oi in range(int(O_MIN_FRAC * 8), int(O_MAX * 8) + 1):
            o = oi / 8.0
            cp = ClockPoint(m=m, d=d, o=o)
            f = cp.actual_mhz
            if not (f_min - 1e-12 <= f <= f_max + 1e-12):
                continue
            if not cp.legal():
                continue

            # Exact rational identity for D fixed: f = FIN * mi / (d*oi).
            # Reduced integer pair avoids float-dedup issues.
            g = math.gcd(mi, d * oi)
            key = (mi // g, (d * oi) // g)

            score = (
                abs(cp.vco_mhz - 1000.0),
                0 if float(cp.m).is_integer() else 1,
                0 if float(cp.o).is_integer() else 1,
                cp.m,
                cp.o,
            )
            old = candidates.get(key)
            if old is None or score < old[0]:
                candidates[key] = (score, cp)

    out = [x[1] for x in candidates.values()]
    out.sort(key=lambda cp: cp.actual_mhz)
    return out


def nearest_point(points: Sequence[ClockPoint], target_mhz: float) -> ClockPoint:
    if not points:
        raise ValueError("empty legal grid")
    return min(
        points,
        key=lambda cp: (
            abs(cp.actual_mhz - target_mhz),
            abs(cp.vco_mhz - 1000.0),
            0 if float(cp.m).is_integer() else 1,
            0 if float(cp.o).is_integer() else 1,
            cp.m,
            cp.o,
        ),
    )


def target_grid(start: float, stop: float, step: float) -> List[float]:
    if step <= 0:
        raise ValueError("target step must be positive")
    vals = []
    n = 0
    while True:
        x = start + n * step
        if x > stop + 1e-12:
            break
        vals.append(x)
        n += 1
    return vals


def write_csv(path: Path, rows: Sequence[dict]) -> None:
    if not rows:
        raise ValueError("no rows to write")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)


def write_json(path: Path, rows: Sequence[dict], metadata: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Keep clock_points directly compatible with fyp_measure.py; extra fields
    # are harmless because that script only reads requested_mhz/m/d/o.
    obj = {
        "metadata": metadata,
        "clock_points": rows,
    }
    path.write_text(json.dumps(obj, indent=2) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Generate a legal fine MMCM M/O grid for the FYP timing sweep."
    )
    ap.add_argument("--f-min", type=float, default=100.0)
    ap.add_argument("--f-max", type=float, default=250.0)
    ap.add_argument("--vco-min", type=float, default=900.0)
    ap.add_argument("--vco-max", type=float, default=1100.0)
    ap.add_argument("--d", type=int, default=1)

    ap.add_argument(
        "--target-step-mhz",
        type=float,
        default=None,
        help="If supplied, select the nearest legal point to each target step.",
    )
    ap.add_argument(
        "--targets",
        type=str,
        default=None,
        help="Comma-separated explicit target frequencies in MHz.",
    )

    ap.add_argument("--csv", type=Path, default=None)
    ap.add_argument("--json", type=Path, default=None)
    ap.add_argument("--limit-print", type=int, default=40)
    args = ap.parse_args()

    legal = enumerate_points(
        f_min=args.f_min,
        f_max=args.f_max,
        vco_min=args.vco_min,
        vco_max=args.vco_max,
        d=args.d,
    )

    if args.targets and args.target_step_mhz is not None:
        raise ValueError("use either --targets or --target-step-mhz, not both")

    selected: List[tuple[float, ClockPoint]]

    if args.targets:
        targets = [float(x.strip()) for x in args.targets.split(",") if x.strip()]
        selected = [(t, nearest_point(legal, t)) for t in targets]
    elif args.target_step_mhz is not None:
        targets = target_grid(args.f_min, args.f_max, args.target_step_mhz)
        selected = [(t, nearest_point(legal, t)) for t in targets]
    else:
        selected = [(cp.actual_mhz, cp) for cp in legal]

    # Remove duplicate actual points while keeping first requested target.
    deduped: List[tuple[float, ClockPoint]] = []
    seen = set()
    for target, cp in selected:
        key = (round(cp.actual_mhz, 12), cp.m, cp.d, cp.o)
        if key in seen:
            continue
        seen.add(key)
        deduped.append((target, cp))

    rows = []
    for target, cp in deduped:
        row = cp.to_row(requested_mhz=target)
        row["target_error_mhz"] = cp.actual_mhz - target
        rows.append(row)

    metadata = {
        "clock_reference_mhz": FIN_MHZ,
        "d_fixed": args.d,
        "device": "xc7z020clg400-1",
        "legal_vco_mhz": [VCO_LEGAL_MIN_MHZ, VCO_LEGAL_MAX_MHZ],
        "selected_vco_band_mhz": [args.vco_min, args.vco_max],
        "output_range_mhz": [args.f_min, args.f_max],
        "m_o_step": 0.125,
        "selection_rule": "nearest output; then VCO closest to 1000 MHz; then integer M/O",
        "register_encoding": "project-compatible legacy fractional enable bits (M bit26, O bit18)",
        "legal_unique_points": len(legal),
        "selected_points": len(rows),
    }

    print(json.dumps(metadata, indent=2))
    print()
    print(
        f"{'target':>11} {'actual':>11} {'period(ns)':>11} "
        f"{'M':>6} {'D':>3} {'O':>7} {'VCO':>8} {'0x200':>10} {'0x208':>10}"
    )
    print("-" * 96)

    nshow = min(len(rows), max(args.limit_print, 0))
    for row in rows[:nshow]:
        print(
            f"{row['requested_mhz']:11.6f} "
            f"{row['actual_mhz']:11.6f} "
            f"{row['period_ns']:11.6f} "
            f"{row['m']:6.3f} "
            f"{row['d']:3d} "
            f"{row['o']:7.3f} "
            f"{row['vco_mhz']:8.3f} "
            f"{row['md_reg_hex']:>10} "
            f"{row['o_reg_hex']:>10}"
        )
    if len(rows) > nshow:
        print(f"... {len(rows) - nshow} more points")

    if args.csv:
        write_csv(args.csv, rows)
        print(f"\nWrote {args.csv}")
    if args.json:
        write_json(args.json, rows, metadata)
        print(f"Wrote {args.json}")


if __name__ == "__main__":
    main()
