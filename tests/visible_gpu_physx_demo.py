#!/usr/bin/env python3
"""Populate the livestreamed Isaac Sim app with a repeating GPU PhysX demo."""

from __future__ import annotations

import json
import math
import traceback

import numpy as np


BODY_COUNT = 1024
RESET_STEPS = 600
SEED = 20260720
PHYSICS_DT = 1.0 / 60.0
PHYSICS_SCENE_PATH = "/World/PhysicsScene"


try:
    import isaacsim.core.experimental.utils.app as app_utils
    import isaacsim.core.experimental.utils.stage as stage_utils
    from isaacsim.core.experimental.objects import Cube, DistantLight, DomeLight, GroundPlane
    from isaacsim.core.experimental.prims import GeomPrim, RigidPrim
    from isaacsim.core.simulation_manager import IsaacEvents, SimulationManager
    from isaacsim.core.utils.viewports import set_camera_view
    from pxr import Gf, PhysxSchema, UsdGeom, UsdPhysics

    stage_utils.create_new_stage()
    stage_utils.define_prim("/World", type_name="Xform")
    stage = stage_utils.get_current_stage(backend="usd")
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    physics_scene = UsdPhysics.Scene.Define(stage, PHYSICS_SCENE_PATH)
    physics_scene.CreateGravityDirectionAttr(Gf.Vec3f(0.0, 0.0, -1.0))
    physics_scene.CreateGravityMagnitudeAttr(9.81)
    PhysxSchema.PhysxSceneAPI.Apply(physics_scene.GetPrim())

    SimulationManager.set_default_physics_scene(PHYSICS_SCENE_PATH)
    SimulationManager.set_device("cuda:0")
    SimulationManager.set_physics_dt(PHYSICS_DT, physics_scene=PHYSICS_SCENE_PATH)
    SimulationManager.set_broadphase_type("GPU", physics_scene=PHYSICS_SCENE_PATH)
    SimulationManager.enable_gpu_dynamics(True, physics_scene=PHYSICS_SCENE_PATH)

    GroundPlane(
        "/World/GroundPlane",
        positions=[0.0, 0.0, 0.0],
        sizes=30.0,
        colors=[0.20, 0.22, 0.24],
        templates=None,
    )
    dome_light = DomeLight("/World/DomeLight")
    dome_light.set_intensities(550)
    distant_light = DistantLight("/World/DistantLight")
    distant_light.set_intensities(2200)

    columns_x = math.ceil(math.sqrt(BODY_COUNT / 4.0))
    columns_y = math.ceil(BODY_COUNT / (columns_x * 4.0))
    initial_positions = np.empty((BODY_COUNT, 3), dtype=np.float32)
    initial_orientations = np.zeros((BODY_COUNT, 4), dtype=np.float32)
    initial_orientations[:, 0] = 1.0
    zero_velocities = np.zeros((BODY_COUNT, 3), dtype=np.float32)
    colors = np.empty((BODY_COUNT, 3), dtype=np.float32)
    palette = np.asarray(
        [
            [0.88, 0.31, 0.14],
            [0.10, 0.48, 0.76],
            [0.96, 0.70, 0.16],
            [0.24, 0.68, 0.42],
        ],
        dtype=np.float32,
    )
    paths: list[str] = []
    for index in range(BODY_COUNT):
        layer = index % 4
        column = index // 4
        x_index = column % columns_x
        y_index = column // columns_x
        initial_positions[index] = (
            (x_index - (columns_x - 1) / 2.0) * 0.65,
            (y_index - (columns_y - 1) / 2.0) * 0.55,
            2.0 + layer * 0.45,
        )
        colors[index] = palette[layer]
        paths.append(f"/World/Cartons/carton_{index:05d}")

    rng = np.random.default_rng(SEED)
    initial_positions[:, :2] += rng.uniform(-0.01, 0.01, size=(BODY_COUNT, 2)).astype(np.float32)

    carton_shapes = Cube(
        paths=paths,
        positions=initial_positions,
        sizes=1.0,
        scales=[0.50, 0.40, 0.30],
        colors=colors,
    )
    cartons = RigidPrim(paths=carton_shapes.paths, masses=5.0)
    carton_collisions = GeomPrim(paths=carton_shapes.paths, apply_collision_apis=True)

    set_camera_view(
        eye=[13.0, -15.0, 10.0],
        target=[0.0, 0.0, 1.1],
        camera_prim_path="/OmniverseKit_Persp",
    )

    loop_state = {"steps": 0, "cycles": 0, "failed": False}

    def repeat_carton_drop(dt: float, context: object) -> None:
        del dt, context
        if loop_state["failed"]:
            return
        loop_state["steps"] += 1
        if loop_state["steps"] < RESET_STEPS:
            return
        try:
            cartons.set_world_poses(
                positions=initial_positions,
                orientations=initial_orientations,
            )
            cartons.set_velocities(
                linear_velocities=zero_velocities,
                angular_velocities=zero_velocities,
            )
            loop_state["steps"] = 0
            loop_state["cycles"] += 1
            print(f"VISIBLE_T2_DEMO_RESET cycle={loop_state['cycles']}", flush=True)
        except Exception:
            loop_state["failed"] = True
            print("VISIBLE_T2_DEMO_RESET_ERROR", flush=True)
            traceback.print_exc()

    app_utils.play()
    callback_id = SimulationManager.register_callback(
        repeat_carton_drop,
        event=IsaacEvents.POST_PHYSICS_STEP,
    )

    config = {
        "active_engine": SimulationManager.get_active_physics_engine(),
        "body_count": len(cartons),
        "broadphase_type": SimulationManager.get_broadphase_type(physics_scene=PHYSICS_SCENE_PATH),
        "callback_id": callback_id,
        "collision_shape_count": len(carton_collisions),
        "device": SimulationManager.get_physics_sim_device(),
        "gpu_dynamics_enabled": bool(
            SimulationManager.is_gpu_dynamics_enabled(physics_scene=PHYSICS_SCENE_PATH)
        ),
        "reset_steps": RESET_STEPS,
        "seed": SEED,
    }
    if not (
        config["active_engine"] == "physx"
        and "cuda" in str(config["device"]).lower()
        and str(config["broadphase_type"]).upper() == "GPU"
        and config["gpu_dynamics_enabled"] is True
    ):
        raise RuntimeError(f"Visible GPU PhysX configuration failed: {config}")

    print("VISIBLE_T2_DEMO_CONFIG " + json.dumps(config, sort_keys=True), flush=True)
    print("VISIBLE_T2_DEMO_READY", flush=True)
except Exception:
    print("VISIBLE_T2_DEMO_STARTUP_ERROR", flush=True)
    traceback.print_exc()
    raise
