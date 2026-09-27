# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy"]
# ///
"""Interactive 3D comparison of one Fidmaa Pic capture, as a local HTML page.

Panels (only those the capture has data for):
  1× single frame · 1× + bilateral · N× median · N× median + bilateral ·
  Apple-filtered photo depth · fusion (Apple shape + raw metric low frequencies)

usage: uv run tools/view3d.py <capture folder or .zip> [-o out.html] [--open]

The output contains a 3D model of the photographed face — keep it local.
"""
import argparse
import base64
import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

import numpy as np

TOOLS = Path(__file__).resolve().parent
SIGMA_SPACE_PX = 2.0     # bilateral: spatial Gaussian
SIGMA_RANGE_M = 0.002    # bilateral: depth steps above ~2 mm are edges and are not blended
RADIUS_PX = 4
FUSION_SIGMA_PX = 15.0   # fusion: raw−Apple difference is kept only at scales above this
FUSION_MAX_DIFF_M = 0.02
NEAR, FAR = 0.2, 0.6     # meters kept in the view
TEXTURE_SIZE = (1280, 960)


def bilateral(depth: np.ndarray) -> np.ndarray:
    valid = np.isfinite(depth) & (depth > 0)
    d = np.where(valid, depth, 0.0)
    h, w = d.shape
    pad = RADIUS_PX
    dp, vp = np.pad(d, pad), np.pad(valid, pad)
    num, den = np.zeros_like(d), np.zeros_like(d)
    for dy in range(-pad, pad + 1):
        for dx in range(-pad, pad + 1):
            nd = dp[pad + dy:pad + dy + h, pad + dx:pad + dx + w]
            nv = vp[pad + dy:pad + dy + h, pad + dx:pad + dx + w]
            weight = (np.exp(-(dx * dx + dy * dy) / (2 * SIGMA_SPACE_PX ** 2))
                      * np.exp(-((nd - d) ** 2) / (2 * SIGMA_RANGE_M ** 2)) * nv)
            num += weight * nd
            den += weight
    return np.where(valid & (den > 0), num / np.maximum(den, 1e-12), np.nan).astype(np.float32)


def normalized_blur(values: np.ndarray, valid: np.ndarray, sigma: float) -> np.ndarray:
    """Gaussian blur that ignores invalid pixels (normalized convolution)."""
    radius = int(3 * sigma)
    x = np.arange(-radius, radius + 1)
    kernel = np.exp(-x * x / (2 * sigma * sigma))

    def blur(a):
        a = np.apply_along_axis(lambda r: np.convolve(r, kernel, mode="same"), 1, a)
        return np.apply_along_axis(lambda c: np.convolve(c, kernel, mode="same"), 0, a)

    num = blur(np.where(valid, values, 0.0))
    den = blur(valid.astype(float))
    return np.where(den > 1e-3, num / np.maximum(den, 1e-12), np.nan)


def fuse(apple: np.ndarray, reference: np.ndarray) -> tuple[np.ndarray, dict]:
    """Apple's shape plus the low-frequency metric correction from the raw reference."""
    both = np.isfinite(apple) & (apple > 0) & np.isfinite(reference) & (reference > 0)
    diff = reference - apple
    usable = both & (np.abs(diff) < FUSION_MAX_DIFF_M)
    correction = normalized_blur(np.where(usable, diff, 0.0), usable, FUSION_SIGMA_PX)
    fused = np.where(np.isfinite(apple) & (apple > 0), apple + np.nan_to_num(correction), np.nan)
    stats = dict(meanDiffMm=float(np.mean(diff[usable]) * 1000), sdDiffMm=float(np.std(diff[usable]) * 1000),
                 usedFraction=float(usable.sum() / max(both.sum(), 1)))
    return fused.astype(np.float32), stats


def roughness_mm(a: np.ndarray, region) -> float:
    y0, y1, x0, x1 = region
    c = a[y0:y1, x0:x1]
    n = (a[y0 - 1:y1 - 1, x0:x1] + a[y0 + 1:y1 + 1, x0:x1] + a[y0:y1, x0 - 1:x1 - 1] + a[y0:y1, x0 + 1:x1 + 1]) / 4
    r = (c - n)[np.isfinite(c - n)]
    return float(np.std(r) * 1000) if r.size else float("nan")


def texture(folder: Path, work: Path) -> str:
    out = work / "texture.jpg"
    subprocess.run(["xcrun", "swift", str(TOOLS / "heic_pixels.swift"), str(folder / "photo.heic"), str(out),
                    str(TEXTURE_SIZE[0]), str(TEXTURE_SIZE[1])], check=True)
    return "data:image/jpeg;base64," + base64.b64encode(out.read_bytes()).decode()


