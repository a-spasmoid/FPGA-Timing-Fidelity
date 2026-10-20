#!/usr/bin/env python3
from __future__ import annotations

import argparse, csv, hashlib, json, math, os, time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional
from pynq import MMIO

try:
    from pynq import Bitstream
except Exception:
    Bitstream = None

CTRL_BASE   = 0x41200000
STATUS_BASE = 0x41210000
CLKWIZ_BASE = 0x43C00000
MMIO_RANGE  = 0x10000

CTRL_WORD_OFFSET = 0x0
SEED_OFFSET      = 0x8
STATUS0_OFFSET   = 0x0
STATUS1_OFFSET   = 0x8

CLK_STATUS_OFFSET = 0x04
CLK_MD_OFFSET     = 0x200
CLK_OUT0_OFFSET   = 0x208
CLK_RECONFIG      = 0x25C

SW_RESET_BIT = 19
WORKLOAD_MODES = {"random": 0, "directed": 1}

def utc_now():
    return datetime.now(timezone.utc).isoformat()

def parse_int(v):
    return v if isinstance(v, int) else int(v, 0)

def sha256_file(path):
    if not path or not Path(path).is_file():
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def decode_status(s0, s1):
    return {
        "tests": s0 & 0xffff,
        "wrong": (s0 >> 16) & 0xffff,
        "first_wrong_index": s1 & 0xffff,
        "first_wrong_valid": (s1 >> 16) & 1,
        "timeout_seen": (s1 >> 17) & 1,
        "runner_busy": (s1 >> 18) & 1,
        "done_toggle": (s1 >> 19) & 1,
        "timeout_candidate_seen": (s1 >> 20) & 1,
        "timeout_golden_seen": (s1 >> 21) & 1,
        "lock_live": (s1 >> 22) & 1,
        "clock_fault_seen": (s1 >> 23) & 1,
    }

def classify_timeout(st):
    if not st["timeout_seen"]:
        return "none"
    c, g = st["timeout_candidate_seen"], st["timeout_golden_seen"]
    if not c and g:
        return "candidate_timeout"
    if c and not g:
        return "golden_timeout"
    if not c and not g:
        return "neither_returned"
    return "both_seen_timeout"

@dataclass(frozen=True)
class ClockPoint:
    requested_mhz: float
    m: float
    d: int
    o: float

    @property
    def pfd_mhz(self):
        return 100.0 / self.d

    @property
    def vco_mhz(self):
        return 100.0 * self.m / self.d

    @property
    def actual_mhz(self):
        return self.vco_mhz / self.o

    @property
    def period_ns(self):
        return 1000.0 / self.actual_mhz

