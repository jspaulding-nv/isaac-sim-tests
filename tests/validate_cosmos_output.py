#!/usr/bin/env python3
"""Validate the deterministic output contract of cosmos_writer_simple.py."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image


EXPECTED_FRAMES = 60
EXPECTED_SIZE = (1280, 720)
SAMPLE_INDICES = (0, 10, 20, 30, 40, 50, 59)
VIDEO_COMPARE_INDICES = (0, 30, 59)
MAX_VIDEO_PNG_MAE = 35.0
MIN_EDGE_BOUNDARY_OVERLAP = 0.25
MODALITIES = {
    "rgb": "rgb",
    "shaded_seg": "shaded_seg",
    "segmentation": "segmentation",
    "depth": "depth",
    "edges": "edges",
}
SEMANTIC_COLORS = {
    "plane": (0, 0, 255),
    "cube": (255, 0, 0),
    "sphere": (0, 255, 0),
}


def pixel_digest(array: np.ndarray) -> str:
    return hashlib.sha256(np.ascontiguousarray(array).tobytes()).hexdigest()


def load_rgb(path: Path) -> np.ndarray:
    with Image.open(path) as image:
        return np.asarray(image.convert("RGB"))


def fourcc_string(value: float) -> str:
    code = int(value)
    return "".join(chr((code >> (8 * index)) & 0xFF) for index in range(4)).rstrip("\x00")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--result", required=True, type=Path)
    args = parser.parse_args()

    output_root = args.output_root
    clip_root = output_root / "clip_0000"
    errors: list[str] = []
    warnings: list[str] = []
    metrics: dict[str, Any] = {
        "expected_frames": EXPECTED_FRAMES,
        "expected_size": {"width": EXPECTED_SIZE[0], "height": EXPECTED_SIZE[1]},
        "modalities": {},
        "videos": {},
    }

    all_pngs = sorted(output_root.rglob("*.png")) if output_root.exists() else []
    all_mp4s = sorted(output_root.rglob("*.mp4")) if output_root.exists() else []
    if len(all_pngs) != EXPECTED_FRAMES * len(MODALITIES):
        errors.append(f"Expected 300 PNG files, found {len(all_pngs)}")
    if len(all_mp4s) != len(MODALITIES):
        errors.append(f"Expected 5 MP4 files, found {len(all_mp4s)}")

    decoded_pngs: dict[str, dict[int, np.ndarray]] = {}
    for modality, prefix in MODALITIES.items():
        modality_dir = clip_root / modality
        expected_names = [f"{prefix}_{index:04d}.png" for index in range(EXPECTED_FRAMES)]
        actual_names = sorted(path.name for path in modality_dir.glob("*.png")) if modality_dir.exists() else []
        missing = sorted(set(expected_names) - set(actual_names))
        unexpected = sorted(set(actual_names) - set(expected_names))
        if missing:
            errors.append(f"{modality}: missing {len(missing)} PNGs; first={missing[:3]}")
        if unexpected:
            errors.append(f"{modality}: unexpected PNG names; first={unexpected[:3]}")

        sampled: dict[int, np.ndarray] = {}
        sampled_hashes: list[str] = []
        sampled_ranges: list[int] = []
        decode_failures: list[str] = []
        wrong_sizes: list[str] = []
        empty_files: list[str] = []
        for index, name in enumerate(expected_names):
            path = modality_dir / name
            if not path.exists():
                continue
            if path.stat().st_size == 0:
                empty_files.append(name)
                continue
            image = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
            if image is None:
                decode_failures.append(name)
                continue
            if (image.shape[1], image.shape[0]) != EXPECTED_SIZE:
                wrong_sizes.append(f"{name}:{image.shape[1]}x{image.shape[0]}")
            if index in SAMPLE_INDICES:
                rgb = load_rgb(path)
                sampled[index] = rgb
                sampled_hashes.append(pixel_digest(rgb))
                sampled_ranges.append(int(np.ptp(rgb)))

        if empty_files:
            errors.append(f"{modality}: {len(empty_files)} empty PNGs")
        if decode_failures:
            errors.append(f"{modality}: {len(decode_failures)} PNG decode failures")
        if wrong_sizes:
            errors.append(f"{modality}: wrong PNG dimensions; first={wrong_sizes[:3]}")
        if len(sampled) != len(SAMPLE_INDICES):
            errors.append(f"{modality}: only {len(sampled)}/{len(SAMPLE_INDICES)} sampled PNGs decoded")
        elif len(set(sampled_hashes)) < 2:
            errors.append(f"{modality}: sampled PNGs are pixel-identical")
        if sampled_ranges and max(sampled_ranges) == 0:
            errors.append(f"{modality}: sampled PNGs are blank/constant")

        decoded_pngs[modality] = sampled
        metrics["modalities"][modality] = {
            "png_count": len(actual_names),
            "sample_unique_pixel_hashes": len(set(sampled_hashes)),
            "sample_max_pixel_range": max(sampled_ranges) if sampled_ranges else None,
        }

    class_pixel_max: dict[str, int] = {name: 0 for name in SEMANTIC_COLORS}
    boundary_overlap_values: list[float] = []
    for index in SAMPLE_INDICES:
        semantic = decoded_pngs.get("segmentation", {}).get(index)
        edges_rgb = decoded_pngs.get("edges", {}).get(index)
        if semantic is None or edges_rgb is None:
            continue
        for class_name, color in SEMANTIC_COLORS.items():
            count = int(np.count_nonzero(np.all(semantic == np.asarray(color, dtype=np.uint8), axis=2)))
            class_pixel_max[class_name] = max(class_pixel_max[class_name], count)

        horizontal = np.any(semantic[:, 1:, :] != semantic[:, :-1, :], axis=2)
        vertical = np.any(semantic[1:, :, :] != semantic[:-1, :, :], axis=2)
        boundary = np.zeros(semantic.shape[:2], dtype=np.uint8)
        boundary[:, 1:] |= horizontal
        boundary[:, :-1] |= horizontal
        boundary[1:, :] |= vertical
        boundary[:-1, :] |= vertical
        boundary = cv2.dilate(boundary, np.ones((5, 5), dtype=np.uint8), iterations=1).astype(bool)
        edge_gray = cv2.cvtColor(edges_rgb, cv2.COLOR_RGB2GRAY)
        edge_mask = edge_gray > 8
        edge_count = int(np.count_nonzero(edge_mask))
        if edge_count:
            boundary_overlap_values.append(float(np.count_nonzero(edge_mask & boundary) / edge_count))

    missing_colors = [name for name, count in class_pixel_max.items() if count == 0]
    if missing_colors:
        errors.append(f"Semantic mapping colors not observed for: {', '.join(missing_colors)}")
    if not boundary_overlap_values:
        errors.append("No edge pixels were available for segmentation/edge alignment checks")
    elif min(boundary_overlap_values) < MIN_EDGE_BOUNDARY_OVERLAP:
        errors.append(
            "Segmentation/edge boundary overlap fell below "
            f"{MIN_EDGE_BOUNDARY_OVERLAP:.2f}: min={min(boundary_overlap_values):.3f}"
        )
    metrics["semantic_class_max_pixels"] = class_pixel_max
    metrics["edge_boundary_overlap"] = {
        "minimum": min(boundary_overlap_values) if boundary_overlap_values else None,
        "mean": float(np.mean(boundary_overlap_values)) if boundary_overlap_values else None,
        "threshold": MIN_EDGE_BOUNDARY_OVERLAP,
    }

    for modality, prefix in MODALITIES.items():
        video_path = clip_root / f"{modality}.mp4"
        video_metrics: dict[str, Any] = {"path": str(video_path)}
        metrics["videos"][modality] = video_metrics
        if not video_path.exists():
            errors.append(f"{modality}: MP4 is missing")
            continue
        if video_path.stat().st_size == 0:
            errors.append(f"{modality}: MP4 is empty")
            continue

        capture = cv2.VideoCapture(str(video_path))
        if not capture.isOpened():
            errors.append(f"{modality}: MP4 could not be opened")
            continue
        metadata_count = int(round(capture.get(cv2.CAP_PROP_FRAME_COUNT)))
        width = int(round(capture.get(cv2.CAP_PROP_FRAME_WIDTH)))
        height = int(round(capture.get(cv2.CAP_PROP_FRAME_HEIGHT)))
        fps = float(capture.get(cv2.CAP_PROP_FPS))
        codec = fourcc_string(capture.get(cv2.CAP_PROP_FOURCC))
        decoded_count = 0
        decoded_samples: dict[int, np.ndarray] = {}
        while True:
            ok, frame = capture.read()
            if not ok:
                break
            if decoded_count in SAMPLE_INDICES:
                decoded_samples[decoded_count] = frame.copy()
            decoded_count += 1
        capture.release()

        if metadata_count != EXPECTED_FRAMES:
            errors.append(f"{modality}: MP4 metadata reports {metadata_count} frames")
        if decoded_count != EXPECTED_FRAMES:
            errors.append(f"{modality}: MP4 decoded {decoded_count} frames")
        if (width, height) != EXPECTED_SIZE:
            errors.append(f"{modality}: MP4 dimensions are {width}x{height}")
        if fps <= 0:
            errors.append(f"{modality}: MP4 reports invalid frame rate {fps}")
        if not codec:
            errors.append(f"{modality}: MP4 reports an empty codec identifier")

        video_hashes = [pixel_digest(frame) for frame in decoded_samples.values()]
        if len(decoded_samples) == len(SAMPLE_INDICES) and len(set(video_hashes)) < 2:
            errors.append(f"{modality}: sampled MP4 frames are pixel-identical")

        comparison_mae: dict[str, float] = {}
        for index in VIDEO_COMPARE_INDICES:
            frame = decoded_samples.get(index)
            png_path = clip_root / modality / f"{prefix}_{index:04d}.png"
            png = cv2.imread(str(png_path), cv2.IMREAD_COLOR) if png_path.exists() else None
            if frame is None or png is None or frame.shape != png.shape:
                errors.append(f"{modality}: cannot compare MP4 frame {index} with its PNG")
                continue
            mae = float(np.mean(np.abs(frame.astype(np.int16) - png.astype(np.int16))))
            comparison_mae[str(index)] = mae
            if mae > MAX_VIDEO_PNG_MAE:
                errors.append(
                    f"{modality}: MP4/PNG mean absolute error {mae:.2f} exceeds {MAX_VIDEO_PNG_MAE:.2f} at frame {index}"
                )

        video_metrics.update(
            {
                "file_size_bytes": video_path.stat().st_size,
                "metadata_frame_count": metadata_count,
                "decoded_frame_count": decoded_count,
                "width": width,
                "height": height,
                "fps": fps,
                "codec": codec,
                "sample_unique_pixel_hashes": len(set(video_hashes)),
                "png_comparison_mae": comparison_mae,
            }
        )

    result = {
        "status": "PASS" if not errors else "FAIL",
        "output_root": str(output_root),
        "png_count": len(all_pngs),
        "mp4_count": len(all_mp4s),
        "errors": errors,
        "warnings": warnings,
        "metrics": metrics,
    }
    args.result.parent.mkdir(parents=True, exist_ok=True)
    args.result.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    print(f"T5_OUTPUT_VALIDATION_{result['status']}", flush=True)
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