def resolve_capture(path: Path, work: Path) -> Path:
    if path.suffix == ".zip":
        with zipfile.ZipFile(path) as z:
            z.extractall(work)
        found = [p.parent for p in work.rglob("calibration.json")]
        if len(found) != 1:
            sys.exit(f"{path}: expected exactly one capture inside, found {len(found)}")
        return found[0]
    if not (path / "calibration.json").exists():
        sys.exit(f"{path}: not a capture folder (no calibration.json)")
    return path


def build(folder: Path, work: Path) -> dict:
    meta = json.loads((folder / "calibration.json").read_text())
    depth_info = meta["depth"]
    w, h = depth_info["width"], depth_info["height"]
    load = lambda name, n=1: np.fromfile(folder / name, dtype="<f4").reshape(n, h, w)
    stack_info = meta.get("stack")
    panels: list[tuple[str, np.ndarray, str]] = []
    std = None
    median = None
    if stack_info:
        n = stack_info["framesCaptured"]
        stack = load("depth_stack.f32", n)
        single = stack[-1]
        panels += [("1× — pojedyncza klatka ze strumienia", single, ""),
                   ("1× + filtr bilateralny", bilateral(single), "")]
        std = load("depth_std.f32")[0]
        if n > 1:
            median = load("depth_median.f32")[0]
            panels += [(f"{n}× — mediana", median, ""), (f"{n}× mediana + filtr bilateralny", bilateral(median), "")]
    photo = load("depth.f32")[0]
    reference = median if median is not None else (panels[0][1] if panels else None)
    if depth_info.get("isFiltered"):
        panels.append(("Apple — wygładzona głębia zdjęcia", photo, ""))
        if reference is not None:
            fused, s = fuse(photo, reference)
            panels.append(("Fuzja: kształt Apple + skala z surowej", fused,
                           f"Apple vs surowa: średnio {s['meanDiffMm']:+.2f} mm, sd {s['sdDiffMm']:.2f} mm"))
    elif not panels:
        panels.append(("Głębia zdjęcia (surowa)", photo, ""))

    cal = meta.get("depthMapCalibration") or meta["calibration"]
    k, ref = cal["intrinsicMatrix"], cal["intrinsicMatrixReferenceDimensions"]
    fx, fy = k[0][0] * w / ref["width"], k[1][1] * h / ref["height"]
    cx, cy = k[0][2] * w / ref["width"], k[1][2] * h / ref["height"]

    base = panels[0][1]
    near = np.isfinite(base) & (base > NEAR) & (base < FAR)
    ys, xs = np.nonzero(near)
    x0, x1 = max(0, xs.min() - 8), min(w, xs.max() + 9)
    y0, y1 = max(0, ys.min() - 8), min(h, ys.max() + 9)

    def crop(a, keep_range=True):
        c = a[y0:y1, x0:x1].astype(np.float32)
        if keep_range:
            c = np.where(np.isfinite(c) & (c > NEAR) & (c < FAR), c, np.nan).astype(np.float32)
        return base64.b64encode(c.tobytes()).decode()

    region = (h // 2 - 50, h // 2 + 50, w // 2 - 50, w // 2 + 50)
    return dict(
        cw=int(x1 - x0), ch=int(y1 - y0), x0=int(x0), y0=int(y0), fullW=w, fullH=h, fx=fx, fy=fy, cx=cx, cy=cy,
        panels=[dict(title=t, depth=crop(a), rough=roughness_mm(a, region), note=note) for t, a, note in panels],
        std=crop(std, keep_range=False) if std is not None else None,
        stdMedianMm=float(np.nanmedian(std[region[0]:region[1], region[2]:region[3]]) * 1000) if std is not None else None,
        texture=texture(folder, work),
        title=folder.name,
        filter=f"bilateralny: σ {SIGMA_SPACE_PX:g} px, σ głębi {SIGMA_RANGE_M * 1000:g} mm, promień {RADIUS_PX} px",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture", type=Path, help="capture folder or its .zip")
    parser.add_argument("-o", "--output", type=Path, help="output HTML (default: <capture>-3d.html in cwd)")
    parser.add_argument("--open", action="store_true", help="open in the default browser")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        folder = resolve_capture(args.capture, Path(tmp))
        data = build(folder, Path(tmp))
    out = args.output or Path(f"{data['title']}-3d.html")
    template = (TOOLS / "view3d_template.html").read_text()
    out.write_text(template.replace("__DATA__", json.dumps(data)))
    for p in data["panels"]:
        print(f"{p['title']:45s} chropowatość {p['rough']:.2f} mm  {p['note']}")
    print(f"→ {out}")
    if args.open:
        subprocess.run(["open", str(out)], check=True)


if __name__ == "__main__":
    main()