class MeasurementRig:
    def __init__(self, host_timeout_s=10.0):
        self.ctrl = MMIO(CTRL_BASE, MMIO_RANGE)
        self.status = MMIO(STATUS_BASE, MMIO_RANGE)
        self.clkwiz = MMIO(CLKWIZ_BASE, MMIO_RANGE)
        self.host_timeout_s = host_timeout_s
        self.start_toggle = 0

    def read_status(self):
        s0 = self.status.read(STATUS0_OFFSET)
        s1 = self.status.read(STATUS1_OFFSET)
        st = decode_status(s0, s1)
        st["status0_raw"] = s0
        st["status1_raw"] = s1
        return st

    @staticmethod
    def _split_eighth_step(value, name):
        eighths = round(value * 8)
        snapped = eighths / 8.0
        if not math.isclose(value, snapped, abs_tol=1e-9):
            raise ValueError(f"{name}={value} is not on the validated 0.125 grid")

        whole = int(math.floor(snapped))
        frac = int(round((snapped - whole) * 1000))

        if frac not in (0, 125, 250, 375, 500, 625, 750, 875):
            raise ValueError(f"{name}={value} produced unexpected fractional field {frac}")

        return whole, frac

    @classmethod
    def encode_md(cls, m, d):
        """
        Project-compatible Clock Wizard register 0x200 encoding.

        Layout used by the already-tested AXI Clock Wizard path:
          [7:0]   D
          [15:8]  integer M
          [25:16] fractional M * 1000
          [26]    fractional-M enable

        Example previously exercised on hardware:
          M=24.125, D=5 -> 0x047D1805
        """
        if not 1 <= d <= 106:
            raise ValueError(f"D={d} is outside the supported MMCM range 1..106")

        whole, frac = cls._split_eighth_step(m, "M")

        if not 2.0 <= m <= 64.0:
            raise ValueError(f"M={m} is outside the supported MMCM range 2..64")

        reg = (d & 0xff) | ((whole & 0xff) << 8)

        if frac:
            reg |= (frac << 16) | (1 << 26)

        return reg

    @classmethod
    def encode_o(cls, o):
        """
        Project-compatible Clock Wizard register 0x208 encoding.

        Layout preserved from the already-validated script:
          [7:0]   integer O
          [17:8]  fractional O * 1000
          [18]    fractional-O enable
        """
        whole, frac = cls._split_eighth_step(o, "O")

        if not (math.isclose(o, 1.0) or 2.0 <= o <= 128.0):
            raise ValueError(f"O={o} is outside the supported CLKOUT0 range")

        reg = whole

        if frac:
            reg |= (frac << 8) | (1 << 18)

        return reg

    @staticmethod
    def validate_clock_point(cp):
        # 7-series / XC7Z020-1 limits relevant to this rig.
        if not 10.0 <= cp.pfd_mhz <= 450.0:
            raise ValueError(
                f"Illegal MMCM PFD frequency {cp.pfd_mhz:.6f} MHz "
                f"for M={cp.m}, D={cp.d}, O={cp.o}"
            )

        if not 600.0 <= cp.vco_mhz <= 1200.0:
            raise ValueError(
                f"Illegal MMCM VCO frequency {cp.vco_mhz:.6f} MHz "
                f"for M={cp.m}, D={cp.d}, O={cp.o}"
            )

        if cp.actual_mhz > 800.0:
            raise ValueError(
                f"Illegal CLKOUT0 frequency {cp.actual_mhz:.6f} MHz "
                f"for M={cp.m}, D={cp.d}, O={cp.o}"
            )

    def set_clock_point(self, cp):
        self.validate_clock_point(cp)

        md_reg = self.encode_md(cp.m, cp.d)
        o_reg = self.encode_o(cp.o)

        # Hold the measurement logic in reset while the MMCM changes.
        # This reset does not reset the Clock Wizard itself.
        self.ctrl.write(CTRL_WORD_OFFSET, 1 << SW_RESET_BIT)
        time.sleep(0.001)

        self.clkwiz.write(CLK_MD_OFFSET, md_reg)
        self.clkwiz.write(CLK_OUT0_OFFSET, o_reg)
        self.clkwiz.write(CLK_RECONFIG, 0x3)

        t0 = time.monotonic()
        while self.clkwiz.read(CLK_RECONFIG) & 1:
            if time.monotonic() - t0 > 0.5:
                raise RuntimeError("Clock Wizard reconfiguration timeout")

        # Give LOCKED its own timeout window rather than sharing the
        # reconfiguration timer.
        t0 = time.monotonic()
        while not (self.clkwiz.read(CLK_STATUS_OFFSET) & 1):
            if time.monotonic() - t0 > 0.5:
                raise RuntimeError("Clock Wizard failed to lock")

        time.sleep(0.002)

        # Release the coordinated logic reset only after the Clock Wizard
        # reports lock.  The RTL then synchronously deasserts reset in both
        # clock domains.
        self.ctrl.write(CTRL_WORD_OFFSET, 0)
        self.start_toggle = 0
        time.sleep(0.001)

        if not self.read_status()["lock_live"]:
            raise RuntimeError("lock_live is low after reconfiguration")

    def run_batch(self, count, workload_mode):
        if not 1 <= count <= 0xffff:
            raise ValueError("batch count must be 1..65535")

        old_done = self.read_status()["done_toggle"]
        self.start_toggle ^= 1

        word = (
            (count & 0xffff)
            | ((self.start_toggle & 1) << 16)
            | ((workload_mode & 0x3) << 17)
        )

        t0 = time.monotonic()
        self.ctrl.write(CTRL_WORD_OFFSET, word)

        while True:
            st = self.read_status()
            if st["done_toggle"] != old_done:
                break
            if time.monotonic() - t0 > self.host_timeout_s:
                raise TimeoutError("Host timed out waiting for batch completion")

        st["elapsed_s"] = time.monotonic() - t0
        st["timeout_class"] = classify_timeout(st)
        return st

