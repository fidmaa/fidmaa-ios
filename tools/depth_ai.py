"""Monocular depth for a capture's photo with Apple Depth Pro (RGB only; the TrueDepth map is not used here).

Writes a Float32 little-endian map in meters on the depth-map grid (sensor orientation, same size as
depth.f32), ready for `view3d.py --ai-depth`.

Run inside an environment with Depth Pro installed (https://github.com/apple/ml-depth-pro), from a
directory containing checkpoints/depth_pro.pt:
    python tools/depth_ai.py <capture folder> <out.f32>
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch
from PIL import Image

import depth_pro

TOOLS = Path(__file__).resolve().parent
# EXIF orientation → PIL transpose that makes the stored pixels upright, and its inverse.
UPRIGHT = {1: (None, None), 3: (Image.ROTATE_180, Image.ROTATE_180),
           6: (Image.ROTATE_270, Image.ROTATE_90), 8: (Image.ROTATE_90, Image.ROTATE_270)}


def main(folder: Path, out: Path) -> None:
    meta = json.loads((folder / "calibration.json").read_text())
    w, h = meta["depth"]["width"], meta["depth"]["height"]
    cal = meta.get("depthMapCalibration") or meta["calibration"]
    ref_w = cal["intrinsicMatrixReferenceDimensions"]["width"]
    orientation = meta["image"]["exifOrientation"]
    if orientation not in UPRIGHT:
        sys.exit(f"unsupported EXIF orientation {orientation}")
    to_upright, back = UPRIGHT[orientation]

    with tempfile.TemporaryDirectory() as tmp:
        jpg = Path(tmp) / "photo.jpg"
        photo_w, photo_h = meta["image"]["width"], meta["image"]["height"]
        subprocess.run(["xcrun", "swift", str(TOOLS / "heic_pixels.swift"), str(folder / "photo.heic"), str(jpg),
                        str(photo_w), str(photo_h)], check=True)
        image = Image.open(jpg).convert("RGB")
    if to_upright is not None:
        image = image.transpose(to_upright)
    f_px = cal["intrinsicMatrix"][0][0] * photo_w / ref_w  # fx == fy, unchanged by 90° rotations

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model, transform = depth_pro.create_model_and_transforms(device=device, precision=torch.float16)
    model.eval()
    with torch.no_grad():
        prediction = model.infer(transform(image).to(device), f_px=torch.tensor(f_px, device=device))
    depth = prediction["depth"].float().cpu().numpy()
    print(f"Depth Pro: {depth.shape[1]}x{depth.shape[0]}, f_px {f_px:.1f}, "
          f"range {np.nanmin(depth):.3f}–{np.nanmax(depth):.3f} m, device {device}")

    result = Image.fromarray(depth.astype(np.float32), mode="F")
    if back is not None:
        result = result.transpose(back)
    result = result.resize((w, h), Image.BOX)
    np.asarray(result, dtype="<f4").tofile(out)
    print(f"→ {out} ({w}x{h}, sensor orientation)")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
