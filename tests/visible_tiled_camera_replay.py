#!/usr/bin/env python3
"""Create a browser-visible, user-triggered T4 tiled-camera replay."""

from __future__ import annotations

import colorsys
import json
import math
import traceback

import numpy as np


CAMERA_COUNT = 16
RESOLUTION = (240, 320)
TARGET_FRAMES = 600
NO_DATA_LIMIT = 120
SEED = 20260721


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


try:
    import isaacsim.core.experimental.utils.app as app_utils
    import isaacsim.core.experimental.utils.stage as stage_utils
    import omni.kit.app
    import omni.replicator.core as rep
    import omni.ui as ui
    from isaacsim.core.experimental.objects import DomeLight, GroundPlane
    from isaacsim.core.rendering_manager import ViewportManager
    from isaacsim.core.utils.viewports import set_camera_view
    from isaacsim.sensors.experimental.rtx import RtxCamera, TiledCameraSensor
    from pxr import Gf, UsdGeom

    app_utils.stop(commit=True)
    stage_utils.create_new_stage()
    stage_utils.define_prim("/World", type_name="Xform")
    stage_utils.define_prim("/World/Cameras", type_name="Xform")
    stage_utils.define_prim("/World/Environments", type_name="Xform")
    stage = stage_utils.get_current_stage(backend="usd")
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    grid_columns = 4
    grid_rows = 4
    spacing = 6.0
    GroundPlane("/World/GroundPlane", sizes=36.0, colors=[0.12, 0.14, 0.16])
    light = DomeLight("/World/DomeLight")
    light.set_intensities(1200)

    camera_paths: list[str] = []
    camera_objects: list[object] = []
    moving_ops: list[object] = []
    centers: list[tuple[float, float]] = []
    rng = np.random.default_rng(SEED)

    for index in range(CAMERA_COUNT):
        column = index % grid_columns
        row = index // grid_columns
        center_x = (column - (grid_columns - 1) / 2.0) * spacing
        center_y = (row - (grid_rows - 1) / 2.0) * spacing
        centers.append((center_x, center_y))
        env_path = f"/World/Environments/env_{index:03d}"
        stage_utils.define_prim(env_path, type_name="Xform")

        accent = colorsys.hsv_to_rgb(index / CAMERA_COUNT, 0.78, 0.92)
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
        camera_objects.append(RtxCamera(camera_path))

    for index, camera_path in enumerate(camera_paths):
        center_x, center_y = centers[index]
        ViewportManager.set_camera_view(
            camera_path,
            eye=[center_x + 3.4 + float(rng.uniform(-0.12, 0.12)), center_y - 3.8, 3.5],
            target=[center_x, center_y, 0.35],
        )

    set_camera_view(
        eye=[19.0, -23.0, 23.0],
        target=[0.0, 0.0, 0.0],
        camera_prim_path="/OmniverseKit_Persp",
    )

    sensor = TiledCameraSensor(
        "/World/Cameras/camera_.*",
        resolution=RESOLUTION,
        annotators=["rgb"],
    )
    rep.orchestrator.preview()

    tiled_height, tiled_width = sensor.tiled_resolution
    placeholder = np.zeros((tiled_height, tiled_width, 4), dtype=np.uint8)
    placeholder[:, :, 3] = 255
    band_height = max(1, tiled_height // 4)
    placeholder[:band_height, :, :3] = [38, 49, 58]
    placeholder[band_height : band_height * 2, :, :3] = [28, 84, 104]
    placeholder[band_height * 2 : band_height * 3, :, :3] = [92, 73, 32]
    placeholder[band_height * 3 :, :, :3] = [35, 92, 61]

    provider = ui.DynamicTextureProvider("t4_tiled_camera_replay")
    provider.set_data_array(placeholder, [tiled_width, tiled_height])

    state = {
        "running": False,
        "delivered_frames": 0,
        "updates_without_data": 0,
        "first_frame_logged": False,
        "failed": False,
    }

    window = ui.Window("T4 Tiled Camera Replay", width=1120, height=820, visible=True)
    status_label = None
    detail_label = None

    def set_status(status: str, detail: str) -> None:
        if status_label is not None:
            status_label.text = status
        if detail_label is not None:
            detail_label.text = detail

    def reset_replay() -> None:
        state.update(
            {
                "running": False,
                "delivered_frames": 0,
                "updates_without_data": 0,
                "first_frame_logged": False,
                "failed": False,
            }
        )
        app_utils.stop(commit=True)
        for index, translate_op in enumerate(moving_ops):
            center_x, center_y = centers[index]
            translate_op.Set(Gf.Vec3d(center_x, center_y, 0.45))
        provider.set_data_array(placeholder, [tiled_width, tiled_height])
        set_status(
            "READY - start your screen recorder, then select Start Replay",
            f"T4-C visual comparison | {CAMERA_COUNT} cameras | {RESOLUTION[1]}x{RESOLUTION[0]} per tile",
        )

    def start_replay() -> None:
        state.update(
            {
                "running": True,
                "delivered_frames": 0,
                "updates_without_data": 0,
                "first_frame_logged": False,
                "failed": False,
            }
        )
        app_utils.play(commit=True)
        set_status(
            "RUNNING - waiting for the first tiled RGB frame",
            f"Delivered 0/{TARGET_FRAMES} | no-data updates 0/{NO_DATA_LIMIT}",
        )
        print("VISIBLE_T4_REPLAY_STARTED", flush=True)

    with window.frame:
        with ui.VStack(spacing=8):
            ui.Label(
                "T4 Tiled-Camera Visual Replay",
                height=34,
                style={"font_size": 24, "color": 0xFFFFFFFF},
            )
            status_label = ui.Label(
                "READY - start your screen recorder, then select Start Replay",
                height=28,
                style={"font_size": 18, "color": 0xFFB7E4C7},
            )
            detail_label = ui.Label(
                f"T4-C visual comparison | {CAMERA_COUNT} cameras | {RESOLUTION[1]}x{RESOLUTION[0]} per tile",
                height=24,
                style={"font_size": 15, "color": 0xFFD6D9DC},
            )
            with ui.HStack(height=36, spacing=8):
                ui.Button("Start Replay", clicked_fn=start_replay, width=160)
                ui.Button("Reset", clicked_fn=reset_replay, width=100)
                ui.Spacer()
            ui.ImageWithProvider(
                provider,
                fill_policy=ui.IwpFillPolicy.IWP_STRETCH,
                width=ui.Fraction(1),
                height=ui.Fraction(1),
            )

    def on_update(event: object) -> None:
        del event
        if not state["running"]:
            return
        frame = state["delivered_frames"]
        phase = 2.0 * math.pi * frame / 113.0
        for index, translate_op in enumerate(moving_ops):
            center_x, center_y = centers[index]
            offset_x = 0.82 * math.sin(phase + index * 0.17)
            offset_y = 0.42 * math.cos(phase * 0.73 + index * 0.11)
            translate_op.Set(Gf.Vec3d(center_x + offset_x, center_y + offset_y, 0.45))

        data, _ = sensor.get_data("rgb", tiled=True)
        if data is None:
            state["updates_without_data"] += 1
            set_status(
                "RUNNING - render product has not delivered RGB data",
                f"Delivered {frame}/{TARGET_FRAMES} | no-data updates {state['updates_without_data']}/{NO_DATA_LIMIT}",
            )
            if state["updates_without_data"] >= NO_DATA_LIMIT:
                state["running"] = False
                state["failed"] = True
                app_utils.stop(commit=True)
                set_status(
                    "FAIL - no tiled RGB data after 120 updates",
                    "This matches the headless T4-A baseline boundary; no camera-scale claim is made.",
                )
                print("VISIBLE_T4_REPLAY_FAIL reason=no_rgb_data updates=120", flush=True)
            return

        state["updates_without_data"] = 0
        tiled_rgb = data.numpy()
        if tuple(tiled_rgb.shape) != (tiled_height, tiled_width, 3):
            state["running"] = False
            state["failed"] = True
            app_utils.stop(commit=True)
            set_status(
                "FAIL - unexpected tiled RGB shape",
                f"Received {tuple(tiled_rgb.shape)}, expected {(tiled_height, tiled_width, 3)}",
            )
            print(f"VISIBLE_T4_REPLAY_FAIL reason=shape actual={tuple(tiled_rgb.shape)}", flush=True)
            return

        rgba = np.empty((tiled_height, tiled_width, 4), dtype=np.uint8)
        rgba[:, :, :3] = tiled_rgb
        rgba[:, :, 3] = 255
        provider.set_data_array(rgba, [tiled_width, tiled_height])
        state["delivered_frames"] += 1
        frame = state["delivered_frames"]
        if not state["first_frame_logged"]:
            state["first_frame_logged"] = True
            print("VISIBLE_T4_FRAME_READY", flush=True)
        set_status(
            "RUNNING - tiled RGB frames are advancing",
            f"Delivered {frame}/{TARGET_FRAMES} | {CAMERA_COUNT} cameras | tiled output {tiled_width}x{tiled_height}",
        )
        if frame >= TARGET_FRAMES:
            state["running"] = False
            app_utils.stop(commit=True)
            set_status(
                "PASS - visual replay delivered all tiled RGB frames",
                f"Delivered {frame}/{TARGET_FRAMES}; recording is a visual comparison, not the headless evidence run.",
            )
            print(f"VISIBLE_T4_REPLAY_COMPLETE frames={frame}", flush=True)

    update_subscription = omni.kit.app.get_app().get_update_event_stream().create_subscription_to_pop(
        on_update,
        name="T4 tiled-camera visual replay",
    )

    config = {
        "camera_count": CAMERA_COUNT,
        "per_camera_resolution": list(RESOLUTION),
        "tiled_resolution": list(sensor.tiled_resolution),
        "target_frames": TARGET_FRAMES,
        "no_data_limit": NO_DATA_LIMIT,
        "seed": SEED,
        "render_product_path": str(sensor.render_product.GetPath()),
    }
    print("VISIBLE_T4_REPLAY_CONFIG " + json.dumps(config, sort_keys=True), flush=True)
    print("VISIBLE_T4_REPLAY_READY", flush=True)
except Exception:
    print("VISIBLE_T4_REPLAY_STARTUP_ERROR", flush=True)
    traceback.print_exc()
    raise
