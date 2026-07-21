#!/usr/bin/env python3
"""Run a deterministic, headless GPU PhysX rigid-body smoke workload."""

from __future__ import annotations

import argparse
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
    parser.add_argument("--bodies", type=int, default=1024)
    parser.add_argument("--steps", type=int, default=600)
    parser.add_argument("--seed", type=int, default=20260720)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--shutdown-mode",
        choices=("process-exit", "app-close"),
        default="process-exit",
    )
    args, _ = parser.parse_known_args()
    if args.bodies < 1:
        parser.error("--bodies must be positive")
    if args.steps < 1:
        parser.error("--steps must be positive")
    return args


ARGS = parse_args()
STARTED_AT = datetime.now(timezone.utc)
RESULT: dict[str, object] = {
    "test_id": "T2",
    "test_name": "GPU PhysX smoke",
    "started_at_utc": STARTED_AT.isoformat(),
    "status": "ERROR",
    "parameters": {
        "body_count": ARGS.bodies,
        "physics_steps": ARGS.steps,
        "physics_dt_s": 1.0 / 60.0,
        "seed": ARGS.seed,
        "box_dimensions_m": [0.50, 0.40, 0.30],
        "headless": True,
        "shutdown_mode": ARGS.shutdown_mode,
        "fast_shutdown": ARGS.shutdown_mode != "app-close",
    },
}


def write_result() -> None:
    ARGS.output.parent.mkdir(parents=True, exist_ok=True)
    ARGS.output.write_text(json.dumps(RESULT, indent=2, sort_keys=True) + "\n", encoding="utf-8")


from isaacsim import SimulationApp


simulation_app = SimulationApp(
    {
        "fast_shutdown": ARGS.shutdown_mode != "app-close",
        "headless": True,
        "hide_ui": True,
        "width": 640,
        "height": 480,
    }
)


