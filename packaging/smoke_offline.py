#!/usr/bin/env python
"""Offline self-test for a forge-align env.

Synthesises a textured plate and a rotated/scaled/shifted reference, writes
them as DPX (and a ProRes .mov when ffmpeg is present), then runs
``forge_cv.cli_solve`` exactly like the Flame hook does and checks the
recovered transform. SuperPoint is exercised when torch + lightglue import.
Needs no network, no Flame and no facility OCIO config.

Exit code 0 on success, 1 on any failure.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

import cv2
import numpy as np
import OpenImageIO as oiio
import PyOpenColorIO as ocio

W, H = 960, 540
FRAME = 1001
# Ground truth applied to the plate to make the reference.
ANGLE_DEG, SCALE, SHIFT = 3.0, 1.08, (25.0, -15.0)


def _texture(seed=7):
    rng = np.random.default_rng(seed)
    img = cv2.resize(rng.random((H // 16, W // 16)).astype(np.float32), (W, H),
                     interpolation=cv2.INTER_CUBIC)
    for _ in range(80):
        x, y = int(rng.integers(0, W)), int(rng.integers(0, H))
        s = int(rng.integers(6, 36))
        v = float(rng.random())
        if rng.random() < 0.5:
            cv2.rectangle(img, (x, y), (x + s, y + s // 2), v, -1)
        else:
            cv2.circle(img, (x, y), s // 2, v, 2)
    return np.clip(img, 0.0, 1.0)


def _write_dpx(path, gray):
    rgb = np.repeat(gray[:, :, None], 3, axis=2).astype(np.float32)
    out = oiio.ImageOutput.create(path)
    if out is None or not out.open(path, oiio.ImageSpec(W, H, 3, oiio.UINT16)):
        raise RuntimeError(f"cannot write {path}: {oiio.geterror()}")
    out.write_image(rgb)
    out.close()


def _write_ocio_config(path):
    # forge-io always converts to working_space="sRGB"; an identity config
    # with "raw" (source) and "sRGB" (target) is enough for the solver.
    cfg = ocio.Config.CreateRaw()
    cfg.addColorSpace(ocio.ColorSpace(name="sRGB"))
    with open(path, "w") as f:
        f.write(cfg.serialize())


def _solve(source, ref, ref_frame, detector, env):
    cmd = [
        sys.executable, "-m", "forge_cv.cli_solve",
        "--source", source, "--source-frames", str(FRAME),
        "--ref", ref, "--ref-frames", str(ref_frame),
        "--source-width", str(W), "--source-height", str(H),
        "--output-width", str(W), "--output-height", str(H),
        "--detector", detector, "--mode", "similarity",
        "--source-cs", "raw", "--ref-cs", "raw",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=300)
    lines = [ln for ln in proc.stdout.strip().splitlines() if ln.startswith("{")]
    if proc.returncode != 0 or not lines:
        raise RuntimeError(f"cli_solve exit {proc.returncode}\n{proc.stdout}\n{proc.stderr}")
    result = json.loads(lines[-1])
    if "error" in result:
        raise RuntimeError(result["error"])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--keep", action="store_true", help="keep the temp dir")
    args = parser.parse_args()

    tmp = tempfile.mkdtemp(prefix="forge_cv_smoke_")
    failures = []
    try:
        plate = _texture()
        m = cv2.getRotationMatrix2D((W / 2, H / 2), ANGLE_DEG, SCALE)
        m[:, 2] += SHIFT
        ref = cv2.warpAffine(plate, m, (W, H), flags=cv2.INTER_LINEAR,
                             borderMode=cv2.BORDER_REFLECT)

        plate_pat = os.path.join(tmp, "plate.%04d.dpx")
        ref_pat = os.path.join(tmp, "ref.%04d.dpx")
        _write_dpx(plate_pat % FRAME, plate)
        _write_dpx(ref_pat % FRAME, ref)

        env = os.environ.copy()
        env["OCIO"] = os.path.join(tmp, "config.ocio")
        _write_ocio_config(env["OCIO"])

        cases = [("sift", ref_pat, FRAME)]

        ffmpeg = os.path.join(os.path.dirname(sys.executable), "ffmpeg")
        if not os.path.exists(ffmpeg):
            ffmpeg = shutil.which("ffmpeg")
        if ffmpeg:
            mov = os.path.join(tmp, "ref.mov")
            subprocess.run(
                [ffmpeg, "-v", "error", "-y", "-start_number", str(FRAME), "-i", ref_pat,
                 "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", mov],
                check=True,
            )
            cases.append(("sift", mov, 0))
        else:
            failures.append("ffmpeg not found — container decode untested")

        try:
            import torch  # noqa: F401
            from lightglue import SuperPoint  # noqa: F401
            cases.append(("superpoint", ref_pat, FRAME))
        except ImportError:
            print("  (SuperPoint not installed — skipped)")

        for detector, ref_path, ref_frame in cases:
            label = f"{detector} vs {os.path.basename(ref_path)}"
            try:
                r = _solve(plate_pat, ref_path, ref_frame, detector, env)
            except Exception as e:  # noqa: BLE001
                failures.append(f"{label}: {e}")
                print(f"  FAIL {label}: {e}")
                continue
            # Flame reports scaling in percent and rotation in degrees.
            scale_ok = abs(r["scaling_x"] - SCALE * 100) < 1.0
            rot_ok = abs(abs(r["rotation_z"]) - ANGLE_DEG) < 0.5
            status = "ok  " if (scale_ok and rot_ok) else "FAIL"
            print(f"  {status} {label}: conf={r['confidence']:.2f} "
                  f"scale={r['scaling_x']:.2f}% rot={r['rotation_z']:.2f}deg "
                  f"pos=({r['position_x']:.1f}, {r['position_y']:.1f})")
            if not (scale_ok and rot_ok):
                failures.append(f"{label}: transform off (expected {SCALE * 100}% / {ANGLE_DEG}deg)")
    finally:
        if args.keep:
            print(f"  temp dir kept: {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("\n".join(["Self-test FAILED:"] + [f"  - {f}" for f in failures]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