BATCH_FIELDS = [
    "experiment_id","candidate","route_id","workload","seed_hex",
    "frequency_requested_mhz","frequency_actual_mhz","period_ns",
    "clock_m","clock_d","clock_o","batch_index","global_start_index",
    "requested_transactions","completed_transactions","wrong",
    "first_wrong_valid","first_wrong_local","first_wrong_global",
    "timeout_seen","timeout_class","timeout_candidate_seen",
    "timeout_golden_seen","lock_live","clock_fault_seen",
    "status0_raw","status1_raw","elapsed_s","timestamp_utc"
]

FREQ_FIELDS = [
    "experiment_id","candidate","route_id","workload","seed_hex",
    "frequency_requested_mhz","frequency_actual_mhz","period_ns",
    "clock_m","clock_d","clock_o","target_transactions",
    "completed_transactions","total_wrong","error_rate","batches_run",
    "batches_with_error","first_wrong_global","timeout_seen",
    "timeout_class","clock_fault_seen","measurement_valid","budget_complete",
    "valid_run","run_status","elapsed_s","timestamp_utc"
]

class CsvSink:
    def __init__(self, path, fields):
        self.file = open(path, "w", newline="", buffering=1)
        self.writer = csv.DictWriter(self.file, fieldnames=fields)
        self.writer.writeheader()
        self.file.flush()
        os.fsync(self.file.fileno())

    def write(self, row):
        self.writer.writerow(row)
        self.file.flush()
        os.fsync(self.file.fileno())

    def close(self):
        self.file.close()