EXIT_CODE = 1
try:
    import isaacsim.core.experimental.utils.app as app_utils
    import isaacsim.core.experimental.utils.stage as stage_utils
    from isaacsim.core.experimental.objects import Cube, GroundPlane
    from isaacsim.core.experimental.prims import GeomPrim, RigidPrim
    from isaacsim.core.simulation_manager import SimulationManager
    from pxr import Gf, PhysxSchema, UsdPhysics

    physics_dt = 1.0 / 60.0
    physics_scene_path = "/World/PhysicsScene"

    stage_utils.create_new_stage()
    stage_utils.define_prim("/World", type_name="Xform")
    stage = stage_utils.get_current_stage(backend="usd")
    physics_scene = UsdPhysics.Scene.Define(stage, physics_scene_path)
    physics_scene.CreateGravityDirectionAttr(Gf.Vec3f(0.0, 0.0, -1.0))
    physics_scene.CreateGravityMagnitudeAttr(9.81)
    PhysxSchema.PhysxSceneAPI.Apply(physics_scene.GetPrim())
    simulation_app.update()

    SimulationManager.set_default_physics_scene(physics_scene_path)
    SimulationManager.set_device("cuda:0")
    SimulationManager.set_physics_dt(physics_dt, physics_scene=physics_scene_path)
    SimulationManager.set_broadphase_type("GPU", physics_scene=physics_scene_path)
    SimulationManager.enable_gpu_dynamics(True, physics_scene=physics_scene_path)

    config = {
        "active_engine": SimulationManager.get_active_physics_engine(),
        "requested_device": "cuda:0",
        "device": str(SimulationManager.get_device()),
        "physics_sim_device": SimulationManager.get_physics_sim_device(),
        "broadphase_type": SimulationManager.get_broadphase_type(physics_scene=physics_scene_path),
        "gpu_dynamics_enabled": bool(
            SimulationManager.is_gpu_dynamics_enabled(physics_scene=physics_scene_path)
        ),
        "fabric_enabled": bool(SimulationManager.is_fabric_enabled()),
        "physics_scene": physics_scene_path,
    }
    RESULT["configuration"] = config
    print("T2_CONFIG " + json.dumps(config, sort_keys=True), flush=True)

    config_checks = {
        "active_engine_is_physx": config["active_engine"] == "physx",
        "device_is_cuda": "cuda" in str(config["physics_sim_device"]).lower(),
        "broadphase_is_gpu": str(config["broadphase_type"]).upper() == "GPU",
        "gpu_dynamics_is_enabled": config["gpu_dynamics_enabled"] is True,
    }
    if not all(config_checks.values()):
        raise RuntimeError(f"GPU PhysX configuration check failed: {config_checks}")

    GroundPlane(
        "/World/GroundPlane",
        positions=[0.0, 0.0, 0.0],
        sizes=100.0,
        templates=None,
    )

    columns_x = math.ceil(math.sqrt(ARGS.bodies / 4.0))
    columns_y = math.ceil(ARGS.bodies / (columns_x * 4.0))
    positions = np.empty((ARGS.bodies, 3), dtype=np.float32)
    paths: list[str] = []
    for index in range(ARGS.bodies):
        layer = index % 4
        column = index // 4
        x_index = column % columns_x
        y_index = column // columns_x
        positions[index] = (
            (x_index - (columns_x - 1) / 2.0) * 0.65,
            (y_index - (columns_y - 1) / 2.0) * 0.55,
            2.0 + layer * 0.45,
        )
        paths.append(f"/World/Cartons/carton_{index:05d}")

    rng = np.random.default_rng(ARGS.seed)
    positions[:, :2] += rng.uniform(-0.01, 0.01, size=(ARGS.bodies, 2)).astype(np.float32)

    box_shapes = Cube(
        paths=paths,
        positions=positions,
        sizes=1.0,
        scales=[0.50, 0.40, 0.30],
        colors="#a87943",
    )
    rigid_bodies = RigidPrim(paths=box_shapes.paths, masses=5.0)
    collision_shapes = GeomPrim(paths=box_shapes.paths, apply_collision_apis=True)
    RESULT["scene"] = {
        "layout": [columns_x, columns_y, 4],
        "rigid_body_count": len(rigid_bodies),
        "collision_shape_count": len(collision_shapes),
    }
    print(
        f"T2_SCENE bodies={len(rigid_bodies)} layout={columns_x}x{columns_y}x4",
        flush=True,
    )

    app_utils.play()
    simulation_app.update()

    start_positions, _ = rigid_bodies.get_world_poses()
    start_positions_np = start_positions.numpy().copy()

    step_started = time.perf_counter()
    progress_interval = max(1, ARGS.steps // 5)
    completed_steps = 0
    while completed_steps < ARGS.steps:
        chunk_steps = min(progress_interval, ARGS.steps - completed_steps)
        SimulationManager.step(steps=chunk_steps, update_fabric=False)
        completed_steps += chunk_steps
        print(f"T2_PROGRESS steps={completed_steps}/{ARGS.steps}", flush=True)
    step_elapsed_s = time.perf_counter() - step_started

    final_positions, final_orientations = rigid_bodies.get_world_poses()
    final_positions_np = final_positions.numpy().copy()
    final_orientations_np = final_orientations.numpy().copy()

    displacements = np.linalg.norm(final_positions_np - start_positions_np, axis=1)
    finite_poses = bool(
        np.isfinite(final_positions_np).all() and np.isfinite(final_orientations_np).all()
    )
    moved_count = int(np.count_nonzero(displacements > 0.25))
    metrics = {
        "completed_steps": completed_steps,
        "simulated_duration_s": completed_steps * physics_dt,
        "step_wall_time_s": step_elapsed_s,
        "mean_step_time_ms": step_elapsed_s * 1000.0 / completed_steps,
        "simulated_realtime_factor": (completed_steps * physics_dt) / step_elapsed_s,
        "finite_poses": finite_poses,
        "moved_more_than_0_25m_count": moved_count,
        "moved_fraction": moved_count / ARGS.bodies,
        "mean_displacement_m": float(np.mean(displacements)),
        "max_displacement_m": float(np.max(displacements)),
        "initial_mean_z_m": float(np.mean(start_positions_np[:, 2])),
        "final_mean_z_m": float(np.mean(final_positions_np[:, 2])),
        "final_min_z_m": float(np.min(final_positions_np[:, 2])),
        "final_max_z_m": float(np.max(final_positions_np[:, 2])),
    }
    RESULT["metrics"] = metrics

    behavioral_checks = {
        "all_steps_completed": completed_steps == ARGS.steps,
        "all_poses_are_finite": finite_poses,
        "at_least_95_percent_moved": moved_count >= math.ceil(ARGS.bodies * 0.95),
        "no_body_fell_materially_through_floor": metrics["final_min_z_m"] > -0.10,
    }
    RESULT["checks"] = {**config_checks, **behavioral_checks}
    RESULT["status"] = "PASS" if all(RESULT["checks"].values()) else "FAIL"
    RESULT["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
    write_result()
    print("T2_METRICS " + json.dumps(metrics, sort_keys=True), flush=True)
    print("T2_CHECKS " + json.dumps(RESULT["checks"], sort_keys=True), flush=True)
    print(f"T2_RESULT {RESULT['status']}", flush=True)
    EXIT_CODE = 0 if RESULT["status"] == "PASS" else 2
except Exception as exc:
    EXIT_CODE = 1
    RESULT["status"] = "ERROR"
    RESULT["error"] = {
        "type": type(exc).__name__,
        "message": str(exc),
        "traceback": traceback.format_exc(),
    }
    RESULT["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
    write_result()
    print("T2_RESULT ERROR", flush=True)
    traceback.print_exc()
finally:
    if ARGS.shutdown_mode == "process-exit":
        teardown = {
            "mode": "process-exit",
            "status": "FRAMEWORK_SHUTDOWN_BYPASSED",
            "timeline_stop": "NOT_ATTEMPTED",
            "stage_close": "NOT_ATTEMPTED",
            "reason": "One-shot container exits after timeline stop, stage close, and evidence flush.",
        }
        try:
            if "app_utils" in globals():
                app_utils.stop()
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
        RESULT["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        write_result()
        print("T2_TEARDOWN " + json.dumps(teardown, sort_keys=True), flush=True)
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(EXIT_CODE)

    RESULT["teardown"] = {"mode": "app-close", "status": "STARTED"}
    write_result()
    try:
        simulation_app.close(wait_for_replicator=False)
        RESULT["teardown"]["status"] = "COMPLETE"
        print("T2_TEARDOWN COMPLETE", flush=True)
    except Exception as exc:
        EXIT_CODE = 1
        RESULT["status"] = "ERROR"
        RESULT["teardown"] = {
            "mode": "app-close",
            "status": "ERROR",
            "error": f"{type(exc).__name__}: {exc}",
        }
        traceback.print_exc()
    RESULT["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
    write_result()

sys.exit(EXIT_CODE)
