#!/usr/bin/env python3
"""Run one deterministic stage of the T4 tiled-camera progression."""

from __future__ import annotations

import argparse
import colorsys
import faulthandler
import hashlib
import json
import math
import os
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path

import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage-id", required=True)
    parser.add_argument("--mode", choices=("single", "tiled"), required=True)
    parser.add_argument("--cameras", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--frames", type=int, required=True)
    parser.add_argument("--warmup-frames", type=int, default=30)
    parser.add_argument("--watchdog-seconds", type=int, default=120)
    parser.add_argument("--startup-watchdog-seconds", type=int, default=420)
    parser.add_argument("--seed", type=int, default=20260721)
    parser.add_argument("--output-dir", type=Path, required=True)
    args, _ = parser.parse_known_args()
    if args.mode == "single" and args.cameras != 1:
        parser.error("single mode requires exactly one camera")
    for name in ("cameras", "height", "width", "frames", "warmup_frames"):
        if getattr(args, name) < 1:
            parser.error(f"--{name.replace('_', '-')} must be positive")
    return args


ARGS = parse_args()
ARGS.output_dir.mkdir(parents=True, exist_ok=True)
RESULT_PATH = ARGS.output_dir / "result.json"
HEARTBEAT_PATH = ARGS.output_dir / "heartbeat.json"
STARTED_AT = datetime.now(timezone.utc)
RESULT: dict[str, object] = {
    "test_id": "T4",
    "stage_id": ARGS.stage_id,
    "test_name": "Tiled-camera progression",
    "started_at_utc": STARTED_AT.isoformat(),
    "status": "ERROR",
    "parameters": {
        "mode": ARGS.mode,
        "camera_count": ARGS.cameras,
        "resolution_height": ARGS.height,
        "resolution_width": ARGS.width,
        "target_frames": ARGS.frames,
        "warmup_frames": ARGS.warmup_frames,
        "seed": ARGS.seed,
        "headless": True,
        "annotators": ["rgb"],
        "no_progress_watchdog_s": ARGS.watchdog_seconds,
    },
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_json_atomic(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def write_result() -> None:
    write_json_atomic(RESULT_PATH, RESULT)


def arm_watchdog(seconds: int) -> None:
    faulthandler.cancel_dump_traceback_later()
    faulthandler.dump_traceback_later(seconds, repeat=False, exit=True)


def heartbeat(phase: str, frame: int = 0, **details: object) -> None:
    write_json_atomic(
        HEARTBEAT_PATH,
        {
            "stage_id": ARGS.stage_id,
            "phase": phase,
            "completed_frames": frame,
            "updated_at_utc": utc_now(),
            **details,
        },
    )


faulthandler.enable(all_threads=True)
arm_watchdog(ARGS.startup_watchdog_seconds)
heartbeat("starting_simulation_app")
write_result()

from isaacsim import SimulationApp


simulation_app = SimulationApp(
    {
        "fast_shutdown": True,
        "headless": True,
        "hide_ui": True,
        "width": 640,
        "height": 480,
    }
)


def make_cube(stage: object, path: str, position: tuple[float, float, float], scale: tuple[float, float, float], color: tuple[float, float, float]) -> object:
    from pxr import Gf, UsdGeom

    cube = UsdGeom.Cube.Define(stage, path)
    cube.CreateSizeAttr(1.0)
    cube.CreateDisplayColorAttr([Gf.Vec3f(*color)])
    xform = UsdGeom.Xformable(cube.GetPrim())
    translate = xform.AddTranslateOp()
    translate.Set(Gf.Vec3d(*position))
    xform.AddScaleOp().Set(Gf.Vec3f(*scale))
    return translate


def short_hash(array: np.ndarray) -> str:
    return hashlib.blake2b(array.tobytes(), digest_size=8).hexdigest()


def image_stats(batch: np.ndarray) -> list[dict[str, object]]:
    stats: list[dict[str, object]] = []
    for camera_id, frame in enumerate(batch):
        stats.append(
            {
                "camera_id": camera_id,
                "hash": short_hash(frame),
                "mean": float(np.mean(frame)),
                "stddev": float(np.std(frame)),
                "nonzero_fraction": float(np.count_nonzero(frame) / frame.size),
            }
        )
    return stats


def save_rgb(path: Path, frame: np.ndarray) -> None:
    from PIL import Image

    Image.fromarray(frame.astype(np.uint8), mode="RGB").save(path)


EXIT_CODE = 1
try:
    import isaacsim.core.experimental.utils.app as app_utils
    import isaacsim.core.experimental.utils.stage as stage_utils
    import omni.replicator.core as rep
    import omni.timeline
    from isaacsim.core.experimental.objects import DomeLight, GroundPlane
    from isaacsim.core.rendering_manager import ViewportManager
    from isaacsim.sensors.experimental.rtx import CameraSensor, RtxCamera, TiledCameraSensor
    from pxr import Gf

    heartbeat("authoring_scene")
    stage_utils.create_new_stage()
    stage_utils.define_prim("/World", type_name="Xform")
    stage_utils.define_prim("/World/Cameras", type_name="Xform")
    stage_utils.define_prim("/World/Environments", type_name="Xform")
    stage = stage_utils.get_current_stage(backend="usd")

    grid_columns = math.ceil(math.sqrt(ARGS.cameras))
    grid_rows = math.ceil(ARGS.cameras / grid_columns)
    spacing = 6.0
    scene_width = max(grid_columns, grid_rows) * spacing + 8.0
    GroundPlane("/World/GroundPlane", sizes=scene_width)
    light = DomeLight("/World/DomeLight")
    light.set_intensities(1200)

    camera_paths: list[str] = []
    camera_objects: list[object] = []
    moving_ops: list[object] = []
    centers: list[tuple[float, float]] = []
    rng = np.random.default_rng(ARGS.seed)

    for index in range(ARGS.cameras):
        column = index % grid_columns
        row = index // grid_columns
        center_x = (column - (grid_columns - 1) / 2.0) * spacing
        center_y = (row - (grid_rows - 1) / 2.0) * spacing
        centers.append((center_x, center_y))
        env_path = f"/World/Environments/env_{index:03d}"
        stage_utils.define_prim(env_path, type_name="Xform")

        hue = index / max(1, ARGS.cameras)
        accent = colorsys.hsv_to_rgb(hue, 0.78, 0.92)
        floor_tint = tuple(0.16 + channel * 0.18 for channel in accent)
        make_cube(
            stage,
            f"{env_path}/Zone",
            (center_x, center_y, 0.04),
            (2.35, 2.35, 0.08),
            floor_tint,
        )
        moving_ops.append(
            make_cube(
                stage,
                f"{env_path}/MovingTarget",
                (center_x, center_y, 0.45),
                (0.65, 0.65, 0.90),
                accent,
            )
        )

        # The asymmetric landmark pattern makes camera overrides and duplicate
        # frames detectable without relying on text rendering.
        for marker in range(3):
            marker_color = [0.12, 0.12, 0.12]
            marker_color[(index + marker) % 3] = 0.95
            offset_x = -1.35 + marker * 1.25
            offset_y = 1.15 - 0.22 * ((index >> marker) & 1)
            height = 0.25 + 0.10 * ((index + marker) % 4)
            make_cube(
                stage,
                f"{env_path}/Marker_{marker}",
                (center_x + offset_x, center_y + offset_y, height / 2.0 + 0.09),
                (0.32, 0.32, height),
                tuple(marker_color),
            )

        camera_path = f"/World/Cameras/camera_{index:03d}"
        camera_paths.append(camera_path)
        camera_objects.append(RtxCamera(camera_path, tick_rate=30.0))

    simulation_app.update()
    for index, camera_path in enumerate(camera_paths):
        center_x, center_y = centers[index]
        eye_jitter = float(rng.uniform(-0.12, 0.12))
        ViewportManager.set_camera_view(
            camera_path,
            eye=[center_x + 3.4 + eye_jitter, center_y - 3.8, 3.5],
            target=[center_x, center_y, 0.35],
        )

    resolution = (ARGS.height, ARGS.width)
    if ARGS.mode == "single":
        sensor = CameraSensor(camera_objects[0], resolution=resolution, annotators=["rgb"])
    else:
        sensor = TiledCameraSensor(
            "/World/Cameras/camera_.*",
            resolution=resolution,
            annotators=["rgb"],
        )

    sensor_details = {
        "sensor_class": type(sensor).__name__,
        "camera_count": 1 if ARGS.mode == "single" else len(sensor),
        "per_camera_resolution": list(resolution),
        "render_product_path": str(sensor.render_product.GetPath()),
    }
    if ARGS.mode == "tiled":
        sensor_details["tiled_resolution"] = list(sensor.tiled_resolution)
    RESULT["sensor"] = sensor_details
    if sensor_details["camera_count"] != ARGS.cameras:
        raise RuntimeError(f"Sensor matched {sensor_details['camera_count']} cameras, expected {ARGS.cameras}")
    print("T4_SENSOR " + json.dumps(sensor_details, sort_keys=True), flush=True)

    stage.Export(str(ARGS.output_dir / "stage.usda"))
    rep.orchestrator.preview()
    timeline = omni.timeline.get_timeline_interface()
    app_utils.play(commit=True)

    heartbeat("warming_up")
    first_data = None
    warmup_updates = 0
    max_warmup_updates = max(ARGS.warmup_frames * 4, 120)
    while warmup_updates < max_warmup_updates:
        simulation_app.update()
        warmup_updates += 1
        data, _ = sensor.get_data("rgb")
        if data is not None and warmup_updates >= ARGS.warmup_frames:
            first_data = data
            break
        if warmup_updates % 10 == 0:
            heartbeat("warming_up", warmup_updates=warmup_updates)
            arm_watchdog(ARGS.startup_watchdog_seconds)
    if first_data is None:
        raise RuntimeError(f"No RGB data after {warmup_updates} warm-up updates")

    (ARGS.output_dir / "capture_started_at_utc.txt").write_text(utc_now() + "\n", encoding="utf-8")
    arm_watchdog(ARGS.watchdog_seconds)
    heartbeat("capturing", 0)
    expected_batch_shape = (ARGS.cameras, ARGS.height, ARGS.width, 3)
    snapshots_at = {0, ARGS.frames // 2, ARGS.frames - 1}
    snapshot_stats: dict[str, list[dict[str, object]]] = {}
    snapshot_tiled_shapes: dict[str, list[int]] = {}
    sampled_frame_hashes: list[str] = []
    sample_interval = max(1, ARGS.frames // 20)
    missed_frames = 0
    completed_frames = 0
    frame_started = time.perf_counter()

    while completed_frames < ARGS.frames:
        phase = 2.0 * math.pi * completed_frames / 113.0
        for index, translate_op in enumerate(moving_ops):
            center_x, center_y = centers[index]
            offset_x = 0.82 * math.sin(phase + index * 0.17)
            offset_y = 0.42 * math.cos(phase * 0.73 + index * 0.11)
            translate_op.Set(Gf.Vec3d(center_x + offset_x, center_y + offset_y, 0.45))

        simulation_app.update()
        data, _ = sensor.get_data("rgb")
        if data is None:
            missed_frames += 1
            continue

        batch = data.numpy()
        if ARGS.mode == "single":
            batch = batch[np.newaxis, ...]
        if tuple(batch.shape) != expected_batch_shape:
            raise RuntimeError(f"RGB batch shape {batch.shape} != {expected_batch_shape}")

        if completed_frames % sample_interval == 0 or completed_frames == ARGS.frames - 1:
            sampled_frame_hashes.append(short_hash(batch))

        if completed_frames in snapshots_at:
            label = f"frame_{completed_frames:04d}"
            snapshot_stats[label] = image_stats(batch)
            if ARGS.mode == "tiled":
                tiled_data, _ = sensor.get_data("rgb", tiled=True)
                if tiled_data is None:
                    raise RuntimeError(f"Tiled RGB unavailable at frame {completed_frames}")
                tiled_np = tiled_data.numpy()
            else:
                tiled_np = batch[0]
            snapshot_tiled_shapes[label] = list(tiled_np.shape)
            save_rgb(ARGS.output_dir / f"{label}_rgb_tiled.png", tiled_np)

        completed_frames += 1
        if completed_frames == 1 or completed_frames % max(1, ARGS.frames // 10) == 0:
            elapsed = time.perf_counter() - frame_started
            print(
                f"T4_PROGRESS stage={ARGS.stage_id} frames={completed_frames}/{ARGS.frames} "
                f"rate={completed_frames / max(elapsed, 1e-9):.2f}_fps",
                flush=True,
            )
        heartbeat("capturing", completed_frames, missed_frames=missed_frames)
        arm_watchdog(ARGS.watchdog_seconds)

    frame_elapsed_s = time.perf_counter() - frame_started
    first_stats = snapshot_stats["frame_0000"]
    final_label = f"frame_{ARGS.frames - 1:04d}"
    final_stats = snapshot_stats[final_label]
    unique_final_hashes = len({item["hash"] for item in final_stats})
    changed_camera_count = sum(
        first["hash"] != final["hash"] for first, final in zip(first_stats, final_stats, strict=True)
    )
    nonblank_camera_count = sum(
        item["stddev"] >= 2.0 and item["nonzero_fraction"] >= 0.05 for item in final_stats
    )
    unique_sampled_frames = len(set(sampled_frame_hashes))
    required_cameras = max(1, math.ceil(ARGS.cameras * 0.95))
    required_sampled_frames = max(1, math.ceil(len(sampled_frame_hashes) * 0.90))

    expected_tiled_shape = None
    if ARGS.mode == "tiled":
        expected_tiled_shape = [*sensor.tiled_resolution, 3]
    else:
        expected_tiled_shape = [ARGS.height, ARGS.width, 3]

    checks = {
        "all_target_frames_delivered": completed_frames == ARGS.frames,
        "camera_count_matches": sensor_details["camera_count"] == ARGS.cameras,
        "all_final_camera_frames_nonblank": nonblank_camera_count == ARGS.cameras,
        "at_least_95_percent_final_camera_frames_distinct": unique_final_hashes >= required_cameras,
        "at_least_95_percent_cameras_changed": changed_camera_count >= required_cameras,
        "at_least_90_percent_sampled_frames_unique": unique_sampled_frames >= required_sampled_frames,
        "all_snapshot_tiled_shapes_match": all(
            shape == expected_tiled_shape for shape in snapshot_tiled_shapes.values()
        ),
    }
    metrics = {
        "completed_frames": completed_frames,
        "missed_frames_after_warmup": missed_frames,
        "warmup_updates": warmup_updates,
        "capture_wall_time_s": frame_elapsed_s,
        "delivered_frame_rate_hz": completed_frames / frame_elapsed_s,
        "total_rendered_pixels_per_frame": ARGS.cameras * ARGS.height * ARGS.width,
        "sampled_frame_count": len(sampled_frame_hashes),
        "unique_sampled_frame_count": unique_sampled_frames,
        "unique_final_camera_hashes": unique_final_hashes,
        "changed_camera_count": changed_camera_count,
        "nonblank_camera_count": nonblank_camera_count,
        "snapshot_tiled_shapes": snapshot_tiled_shapes,
    }
    RESULT["metrics"] = metrics
    RESULT["snapshot_camera_stats"] = snapshot_stats
    RESULT["checks"] = checks
    RESULT["status"] = "PASS" if all(checks.values()) else "FAIL"
    RESULT["finished_at_utc"] = utc_now()
    write_result()
    print("T4_METRICS " + json.dumps(metrics, sort_keys=True), flush=True)
    print("T4_CHECKS " + json.dumps(checks, sort_keys=True), flush=True)
    print(f"T4_RESULT stage={ARGS.stage_id} status={RESULT['status']}", flush=True)
    EXIT_CODE = 0 if RESULT["status"] == "PASS" else 2
except Exception as exc:
    EXIT_CODE = 1
    RESULT["status"] = "ERROR"
    RESULT["error"] = {
        "type": type(exc).__name__,
        "message": str(exc),
        "traceback": traceback.format_exc(),
    }
    RESULT["finished_at_utc"] = utc_now()
    write_result()
    heartbeat("error", error=f"{type(exc).__name__}: {exc}")
    print(f"T4_RESULT stage={ARGS.stage_id} status=ERROR", flush=True)
    traceback.print_exc()
finally:
    faulthandler.cancel_dump_traceback_later()
    teardown = {
        "mode": "process-exit",
        "status": "FRAMEWORK_SHUTDOWN_BYPASSED",
        "timeline_stop": "NOT_ATTEMPTED",
        "stage_close": "NOT_ATTEMPTED",
        "reason": "T2 established a native Kit shutdown hang; T4 uses the documented one-shot exit path.",
    }
    try:
        if "timeline" in locals():
            timeline.stop()
            simulation_app.update()
            teardown["timeline_stop"] = "COMPLETE"
        if simulation_app.context.can_close_stage():
            simulation_app.context.close_stage()
            teardown["stage_close"] = "COMPLETE"
        else:
            teardown["stage_close"] = "NOT_CLOSABLE"
    except Exception as exc:
        teardown["cleanup_error"] = f"{type(exc).__name__}: {exc}"
    RESULT["teardown"] = teardown
    RESULT["finished_at_utc"] = utc_now()
    write_result()
    heartbeat("finished", RESULT.get("metrics", {}).get("completed_frames", 0), status=RESULT["status"])
    print("T4_TEARDOWN " + json.dumps(teardown, sort_keys=True), flush=True)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(EXIT_CODE)
