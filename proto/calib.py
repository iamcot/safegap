"""Tính tiêu cự f_px (mục 4 trong SafeGap.md).

Ví dụ:
    python -m proto.calib a4 --w-px 1550 --dist 3
    python -m proto.calib hfov --width 1920 --hfov 69.4
    python -m proto.calib scale --f 1530 --from-width 2100 --to-width 1920
"""
import argparse
import math

A4_LONG_SIDE_M = 0.297


def f_from_reference(w_px: float, distance_m: float, real_width_m: float = A4_LONG_SIDE_M) -> float:
    """f = w_px * D / W_real (mặc định: tờ A4 dán ngang)."""
    if w_px <= 0 or distance_m <= 0 or real_width_m <= 0:
        raise ValueError("w_px, distance_m, real_width_m phải > 0")
    return w_px * distance_m / real_width_m


def f_from_hfov(image_width_px: float, hfov_deg: float) -> float:
    """f = (width/2) / tan(HFOV/2)."""
    if not 0 < hfov_deg < 180:
        raise ValueError("hfov_deg phải trong (0, 180)")
    return (image_width_px / 2.0) / math.tan(math.radians(hfov_deg) / 2.0)


def scale_f(f_px: float, from_width_px: float, to_width_px: float) -> float:
    """Đổi f sang độ phân giải khác (cùng ống kính, cùng tỉ lệ khung, không crop)."""
    return f_px * to_width_px / from_width_px


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("a4", help="tính f từ ảnh tờ A4 (hoặc vật có bề rộng biết trước)")
    a.add_argument("--w-px", type=float, required=True, help="bề rộng đo được trên ảnh (pixel)")
    a.add_argument("--dist", type=float, required=True, help="khoảng cách camera → vật (m)")
    a.add_argument("--real-width", type=float, default=A4_LONG_SIDE_M, help="bề rộng thật (m), mặc định 0.297")
    h = sub.add_parser("hfov", help="tính f từ góc nhìn ngang")
    h.add_argument("--width", type=float, required=True)
    h.add_argument("--hfov", type=float, required=True)
    s = sub.add_parser("scale", help="đổi f sang độ phân giải khác")
    s.add_argument("--f", type=float, required=True)
    s.add_argument("--from-width", type=float, required=True)
    s.add_argument("--to-width", type=float, required=True)
    args = p.parse_args(argv)
    if args.cmd == "a4":
        f = f_from_reference(args.w_px, args.dist, args.real_width)
    elif args.cmd == "hfov":
        f = f_from_hfov(args.width, args.hfov)
    else:
        f = scale_f(args.f, args.from_width, args.to_width)
    print(f"f_px = {f:.1f}")
    return f


if __name__ == "__main__":
    main()
