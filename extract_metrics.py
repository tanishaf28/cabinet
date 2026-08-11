#!/usr/bin/env python3
"""Roll up merge_eval.py's per-case merged CSVs into one flat summary CSV:
one row per experiment, with throughput + latency, for clients and for
servers separately.

<run_dir> is searched recursively for merged_cabinet_clients_*.csv and
merged_cabinet_servers_*.csv (the filenames merge_eval.py writes by default —
see merge_eval.py's _default_output). Each run_*_plainmsg_*.sh /
run_*_client_scaling_eval_*.sh driver archives a case's merged CSVs directly
into <run_dir>/<label>/ (see archive_results in those scripts), so the case
label is the CSV's parent directory name. Size is parsed from that label:
either an "n<N>" prefix (cluster-size sweeps) or a "clients_<N>" prefix
(client-count sweeps).

Writes <run_dir>/extracted_metrics.csv (clients) and
<run_dir>/extracted_metrics_servers.csv (servers), same columns:
system,size,experiment,filename,throughput,avg_latency,p50,p95,p99,conflict
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
import re
import sys
from typing import Optional


METRIC_FIELDS = [
    "TOTAL_THROUGHPUT",
    "AVG_LATENCY",
    "P50_LATENCY",
    "P95_LATENCY",
    "P99_LATENCY",
    "TOTAL_CONFLICT_COMMITS",
]


def _parse_value(raw: str) -> float:
    match = re.search(r"-?\d+(?:\.\d+)?", raw.replace(",", ""))
    return float(match.group(0)) if match else 0.0


def _parse_case_csv(path: str) -> dict[str, float]:
    values: dict[str, float] = {field: 0.0 for field in METRIC_FIELDS}
    with open(path, "r", newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        next(reader, None)  # header: metric,value,notes
        for row in reader:
            if not row:
                continue
            metric = row[0].strip()
            if metric in values and len(row) > 1:
                values[metric] = _parse_value(row[1])
    return values


def _pick_latest(csvs: list[str]) -> str:
    # Filenames embed a sortable generation timestamp (merge_eval.py's
    # merged_cabinet_{clients,servers}_<YYYYMMDD_HHMMSS>.csv); prefer that
    # over mtime, which only reflects when archive_results() happened to
    # cp the file and can tie or lag behind the true generation order.
    return max(csvs, key=os.path.basename)


def _size_from_path(path: str, default_size: Optional[int]) -> int:
    match = re.search(r"[\\/](?:n|clients_)(\d+)(?:[\\/_]|$)", path)
    if match:
        return int(match.group(1))
    if default_size is not None:
        return default_size
    raise ValueError(f"Could not infer size from path {path!r}; pass --size")


def extract(run_dir: str, system: str, default_size: Optional[int], glob_name: str, output_name: str) -> str:
    pattern = os.path.join(run_dir, "**", glob_name)
    # Keyed by (size, label): the same case label (e.g. "eval1_indep_0") is
    # reused under every n<N>/ cluster-size directory, so label alone would
    # collide across sizes and _pick_latest would keep only the
    # most-recently-modified size's result, silently dropping the rest.
    case_csvs: dict[tuple[int, str], list[str]] = {}
    for csv_path in glob.glob(pattern, recursive=True):
        case_dir = os.path.dirname(csv_path)
        label = os.path.basename(case_dir)
        size = _size_from_path(csv_path, default_size)
        case_csvs.setdefault((size, label), []).append(csv_path)

    if not case_csvs:
        print(f"WARNING: no {glob_name} found under {run_dir}", file=sys.stderr)
        return ""

    output_path = os.path.join(run_dir, output_name)
    write_header = not os.path.exists(output_path)

    with open(output_path, "a", newline="", encoding="utf-8") as out:
        writer = csv.writer(out)
        if write_header:
            writer.writerow(
                ["system", "size", "experiment", "filename", "throughput",
                 "avg_latency", "p50", "p95", "p99", "conflict"]
            )
        for size, label in sorted(case_csvs):
            latest = _pick_latest(case_csvs[(size, label)])
            metrics = _parse_case_csv(latest)
            writer.writerow([
                system,
                size,
                label,
                os.path.basename(latest),
                metrics["TOTAL_THROUGHPUT"],
                metrics["AVG_LATENCY"],
                metrics["P50_LATENCY"],
                metrics["P95_LATENCY"],
                metrics["P99_LATENCY"],
                metrics["TOTAL_CONFLICT_COMMITS"],
            ])

    print(f"Wrote {len(case_csvs)} row(s) to {output_path}")
    return output_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", help="Run directory to scan for merged_cabinet_clients_*.csv / merged_cabinet_servers_*.csv")
    parser.add_argument("--size", type=int, default=None, help="Cluster size to record when not inferable from an n<N>/ path segment")
    parser.add_argument("--system", default="cabinet", help="System name column (default: cabinet)")
    args = parser.parse_args()

    try:
        extract(args.run_dir, args.system, args.size, "merged_cabinet_clients_*.csv", "extracted_metrics.csv")
        extract(args.run_dir, args.system, args.size, "merged_cabinet_servers_*.csv", "extracted_metrics_servers.csv")
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
