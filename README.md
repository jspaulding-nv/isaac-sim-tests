# Isaac Sim and Isaac Lab GPU Validation

## Overview

Reproducible container tests for Isaac Sim 6.0.1 and Isaac Lab on an NVIDIA
RTX PRO 6000 Blackwell Server Edition GPU.

This repository turns a set of researched platform-risk questions into
measurable tests. No prior hardware failure or customer reproduction was
available. The results therefore describe proactive qualification on one
documented VM, not product certification or proof that a failure cannot occur.

## Questions Covered

This work began with seven open questions about "bugs and unknowns that could
affect a rollout." The source language is preserved where useful, lightly
edited to remove recipient-directed requests and to avoid presenting research
reports as failures reproduced here. `PARTIAL` means the question received
direct but bounded evidence on this VM; `OPEN` means the required hardware or
comparison was not tested.

| # | Source question, lightly edited | Evidence from this repository | Coverage and remaining investigation |
|---:|---|---|---|
| 1 | **GPU-PhysX error 719 on Blackwell.** Reports described an intermittent `PhysX Internal CUDA error, Error code 719` after a nondeterministic number of steps, or a silent CPU fallback. Is there a driver + Isaac Sim + PhysX combination stable on `sm_120`? | [T2](docs/test-plan.md#t2-gpu-physx-smoke) completed 600/600 steps with 1,024 bodies on `cuda:0`, with no targeted CUDA/fallback signature or Xid. [T3](docs/test-plan.md#t3-isaac-lab-gpu-physx-soak) completed three 16,384-environment Ant runs and 393,216,000 transitions with no targeted signature. | **PARTIAL.** This bounds one RTX PRO 6000 stack and workload envelope; it cannot disprove a nondeterministic failure. PRO 5000, longer runs, other robots/contacts, and representative scenes remain untested. |
| 2 | **Isaac Sim 6.0 + Newton.** Does 6.0 fix GPU PhysX on `sm_120`, or primarily offer Newton as an alternative backend? Is Newton ready for RL, and which features remain PhysX-GPU-only? | [T6](docs/test-plan.md#t6-newton-mjwarp-versus-physx) completed three runs per shipped preset and 78,643,200 transitions. Newton reported 2.62x PhysX training throughput, but mean simulation-start time was 5.37x as long and summed cold wall time was 8.9% longer on this task. | **PARTIAL.** Both presets ran, but this does not establish product intent, production readiness, convergence or numerical parity, or a PhysX-only feature inventory. More tasks, sensors, APIs, and warm-service tests are needed. |
| 3 | **Replicator tiled-camera hang on `sm_120`.** Reports described tiled rendering hanging before the Warp kernel runs, affecting CosmosWriter SDG output and camera-based sensing. Does this affect the PRO Blackwell line? | [T4](docs/test-plan.md#t4-tiled-camera-progression) produced 600/600 advancing buffers from 16 tiled cameras at 320 x 240 in Full Streaming. The standalone normal-camera control returned no RGB. | **PARTIAL.** No streaming-path hang occurred in the tested envelope, but the standalone discrepancy remains. The planned 64-camera, 640 x 480 case, production scenes, and PRO 5000 remain open. |
| 4 | **CosmosWriter SDG on Blackwell.** Beyond documented video-skip and DLSS-mode workarounds, do `sm_120` issues affect ground-truth label integrity for depth, segmentation, or edge control signals? | [T5](docs/test-plan.md#t5-cosmoswriter) delivered 60/60 frames for five modalities in Full Streaming: 300 PNGs and five 60-frame H.264 videos. Independent checks covered decoding, freshness, semantic colors, and segmentation/edge alignment. Standalone runs delivered 56/60. | **PARTIAL.** The Full Streaming outputs passed, but the standalone shortfall needs root-cause work. Depth was colorized rather than raw metric depth; representative assets, lighting, occlusion, and longer runs remain open. |
| 5 | **PRO 5000 specifically.** Public reports centered on the PRO 6000. Does Isaac Sim launch cleanly on the PRO 5000, and is card-specific validation available? | [T1](docs/test-plan.md#t1-isaac-sim-clean-launch-and-webrtc) demonstrated clean launch and WebRTC on an RTX PRO 6000 Blackwell Server Edition only. | **OPEN for PRO 5000.** A card-specific run of T0-T6 is required; RTX PRO 6000 results must not be treated as PRO 5000 certification. |
| 6 | **Current validated stack.** What driver, Isaac Sim, Isaac Lab, PhysX, and Torch versions are validated for the PRO 5000? | [T0](docs/test-plan.md#t0-environment-inventory), [T1](docs/test-plan.md#t1-isaac-sim-clean-launch-and-webrtc), and the [Tested Stack](#tested-stack) record the exact RTX PRO 6000 VM, driver, containers, Isaac Sim, Isaac Lab, PhysX, Torch, Warp, and RSL-RL versions used here. | **PARTIAL.** This is a reproducible tested configuration for RTX PRO 6000, not a PRO 5000 result or an official supported-stack declaration. |
| 7 | **PRO 5000 Blackwell vs. RTX 6000 Ada.** Is either GPU preferable for current Isaac or Omniverse workloads when production readiness matters more than architecture generation? | No cross-card hardware benchmark was run. T0-T6 provide a reusable comparison procedure. | **OPEN.** Run the same images, seeds, scenes, sensor loads, power sampling, and acceptance criteria on both cards before making a procurement recommendation. |

**Coverage summary:** Questions 1-4 received direct but bounded evidence,
question 6 received an RTX PRO 6000 tested-stack record rather than the
requested PRO 5000 result, and questions 5 and 7 remain untested. See [the
detailed question boundaries](docs/questions.md), the [test
plan](docs/test-plan.md), and the [workload index](tests/README.md).

## Visual Replays

The measured tests run headlessly. Separate WebRTC replays make selected
workloads visible in a browser for recording and human observation.

### T2: GPU PhysX Replay

![T2 GPU PhysX replay showing 1,024 falling rigid bodies](media/t2-gpu-physx.gif)

### T4: Tiled-Camera Replay

![T4 tiled-camera replay showing 16 advancing camera views](media/t4-tiled-cameras.gif)

### T5: CosmosWriter Modalities

![T5-C CosmosWriter synchronized RGB, shaded segmentation, semantic segmentation, colorized depth, and edge outputs](media/t5-cosmoswriter.png)

The panels show the same validated frame. Depth is colorized for visualization
and is not raw metric depth.

### T6: Newton Ant Replay

![T6 Newton Ant policy replay](media/t6-newton-ant.gif)

See [media/README.md](media/README.md) for provenance and sanitization guidance.

## Tested Stack

| Component | Tested value |
|---|---|
| Reference run | 2026-07-20 through 2026-07-21 UTC |
| GPU | NVIDIA RTX PRO 6000 Blackwell Server Edition, full PCIe pass-through |
| Guest | Ubuntu 22.04.5 LTS, kernel 5.15.0-181-generic |
| Driver | 595.84 |
| Docker / NVIDIA Container Toolkit | 29.6.0 / 1.19.1 |
| Isaac Sim container | `nvcr.io/nvidia/isaac-sim:6.0.1` |
| Isaac Sim digest | `sha256:783444c706538aa76cf5126e911ddc5e618779e6105305ad4af4260362a30aa9` |
| Isaac Sim / Kit / PhysX / Warp | 6.0.1 / 110.1.2 / 110.1.13 / 1.13.0 |
| Isaac Lab | `nvcr.io/nvidia/isaac-lab:3.0.0-beta2-post1` |
| Isaac Lab digest | `sha256:18b95be31ec02017fec4c7f1cf51aac9bb7ea9fd868d0f051f5d71837b54bc5f` |
| Isaac Lab bundled Isaac Sim | `6.0.1-rc.7+release.42383.32955d8d.gl` |
| Python / Torch / RSL-RL | 3.12.13 / 2.10.0+cu128 / 5.0.1 |

The Isaac Lab image is a beta track selected because this exact image bundled
the tested Isaac Sim build and shipped both `physx` and `newton_mjwarp`
presets. All scripts allow the image reference to be overridden.

## Result Snapshot

| Test | Result on the tested VM |
|---|---|
| T0 inventory | GPU, VM, driver, container runtime, rendering, and NVENC were identified |
| T1 clean launch | Isaac Sim 6.0.1 reached streaming-ready state and accepted a browser WebRTC session |
| T2 GPU PhysX smoke | 1,024 rigid bodies completed 600 steps on `cuda:0`; lifecycle and driver warnings remain documented |
| T3 PhysX soak | Three 16,384-environment Ant runs completed 393,216,000 transitions |
| T4 tiled cameras | Standalone headless control failed to produce RGB; Full Streaming delivered 600/600 buffers from 16 cameras at 320 x 240 |
| T5 CosmosWriter | Standalone runs delivered 56/60 frames; Full Streaming delivered 60/60 for five modalities and five H.264 videos |
| T6 Newton comparison | Six A/B runs completed 78,643,200 transitions; Newton training throughput was 2.62x PhysX, with longer cold startup |
| T6 visual replay | A 16-environment Newton policy replay was visible and moving in the browser |

These split results matter. A pass in Full Streaming does not erase the
standalone T4/T5 failures. See [results/tested-configuration.md](results/tested-configuration.md)
for measurements, warnings, and limitations.

## Quick Start

Prerequisites:

- Linux host with a supported NVIDIA GPU and driver.
- Docker Engine with NVIDIA CDI devices available as `nvidia.com/gpu=all`.
- Access to `nvcr.io` and acceptance of the image licenses.
- `bash`, `curl`, `jq`, `rg`, and `nvidia-smi` on the host.
- TCP and UDP ports reachable only from a trusted network for browser replay.

Configure the headless WebRTC deployment:

```bash
cp deploy/.env.example deploy/.env
${EDITOR:-vi} deploy/.env
./deploy/start.sh
```

Open `http://<ISAACSIM_HOST>:<WEB_VIEWER_PORT>` from a machine that can reach
the host. The viewer has no built-in authentication or TLS termination. Do not
expose it directly to the public Internet.

Run the tests in order:

```bash
./scripts/collect_inventory.sh
./scripts/run_compatibility.sh
./scripts/run_gpu_physx_smoke.sh
./scripts/run_isaac_lab_preflight.sh
./scripts/run_physx_soak.sh
./scripts/run_tiled_camera_progression.sh
./scripts/run_cosmos_writer_headless.sh
./scripts/run_cosmos_writer_streaming.sh
./scripts/run_backend_comparison.sh
```

The default soak and comparison scales are intentionally substantial. Start
with the lower-cost gates in [docs/reproduction.md](docs/reproduction.md), then
increase scale only after they pass.

## Repository Map

```text
deploy/     Headless Isaac Sim and WebRTC viewer deployment
docs/       Questions, test plan, reproduction, and privacy guidance
media/      Sanitized browser replays and generated evidence visuals
results/    Curated, sanitized results from the reference run
scripts/    Host-side test orchestration and evidence collection
tests/      Workload index, Isaac Sim Python tests, and output validator
```

Generated output goes under `output/` and is ignored by Git. Review
[docs/privacy.md](docs/privacy.md) before sharing any generated evidence.

## Interpretation

- Results apply to the documented images, task definitions, parameters, and
  GPU configuration only.
- A passing soak narrows risk; it does not prove a CUDA failure is impossible.
- PhysX and Newton use different shipped solver configurations. Throughput
  comparisons are not numerical-equivalence claims.
- WebRTC rendering and NVENC add load and are kept outside measured headless
  comparisons.
- RTX PRO 6000 results do not certify another GPU model.

## Upstream Documentation

- [Isaac Sim container installation](https://docs.isaacsim.omniverse.nvidia.com/latest/installation/install_container.html#isaac-sim-app-install-container)
- [Isaac Lab documentation](https://isaac-sim.github.io/IsaacLab/)

Isaac Sim, Isaac Lab, CUDA, PhysX, RTX, and NVIDIA are trademarks or products
of NVIDIA Corporation. This repository is an independent test record and is
not an official certification.
