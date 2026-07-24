# Test Workload Index

The root [question-coverage matrix](../README.md#questions-covered) explains why
each test exists. This index points from each test ID to the workload code and
host-side runner that produced the evidence.

| Test | Source question(s) | Workload and runner | What it exercises |
|---|---|---|---|
| T0 | Q6: current stack | [`collect_inventory.sh`](../scripts/collect_inventory.sh) | GPU exposure, system resources, virtualization exposure, driver, Docker, NVIDIA container runtime, rendering, NVENC, and application versions. |
| T1 | Q5/Q6: clean launch and stack control | [`run_compatibility.sh`](../scripts/run_compatibility.sh) | Cold/warm Isaac Sim 6.0.1 launch, compatibility check, Full Streaming readiness, WebRTC, and NVENC on each documented system. |
| T2 | Q1: GPU-PhysX error 719/fallback | [`gpu_physx_smoke.py`](gpu_physx_smoke.py), [`run_gpu_physx_smoke.sh`](../scripts/run_gpu_physx_smoke.sh), and [`visible_gpu_physx_demo.py`](visible_gpu_physx_demo.py) | A fixed 1,024-body GPU dynamics/broadphase workload, device assertions, progress markers, targeted signatures, lifecycle behavior, and a separate visual replay. |
| T3 | Q1: longer Isaac Lab PhysX stability | [`run_isaac_lab_preflight.sh`](../scripts/run_isaac_lab_preflight.sh) and [`run_physx_soak.sh`](../scripts/run_physx_soak.sh) | The shipped `Isaac-Ant-Direct-v0` task at 16,384 environments, 250 PPO iterations, and three seeds using the `physx` preset. |
| T4 | Q3: tiled-camera hang | [`tiled_camera_progression.py`](tiled_camera_progression.py), [`run_tiled_camera_progression.sh`](../scripts/run_tiled_camera_progression.sh), and [`visible_tiled_camera_replay.py`](visible_tiled_camera_replay.py) | Normal/tiled camera progression, buffer shape and freshness, watchdogs, targeted Warp/CUDA signatures, and a separate 16-view replay. |
| T5 | Q4: CosmosWriter integrity | [`cosmos_writer_simple_headless.py`](cosmos_writer_simple_headless.py), [`cosmos_writer_streaming.py`](cosmos_writer_streaming.py), [`validate_cosmos_output.py`](validate_cosmos_output.py), the [headless runner](../scripts/run_cosmos_writer_headless.sh), and the [streaming runner](../scripts/run_cosmos_writer_streaming.sh) | RGB, shaded segmentation, semantic segmentation, colorized depth, and edges across PNG and H.264 outputs, including independent frame/video validation. |
| T6 | Q2: Newton versus PhysX | [`run_backend_comparison.sh`](../scripts/run_backend_comparison.sh) and [`start_newton_visual_replay.sh`](../scripts/start_newton_visual_replay.sh) | Frozen same-task runs of the shipped `physx` and `newton_mjwarp` presets across three seeds, plus a separate browser-visible policy replay. |

Q7, the PRO 5000 versus RTX 6000 Ada comparison, remains open. The available
matched result is RTX PRO 5000 Blackwell versus RTX PRO 6000 Blackwell Server
Edition; it does not answer the Ada question.

The acceptance criteria and execution order live in the [test
plan](../docs/test-plan.md). Curated measurements, split results, and known
limitations live in the
[RTX PRO 5000 result](../results/rtx-pro-5000-tested-configuration.md) and
[RTX PRO 6000 reference](../results/tested-configuration.md). Visual replays
support human observation but are not substitutes for the measured headless
evidence runs.
