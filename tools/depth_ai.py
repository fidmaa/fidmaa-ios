"""Monocular (RGB-only) depth for a capture's photo; the TrueDepth map is not used here.

Writes a Float32 little-endian map in meters on the depth-map grid (sensor orientation, same size as
depth.f32), ready for `view3d.py --ai-depth`.

Model: Apple Depth Pro (https://github.com/apple/ml-depth-pro); run it in an environment with
Depth Pro installed, from a directory containing checkpoints/depth_pro.pt (see README).
(MoGe-2 was tried as well and dropped: 3× too flat faces and patch artifacts — see git history.)

usage: python tools/depth_ai.py <capture folder> <out.f32>
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch
from PIL import Image

TOOLS = Path(__file__).resolve().parent
# EXIF orientation → PIL transpose that makes the stored pixels upright, and its inverse.
UPRIGHT = {
    1: (None, None),
    3: (Image.ROTATE_180, Image.ROTATE_180),
    6: (Image.ROTATE_270, Image.ROTATE_90),
    8: (Image.ROTATE_90, Image.ROTATE_270),
}


def infer_depthpro(image: Image.Image, f_px: float, device: torch.device) -> np.ndarray:
    import depth_pro

    model, transform = depth_pro.create_model_and_transforms(device=device, precision=torch.float16)
    model.eval()
    with torch.no_grad():
        prediction = model.infer(transform(image).to(device), f_px=torch.tensor(f_px, device=device))
    return prediction["depth"].float().cpu().numpy()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    meta = json.loads((args.capture / "calibration.json").read_text())
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
        subprocess.run(
            [
                "xcrun",
                "swift",
                str(TOOLS / "heic_pixels.swift"),
                str(args.capture / "photo.heic"),
                str(jpg),
                str(photo_w),
                str(photo_h),
            ],
            check=True,
        )
        image = Image.open(jpg).convert("RGB")
    if to_upright is not None:
        image = image.transpose(to_upright)
    f_px = cal["intrinsicMatrix"][0][0] * photo_w / ref_w  # fx == fy, unchanged by 90° rotations

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    depth = infer_depthpro(image, f_px, device)
    finite = depth[np.isfinite(depth)]
    print(
        f"Depth Pro: {depth.shape[1]}x{depth.shape[0]}, f_px {f_px:.1f}, "
        f"range {finite.min():.3f}–{finite.max():.3f} m, device {device}"
    )

    result = Image.fromarray(depth.astype(np.float32), mode="F")
    if back is not None:
        result = result.transpose(back)
    result = result.resize((w, h), Image.BOX)
    np.asarray(result, dtype="<f4").tofile(args.output)
    print(f"→ {args.output} ({w}x{h}, sensor orientation)")


if __name__ == "__main__":
    main()
