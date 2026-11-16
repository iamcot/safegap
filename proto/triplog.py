"""Tóm tắt log CSV của app iPhone (hoặc của run_video.py) sau một chuyến đi.

    uv run python -m proto.triplog safegap_20261115_180000.csv            # in tóm tắt + lưu biểu đồ PNG cạnh file
    uv run python -m proto.triplog logs/*.csv --no-plot                    # nhiều file, chỉ in tóm tắt

Lấy file trên iPhone: app Tệp > Trên iPhone > SafeGap > logs, AirDrop sang Mac.
"""
import argparse
import csv
from collections import Counter
from pathlib import Path
from typing import Dict, List, Optional

LEVELS = ["NONE", "GREEN", "YELLOW", "RED"]


def _f(v) -> Optional[float]:
    try:
        return float(v) if v not in (None, "") else None
    except ValueError:
        return None


def load(path) -> List[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def summarize(rows: List[dict]) -> Dict:
    """Số liệu chính của một chuyến: thời lượng, fps, tỉ lệ có xe phía trước, thời gian từng mức cảnh báo..."""
    if not rows:
        return {"frames": 0}
    t = [_f(r.get("t")) or 0.0 for r in rows]
    dur = max(t) - min(t) if len(t) > 1 else 0.0
    # thời gian mỗi frame = khoảng tới frame sau (bỏ khoảng hở > 1 s, ví dụ app vào nền)
    dt = [min(b - a, 1.0) if b > a else 0.0 for a, b in zip(t, t[1:])] + [0.0]
    level_s = Counter()
    for r, d in zip(rows, dt):
        level_s[r.get("level") or "NONE"] += d
    speeds = [v for v in (_f(r.get("speed_kmh")) for r in rows) if v is not None]
    ds = [v for v in (_f(r.get("d")) for r in rows) if v is not None]
    moving = [r for r in rows if (_f(r.get("speed_kmh")) or 0) >= 40]
    out = {
        "frames": len(rows),
        "duration_s": dur,
        "fps": (len(rows) - 1) / dur if dur > 0 else None,
        "speed_mean_kmh": sum(speeds) / len(speeds) if speeds else None,
        "speed_max_kmh": max(speeds) if speeds else None,
        "gps_frames_pct": 100 * len(speeds) / len(rows),
        "target_pct": 100 * len(ds) / len(rows),
        "d_min_seen_m": min(ds) if ds else None,
        "level_s": {k: level_s.get(k, 0.0) for k in LEVELS},
        "red_alerts": sum(1 for r in rows if r.get("sound") in ("True", "true", "1")),
        "moving_frames": len(moving),
    }
    if "lane" in rows[0]:
        lane = Counter(r.get("lane") or "" for r in rows)
        out["lane_pct"] = {k: 100 * lane.get(k, 0) / len(rows) for k in ["LR", "L", "R", ""]}
    if "thermal" in rows[0]:
        th = Counter(r.get("thermal") or "nominal" for r in rows)
        out["thermal_pct"] = {k: 100 * v / len(rows) for k, v in th.items()}
    infer = [v for v in (_f(r.get("infer_ms")) for r in rows) if v is not None]
    if infer:
        infer.sort()
        out["infer_ms_median"] = infer[len(infer) // 2]
        out["infer_ms_p95"] = infer[int(0.95 * (len(infer) - 1))]
    return out


def _fmt(v, spec="{:.1f}", none="--"):
    return none if v is None else spec.format(v)


def report(name: str, s: Dict) -> str:
    if not s.get("frames"):
        return f"{name}: rỗng"
    m, sec = divmod(int(s["duration_s"]), 60)
    lines = [
        f"== {name}",
        f"Thời lượng {m} phút {sec} s, {s['frames']} frame, {_fmt(s['fps'])} fps"
        + (f", YOLO {s['infer_ms_median']:.0f} ms (p95 {s['infer_ms_p95']:.0f} ms)" if "infer_ms_median" in s else ""),
        f"Tốc độ TB {_fmt(s['speed_mean_kmh'], '{:.0f}')} km/h, max {_fmt(s['speed_max_kmh'], '{:.0f}')} km/h, "
        f"có GPS {s['gps_frames_pct']:.0f}% frame",
        f"Có xe phía trước {s['target_pct']:.0f}% frame, gần nhất {_fmt(s['d_min_seen_m'])} m",
        "Thời gian theo mức: " + ", ".join(f"{k} {s['level_s'][k]:.0f}s" for k in LEVELS),
        f"Số lần kêu (vào RED): {s['red_alerts']}",
    ]
    if "lane_pct" in s:
        lp = s["lane_pct"]
        lines.append(f"Vạch làn: cả 2 bên {lp['LR']:.0f}%, chỉ trái {lp['L']:.0f}%, chỉ phải {lp['R']:.0f}%, "
                     f"không thấy {lp['']:.0f}%")
    if "thermal_pct" in s:
        lines.append("Nhiệt: " + ", ".join(f"{k} {v:.0f}%" for k, v in sorted(s["thermal_pct"].items())))
    return "\n".join(lines)


def plot(rows: List[dict], out_png: Path) -> Path:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    t = [_f(r.get("t")) or 0.0 for r in rows]
    t0 = t[0] if t else 0.0
    t = [x - t0 for x in t]
    col = {"NONE": "#cccccc", "GREEN": "#2e9e4f", "YELLOW": "#f2c40f", "RED": "#d62020"}
    fig, (ax, ax2) = plt.subplots(2, 1, figsize=(14, 6), sharex=True, gridspec_kw={"height_ratios": [3, 1]})
    # nền theo mức cảnh báo
    start = 0
    for i in range(1, len(rows) + 1):
        if i == len(rows) or rows[i].get("level") != rows[start].get("level"):
            ax.axvspan(t[start], t[min(i, len(t) - 1)], color=col.get(rows[start].get("level"), "#ccc"), alpha=0.18, lw=0)
            start = i
    ax.plot(t, [_f(r.get("d_raw")) for r in rows], ".", ms=1.5, color="#999", label="D đo (thô)")
    ax.plot(t, [_f(r.get("d")) for r in rows], "-", lw=1.2, color="#1f5fbf", label="D (đã lọc)")
    ax.plot(t, [_f(r.get("d_min")) for r in rows], "-", lw=1.5, color="#d62020", label="d_min theo luật")
    ax.set_ylabel("m")
    ax.set_ylim(0, 150)
    ax.legend(loc="upper right", fontsize=8)
    ax2.plot(t, [_f(r.get("speed_kmh")) for r in rows], color="#444")
    ax2.set_ylabel("km/h")
    ax2.set_xlabel("giây")
    fig.tight_layout()
    fig.savefig(out_png, dpi=110)
    plt.close(fig)
    return out_png


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("csv", nargs="+", help="file log CSV")
    p.add_argument("--no-plot", action="store_true", help="không vẽ biểu đồ")
    args = p.parse_args(argv)
    for path in map(Path, args.csv):
        rows = load(path)
        print(report(path.name, summarize(rows)))
        if rows and not args.no_plot:
            print("Biểu đồ:", plot(rows, path.with_suffix(".png")))
        print()


if __name__ == "__main__":
    main()
