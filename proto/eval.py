"""So D ước lượng với ground truth.

    python -m proto.eval data/groundtruth.csv --logs out/

groundtruth.csv: clip,frame_start,frame_end,distance_m
  (clip = tên file video không có đuôi; log tương ứng là out/<clip>.csv do run_video.py ghi)
"""
import argparse
import csv
import statistics
from pathlib import Path
from typing import Dict, List


def evaluate(gt_rows: List[dict], logs: Dict[str, List[dict]]) -> List[dict]:
    """Mỗi mốc GT → median D ước lượng trong khoảng frame, sai số %."""
    out = []
    for g in gt_rows:
        clip, f0 = g["clip"], int(g["frame_start"])
        f1 = int(g.get("frame_end") or f0)
        truth = float(g["distance_m"])
        ds = [float(r["d"]) for r in logs.get(clip, [])
              if r.get("d") not in (None, "") and f0 <= int(r["frame"]) <= f1]
        if not ds:
            out.append({"clip": clip, "truth_m": truth, "est_m": None, "err_pct": None, "n": 0})
            continue
        est = statistics.median(ds)
        out.append({"clip": clip, "truth_m": truth, "est_m": est,
                    "err_pct": 100.0 * (est - truth) / truth, "n": len(ds)})
    return out


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("groundtruth")
    p.add_argument("--logs", default="out")
    p.add_argument("--max-err", type=float, default=15.0)
    args = p.parse_args(argv)
    with open(args.groundtruth, newline="") as f:
        gt = list(csv.DictReader(f))
    logs = {}
    for clip in {g["clip"] for g in gt}:
        path = Path(args.logs) / f"{clip}.csv"
        if path.exists():
            with open(path, newline="") as f:
                logs[clip] = list(csv.DictReader(f))
    res = evaluate(gt, logs)
    if not res:
        print("Chưa có mốc ground truth nào trong", args.groundtruth)
        return 1
    ok = True
    print(f"{'clip':<20}{'thật(m)':>9}{'ước(m)':>9}{'sai %':>8}{'n':>6}")
    for r in res:
        est = f"{r['est_m']:.1f}" if r["est_m"] is not None else "--"
        err = f"{r['err_pct']:+.1f}" if r["err_pct"] is not None else "--"
        print(f"{r['clip']:<20}{r['truth_m']:>9.1f}{est:>9}{err:>8}{r['n']:>6}")
        if r["err_pct"] is None or abs(r["err_pct"]) > args.max_err:
            ok = False
    print("ĐẠT" if ok else f"CHƯA ĐẠT (ngưỡng ±{args.max_err}%)")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
