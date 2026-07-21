#!/usr/bin/env python3
"""Run the T5 CosmosWriter control inside an already-running Kit app."""

from __future__ import annotations

import asyncio
import json
import os
import traceback
from pathlib import Path
from typing import Any

import carb.settings
import omni.kit.app
import omni.replicator.core as rep
import omni.timeline
import omni.usd


SEGMENTATION_MAPPING = {
    "plane": [0, 0, 255, 255],
    "cube": [255, 0, 0, 255],
    "sphere": [0, 255, 0, 255],
}
NUM_FRAMES = 60
RESOLUTION = (1280, 720)
MODALITIES = ("rgb", "shaded_seg", "segmentation", "depth", "edges")
OUTPUT_DIR = Path(os.environ.get("T5C_OUTPUT_DIR", "/results/workdir/_out_cosmos_simple"))
BUILTIN_RESULT = Path(os.environ.get("T5C_BUILTIN_RESULT", "/results/builtin_validation.json"))


def validate_output_counts(output_dir: Path) -> dict[str, Any]:
    clip_dir = output_dir / "clip_0000"
    errors: list[str] = []
    png_counts: dict[str, int] = {}

    for modality in MODALITIES:
        modality_dir = clip_dir / modality
        expected = {f"{modality}_{index:04d}.png" for index in range(NUM_FRAMES)}
        actual = {path.name for path in modality_dir.glob("*.png")} if modality_dir.exists() else set()
        png_counts[modality] = len(actual)
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        if missing:
            errors.append(f"{modality}: missing {len(missing)} PNGs; first={missing[:3]}")
        if unexpected:
            errors.append(f"{modality}: unexpected PNGs; first={unexpected[:3]}")

    expected_videos = {f"{modality}.mp4" for modality in MODALITIES}
    actual_videos = {path.name for path in clip_dir.glob("*.mp4")} if clip_dir.exists() else set()
    empty_files = [str(path) for path in output_dir.rglob("*") if path.is_file() and path.stat().st_size == 0]
    if actual_videos != expected_videos:
        errors.append(
            f"MP4 set mismatch: missing={sorted(expected_videos - actual_videos)}, "
            f"unexpected={sorted(actual_videos - expected_videos)}"
        )
    if empty_files:
        errors.append(f"Empty output files: {empty_files[:5]}")

    return {
        "status": "PASS" if not errors else "FAIL",
        "output_dir": str(output_dir),
        "expected_frames": NUM_FRAMES,
        "png_counts": png_counts,
        "png_total": sum(png_counts.values()),
        "mp4_count": len(actual_videos),
        "errors": errors,
    }


async def run_t5c() -> None:
    timeline = None
    cosmos_writer = None
    render_product = None
    try:
        config = {
            "test_id": "T5-C",
            "execution_surface": "Isaac Sim Full Streaming App",
            "frames": NUM_FRAMES,
            "resolution": list(RESOLUTION),
            "modalities": list(MODALITIES),
            "output_dir": str(OUTPUT_DIR),
            "segmentation_mapping": SEGMENTATION_MAPPING,
        }
        print("T5C_CONFIG " + json.dumps(config, sort_keys=True), flush=True)

        OUTPUT_DIR.parent.mkdir(parents=True, exist_ok=True)
        if OUTPUT_DIR.exists() and any(OUTPUT_DIR.iterdir()):
            raise RuntimeError(f"Refusing to use nonempty output directory: {OUTPUT_DIR}")

        await omni.usd.get_context().new_stage_async()
        carb.settings.get_settings().set("rtx/post/dlss/execMode", 2)
        carb.settings.get_settings().set_bool("/app/omni.graph.scriptnode/opt_in", True)
        rep.orchestrator.set_capture_on_play(False)
        rep.settings.set_stage_up_axis("Z")
        rep.settings.set_stage_meters_per_unit(1.0)
        rep.functional.create.dome_light(intensity=500)

        plane = rep.functional.create.plane(
            position=(0, 0, 0),
            scale=(10, 10, 1),
            semantics={"class": "plane"},
        )
        rep.functional.physics.apply_collider(plane)

        sphere = rep.functional.create.sphere(position=(0, 0, 3), semantics={"class": "sphere"})
        rep.functional.physics.apply_collider(sphere)
        rep.functional.physics.apply_rigid_body(sphere)

        cube = rep.functional.create.cube(
            position=(1, 1, 2),
            scale=0.5,
            semantics={"class": "cube"},
        )
        rep.functional.physics.apply_collider(cube)
        rep.functional.physics.apply_rigid_body(cube)

        camera = rep.functional.create.camera(position=(5, 5, 3), look_at=(0, 0, 0))
        render_product = rep.create.render_product(camera, RESOLUTION)
        backend = rep.backends.get("DiskBackend")
        backend.initialize(output_dir=str(OUTPUT_DIR))
        cosmos_writer = rep.WriterRegistry.get("CosmosWriter")
        cosmos_writer.initialize(backend=backend, segmentation_mapping=SEGMENTATION_MAPPING)
        cosmos_writer.attach(render_product)

        timeline = omni.timeline.get_timeline_interface()
        timeline.play()
        print("T5C_RUN_STARTED", flush=True)

        app = omni.kit.app.get_app()
        for index in range(NUM_FRAMES):
            frame = index + 1
            print(f"T5C_FRAME_REQUEST frame={frame}/{NUM_FRAMES}", flush=True)
            # This is the in-Kit equivalent of the example's simulation_app.update().
            await app.next_update_async()
            await rep.orchestrator.step_async(delta_time=0.0, pause_timeline=False)
            print(f"T5C_FRAME_COMPLETE frame={frame}/{NUM_FRAMES}", flush=True)

        timeline.pause()
        print("T5C_WRITER_DRAIN_STARTED", flush=True)
        await rep.orchestrator.wait_until_complete_async()
        print("T5C_WRITER_DRAIN_COMPLETE", flush=True)

        builtin_result = validate_output_counts(OUTPUT_DIR)
        BUILTIN_RESULT.write_text(
            json.dumps(builtin_result, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        if builtin_result["status"] != "PASS":
            print("T5C_BUILTIN_VALIDATION_FAIL " + json.dumps(builtin_result, sort_keys=True), flush=True)
            raise RuntimeError("T5-C output count validation failed")
        print("T5C_BUILTIN_VALIDATION_PASS " + json.dumps(builtin_result, sort_keys=True), flush=True)

        cosmos_writer.detach()
        cosmos_writer = None
        render_product.destroy()
        render_product = None
        await app.next_update_async()
        print(
            f"T5C_RUN_COMPLETE frames={NUM_FRAMES} png={NUM_FRAMES * len(MODALITIES)} mp4={len(MODALITIES)}",
            flush=True,
        )
    except Exception as error:
        print(f"T5C_RUN_FAIL type={type(error).__name__} message={error}", flush=True)
        traceback.print_exc()
    finally:
        if timeline is not None and timeline.is_playing():
            timeline.pause()
        if cosmos_writer is not None:
            try:
                cosmos_writer.detach()
            except Exception:
                print("T5C_CLEANUP_WRITER_ERROR", flush=True)
                traceback.print_exc()
        if render_product is not None:
            try:
                render_product.destroy()
            except Exception:
                print("T5C_CLEANUP_RENDER_PRODUCT_ERROR", flush=True)
                traceback.print_exc()


T5C_TASK = asyncio.ensure_future(run_t5c())