def run_experiment(config_path):
    cfg = json.loads(Path(config_path).read_text())

    experiment_id = cfg["experiment_id"]
    candidate = cfg["candidate"]
    route_id = cfg["route_id"]
    workload = cfg.get("workload", "random").lower()
    workload_mode = WORKLOAD_MODES[workload]
    seed = parse_int(cfg["seed"]) & 0xffffffff
    batch_size = int(cfg.get("batch_size", 50000))
    budget = int(cfg["test_budget"])

    if not 1 <= batch_size <= 65535:
        raise ValueError("batch_size must be 1..65535")
    if budget <= 0:
        raise ValueError("test_budget must be positive")

    points = []
    for x in cfg["clock_points"]:
        o = float(x["o"])
        m = float(x.get("m", 10.0))
        d = int(x.get("d", 1))
        actual = 100.0 * m / (d * o)
        requested = float(x.get("requested_mhz", actual))

        # requested_mhz is descriptive; M/D/O define the actual applied clock.
        # Reject obvious hand-edit mistakes while allowing small target-to-grid
        # differences from the fine-grid selector.
        if abs(requested - actual) > 1.0:
            raise ValueError(
                f"clock point requested_mhz={requested:.9f} differs from "
                f"M/D/O actual={actual:.9f} MHz by more than 1 MHz"
            )

        points.append(ClockPoint(requested, m, d, o))

    out_dir = Path(cfg.get("output_root", "results")) / experiment_id
    out_dir.mkdir(parents=True, exist_ok=False)

    saved_cfg = out_dir / "config_used.json"
    saved_cfg.write_text(json.dumps(cfg, indent=2, sort_keys=True) + "\n")

    bitstream = cfg.get("bitstream")
    if cfg.get("program_bitstream", False):
        if not bitstream:
            raise ValueError("program_bitstream=true but no bitstream supplied")
        if Bitstream is None:
            raise RuntimeError("pynq.Bitstream unavailable")
        Bitstream(bitstream).download()
        time.sleep(0.1)

    manifest = {
        "schema_version": 1,
        "created_utc": utc_now(),
        "experiment_id": experiment_id,
        "candidate": candidate,
        "route_id": route_id,
        "board": cfg.get("board", "PYNQ-Z2"),
        "device": cfg.get("device", "xc7z020clg400-1"),
        "vivado_version": cfg.get("vivado_version", "2026.1"),
        "rtl_git_commit": cfg.get("rtl_git_commit"),
        "workload": workload,
        "prng": cfg.get("prng", "5x xorshift32 continuous across batches"),
        "seed_hex": f"0x{seed:08X}",
        "batch_size": batch_size,
        "test_budget_per_frequency": budget,
        "bitstream": bitstream,
        "bitstream_sha256": sha256_file(bitstream),
        "timing_report": cfg.get("timing_report"),
        "timing_report_sha256": sha256_file(cfg.get("timing_report")),
        "utilization_report": cfg.get("utilization_report"),
        "utilization_report_sha256": sha256_file(cfg.get("utilization_report")),
        "routed_dcp": cfg.get("routed_dcp"),
        "routed_dcp_sha256": sha256_file(cfg.get("routed_dcp")),
        "T_EDA_ns": cfg.get("T_EDA_ns"),
        "config_sha256": sha256_file(saved_cfg),
        "script_sha256": sha256_file(__file__),
        "clock_reference_mhz": 100.0,
        "notes": cfg.get("notes", ""),
    }
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )

    batch_sink = CsvSink(out_dir / "batches.csv", BATCH_FIELDS)
    freq_sink = CsvSink(out_dir / "frequencies.csv", FREQ_FIELDS)
    rig = MeasurementRig(float(cfg.get("host_timeout_s", 10.0)))

    try:
        for n, cp in enumerate(points, start=1):
            print(
                f"\n[{n}/{len(points)}] "
                f"{cp.actual_mhz:.6f} MHz ({cp.period_ns:.6f} ns)"
            )

            # Reset + clock reconfiguration makes every frequency restart from
            # transaction 0 of the same seeded long PRNG sequence.
            rig.set_clock_point(cp)
            rig.ctrl.write(SEED_OFFSET, seed)

            completed = 0
            total_wrong = 0
            batches = 0
            batches_with_error = 0
            first_wrong_global = None
            any_timeout = 0
            timeout_class = "none"
            any_clock_fault = 0
            measurement_valid = True
            budget_complete = False
            valid_run = True
            run_status = "complete"
            point_t0 = time.monotonic()

            while completed < budget:
                requested = min(batch_size, budget - completed)
                batch_start = completed

                try:
                    st = rig.run_batch(requested, workload_mode)
                except TimeoutError:
                    measurement_valid = False
                    valid_run = False
                    run_status = "host_timeout"
                    print(f"  HOST TIMEOUT at batch {batches}")
                    break

                local_first = (
                    st["first_wrong_index"] if st["first_wrong_valid"] else None
                )
                global_first = (
                    batch_start + local_first if local_first is not None else None
                )
                if first_wrong_global is None and global_first is not None:
                    first_wrong_global = global_first

                batch_sink.write({
                    "experiment_id": experiment_id,
                    "candidate": candidate,
                    "route_id": route_id,
                    "workload": workload,
                    "seed_hex": f"0x{seed:08X}",
                    "frequency_requested_mhz": f"{cp.requested_mhz:.9f}",
                    "frequency_actual_mhz": f"{cp.actual_mhz:.9f}",
                    "period_ns": f"{cp.period_ns:.9f}",
                    "clock_m": cp.m,
                    "clock_d": cp.d,
                    "clock_o": cp.o,
                    "batch_index": batches,
                    "global_start_index": batch_start,
                    "requested_transactions": requested,
                    "completed_transactions": st["tests"],
                    "wrong": st["wrong"],
                    "first_wrong_valid": st["first_wrong_valid"],
                    "first_wrong_local": "" if local_first is None else local_first,
                    "first_wrong_global": "" if global_first is None else global_first,
                    "timeout_seen": st["timeout_seen"],
                    "timeout_class": st["timeout_class"],
                    "timeout_candidate_seen": st["timeout_candidate_seen"],
                    "timeout_golden_seen": st["timeout_golden_seen"],
                    "lock_live": st["lock_live"],
                    "clock_fault_seen": st["clock_fault_seen"],
                    "status0_raw": f"0x{st['status0_raw']:08X}",
                    "status1_raw": f"0x{st['status1_raw']:08X}",
                    "elapsed_s": f"{st['elapsed_s']:.9f}",
                    "timestamp_utc": utc_now(),
                })

                batches += 1
                completed += st["tests"]
                total_wrong += st["wrong"]
                if st["wrong"]:
                    batches_with_error += 1

                if st["clock_fault_seen"] or not st["lock_live"]:
                    any_clock_fault = 1
                    measurement_valid = False
                    valid_run = False
                    run_status = "clock_infrastructure_fault"
                    print("  INFRASTRUCTURE FAULT")
                    break

                if st["timeout_seen"]:
                    any_timeout = 1
                    timeout_class = st["timeout_class"]
                    run_status = timeout_class

                    measurement_valid = (
                        timeout_class == "candidate_timeout"
                        and not st["clock_fault_seen"]
                        and st["lock_live"]
                    )

                    # Backward-compatible field: valid_run now means the
                    # measurement is scientifically usable, not that the full
                    # requested transaction budget completed.
                    valid_run = measurement_valid

                    print(f"  TIMEOUT: {timeout_class}")
                    break

                if st["tests"] != requested:
                    measurement_valid = False
                    valid_run = False
                    run_status = "short_batch_without_timeout"
                    break

                if batches % 100 == 0 or completed == budget:
                    print(f"  {completed:,}/{budget:,} wrong={total_wrong:,}")

            elapsed = time.monotonic() - point_t0
            budget_complete = (completed == budget and run_status == "complete")

            # Only report an error-rate estimate for a full-budget run.
            # Candidate timeouts remain valid failure evidence, but they are
            # censored/incomplete with respect to the requested error-rate budget.
            error_rate = (
                total_wrong / completed
                if completed and budget_complete
                else None
            )

            freq_sink.write({
                "experiment_id": experiment_id,
                "candidate": candidate,
                "route_id": route_id,
                "workload": workload,
                "seed_hex": f"0x{seed:08X}",
                "frequency_requested_mhz": f"{cp.requested_mhz:.9f}",
                "frequency_actual_mhz": f"{cp.actual_mhz:.9f}",
                "period_ns": f"{cp.period_ns:.9f}",
                "clock_m": cp.m,
                "clock_d": cp.d,
                "clock_o": cp.o,
                "target_transactions": budget,
                "completed_transactions": completed,
                "total_wrong": total_wrong,
                "error_rate": "" if error_rate is None else f"{error_rate:.12g}",
                "batches_run": batches,
                "batches_with_error": batches_with_error,
                "first_wrong_global": "" if first_wrong_global is None else first_wrong_global,
                "timeout_seen": any_timeout,
                "timeout_class": timeout_class,
                "clock_fault_seen": any_clock_fault,
                "measurement_valid": int(measurement_valid),
                "budget_complete": int(budget_complete),
                "valid_run": int(valid_run),
                "run_status": run_status,
                "elapsed_s": f"{elapsed:.6f}",
                "timestamp_utc": utc_now(),
            })

            print(
                f"  RESULT completed={completed:,} wrong={total_wrong:,} "
                f"first_wrong={first_wrong_global} status={run_status}"
            )

            if run_status in ("clock_infrastructure_fault", "host_timeout"):
                break
    finally:
        batch_sink.close()
        freq_sink.close()

    print(f"\nLogs: {out_dir.resolve()}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config", type=Path)
    args = ap.parse_args()
    run_experiment(args.config)

if __name__ == "__main__":
    main()
