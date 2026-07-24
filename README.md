# Isaac Sim and Isaac Lab GPU Validation

## Overview

Reproducible container tests for Isaac Sim 6.0.1 and Isaac Lab on NVIDIA
RTX PRO 5000 Blackwell and RTX PRO 6000 Blackwell Server Edition GPUs.

This repository turns a set of researched platform-risk questions into
measurable tests. No prior hardware failure or customer reproduction was
available. The results therefore describe proactive qualification on two
documented systems, not product certification, a controlled GPU-only
benchmark, or proof that a failure cannot occur.

## Questions Covered

This work began with seven open questions about "bugs and unknowns that could
affect a rollout." The source language is preserved where useful, lightly
edited to remove recipient-directed requests and to avoid presenting research
reports as failures reproduced here. `PARTIAL` means the question received
direct but bounded evidence; `OPEN` means the required hardware or comparison
was not tested.

| # | Source question, lightly edited | RTX PRO 5000 Blackwell evidence | RTX PRO 6000 Blackwell reference evidence | Coverage and remaining investigation |
|---:|---|---|---|---|
| 1 | **GPU-PhysX error 719 on Blackwell.** Reports described an intermittent `PhysX Internal CUDA error, Error code 719` after a nondeterministic number of steps, or a silent CPU fallback. Is there a driver + Isaac Sim + PhysX combination stable on `sm_120`? | [T2](docs/test-plan.md#t2-gpu-physx-smoke) passed 600/600 steps; [T3](docs/test-plan.md#t3-isaac-lab-gpu-physx-soak) passed 393,216,000/393,216,000 transitions. | The same T2 and T3 envelopes passed. Neither system showed a targeted CUDA/fallback signature or Xid. | **PARTIAL.** This bounds two RTX PRO Blackwell systems and fixed workload envelopes; it cannot disprove an intermittent failure. Longer runs, other robots/contacts, and representative scenes remain open. |
| 2 | **Isaac Sim 6.0 + Newton.** Does 6.0 fix GPU PhysX on `sm_120`, or primarily offer Newton as an alternative backend? Is Newton ready for RL, and which features remain PhysX-GPU-only? | [T6](docs/test-plan.md#t6-newton-mjwarp-versus-physx) passed 6/6 runs. Newton/PhysX ratios were 1.39x training throughput, 6.43x simulation start, and 1.76x summed cold wall time. | T6 passed 6/6 runs. Newton/PhysX ratios were 2.62x training throughput, 5.37x simulation start, and 1.09x summed cold wall time. | **PARTIAL.** Both shipped presets ran on both systems, but this does not establish production readiness, convergence or numerical parity, or a PhysX-only feature inventory. |
| 3 | **Replicator tiled-camera hang on `sm_120`.** Reports described tiled rendering hanging before the Warp kernel runs, affecting CosmosWriter SDG output and camera-based sensing. Does this affect the PRO Blackwell line? | [T4](docs/test-plan.md#t4-tiled-camera-progression) produced 600/600 buffers from 16 tiled cameras at 320 x 240 in Full Streaming; standalone returned no RGB. | The matched Full Streaming replay also produced 600/600 buffers; standalone again returned no RGB. | **PARTIAL.** No streaming-path hang occurred in either tested envelope, but the standalone discrepancy, 64-camera case, 640 x 480 case, and production scenes remain open. |
| 4 | **CosmosWriter SDG on Blackwell.** Beyond documented video-skip and DLSS-mode workarounds, do `sm_120` issues affect ground-truth label integrity for depth, segmentation, or edge control signals? | [T5](docs/test-plan.md#t5-cosmoswriter) delivered and independently validated 60/60 Full Streaming frames for five modalities; standalone delivered 55/60. | Full Streaming also delivered 60/60 frames for all five modalities; standalone delivered 56/60. | **PARTIAL.** Full Streaming passed on both systems, but the standalone shortfall needs root-cause work. Raw metric depth, representative assets, and longer runs remain open. |
| 5 | **PRO 5000 specifically.** Public reports centered on the PRO 6000. Does Isaac Sim launch cleanly on the PRO 5000, and is card-specific validation available? | The card-specific T0-T6 run completed. Compatibility and warm Full Streaming passed; cold Full Streaming remained in `await_viewport` and failed health readiness. | T1 compatibility, cold/warm Full Streaming, WebRTC, and input passed on the reference system. | **PARTIAL for PRO 5000.** Card-specific evidence now exists, but the cold-launch failure needs root-cause work and one system is not certification. |
| 6 | **Current validated stack.** What driver, Isaac Sim, Isaac Lab, PhysX, and Torch versions are validated for the PRO 5000? | The [RTX PRO 5000 result](results/rtx-pro-5000-tested-configuration.md) records driver 595.84, pinned containers, and the observed application stack. | The [RTX PRO 6000 reference](results/tested-configuration.md) records its exact hardware and software stack. | **PARTIAL.** These are reproducible tested configurations, not an official supported-stack declaration. |
| 7 | **PRO 5000 Blackwell vs. RTX 6000 Ada.** Is either GPU preferable for current Isaac or Omniverse workloads when production readiness matters more than architecture generation? | Matched Blackwell-to-Blackwell workloads were run, but the unlike hosts prevent a GPU-only ranking. | The available reference is an RTX PRO 6000 **Blackwell** Server Edition, not an RTX 6000 Ada. | **OPEN.** No RTX 6000 Ada was tested, so this repository cannot answer the requested Ada procurement comparison. |

**Coverage summary:** Questions 1-6 now have direct but bounded evidence on
both documented RTX PRO Blackwell systems. Question 7 remains open because the
reference GPU is an RTX PRO 6000 Blackwell Server Edition, not an RTX 6000 Ada.
See [the detailed question boundaries](docs/questions.md), the [test
plan](docs/test-plan.md), and the [workload index](tests/README.md).

## Visual Replays

The measured tests run headlessly. Separate WebRTC replays make selected
workloads visible in a browser for recording and human observation. The
published media below comes from the RTX PRO 6000 reference run. RTX PRO 5000
visual replays passed manual observation, but no sanitized browser capture was
retained for publication.

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

## Tested Configurations

| Component | RTX PRO 5000 Blackwell | RTX PRO 6000 Blackwell reference |
|---|---|---|
| Run | 2026-07-23 through 2026-07-24 UTC | 2026-07-20 through 2026-07-21 UTC |
| GPU / framebuffer | NVIDIA RTX PRO 5000 Blackwell, 48,935 MiB | NVIDIA RTX PRO 6000 Blackwell Server Edition, 97,887 MiB |
| Exposure | Full device, MIG disabled, ECC enabled; `systemd-detect-virt` reported `none` | Full PCIe pass-through VM, MIG inactive |
| System | Ubuntu 22.04.5 LTS, kernel 5.15.0-177-generic; Ryzen 7 7800X3D, 16 logical CPUs, 124 GiB RAM | Ubuntu 22.04.5 LTS, kernel 5.15.0-181-generic; 32 vCPU, 62 GiB RAM |
| Driver | 595.84 | 595.84 |
| Docker / NVIDIA Container Toolkit | 29.6.0 / 1.19.1 | 29.6.0 / 1.19.1 |

Common frozen software:

| Component | Tested value |
|---|---|
| Isaac Sim container | `nvcr.io/nvidia/isaac-sim:6.0.1` |
| Isaac Sim digest | `sha256:783444c706538aa76cf5126e911ddc5e618779e6105305ad4af4260362a30aa9` |
| Isaac Sim / Kit / PhysX / Warp | 6.0.1 / 110.1.2 / 110.1.13 / 1.13.0 |
| Isaac Lab | `nvcr.io/nvidia/isaac-lab:3.0.0-beta2-post1` |
| Isaac Lab digest | `sha256:18b95be31ec02017fec4c7f1cf51aac9bb7ea9fd868d0f051f5d71837b54bc5f` |
| Isaac Lab bundled Isaac Sim | `6.0.1-rc.7+release.42383.32955d8d.gl` |
| Python / Torch / RSL-RL | 3.12.13 / 2.10.0+cu128 / 5.0.1 |

The Isaac Lab image is a beta track selected because this exact image bundled
the tested Isaac Sim build and shipped both `physx` and `newton_mjwarp`
presets. All scripts allow the image reference to be overridden. Host
differences are material confounders for cross-system timing.

The RTX PRO 5000 evidence records repository commit
`1166bc6d6a5e446d76498b68a8fa59ee069a07ab`. The existing public RTX PRO 6000
artifacts do not independently identify a commit, so commit equality is not
claimed.

## Result Snapshot

| Test | RTX PRO 5000 Blackwell | RTX PRO 6000 Blackwell reference |
|---|---|---|
| T0 inventory/CDI | **PASS** | **PASS** |
| T1 launch/streaming | **SPLIT:** compatibility and warm Full Streaming passed; cold Full Streaming failed in `await_viewport` | **PASS:** compatibility and cold/warm Full Streaming passed |
| T2 GPU PhysX | **PASS:** 1,024 bodies, 600/600 steps on `cuda:0`; documented process-exit lifecycle limitation | **PASS:** same matched workload; native shutdown limitation |
| T3 PhysX soak | **PASS:** 3/3 seeds and 393,216,000 transitions | **PASS:** 3/3 seeds and 393,216,000 transitions |
| T4 tiled cameras | **SPLIT:** standalone no RGB; Full Streaming 600/600 | **SPLIT:** standalone no RGB; Full Streaming 600/600 |
| T5 CosmosWriter | **SPLIT:** standalone 55/60; Full Streaming 60/60 for five modalities | **SPLIT:** standalone 56/60; Full Streaming 60/60 for five modalities |
| T6 PhysX/Newton | **PASS:** 6/6 runs; Newton reported 1.39x PhysX training throughput | **PASS:** 6/6 runs; Newton reported 2.62x PhysX training throughput |
| T6 visual replay | **PASS:** 16 Newton Ant agents visibly moving | **PASS:** 16-environment Newton replay visibly moving |

These split results matter. A pass in Full Streaming does not erase the
standalone T4/T5 failures. Performance values are end-to-end observations from
unlike hosts, not isolated GPU rankings. See the
[RTX PRO 5000 result](results/rtx-pro-5000-tested-configuration.md) and
[RTX PRO 6000 reference](results/tested-configuration.md) for measurements,
warnings, and limitations.

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

`deploy/start.sh` expects its runtime cache tree to remain writable by the
launching user. If an earlier container leaves root-owned cache entries, repair
the local cache ownership or select fresh runtime directories before relaunch.

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
results/    Curated, sanitized results from the documented runs
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
- Results apply only to each documented system. Cross-system timing cannot
  isolate GPU performance because host CPU, RAM, virtualization, kernel,
  storage, and cache conditions differed.

## Upstream Documentation

- [Isaac Sim container installation](https://docs.isaacsim.omniverse.nvidia.com/latest/installation/install_container.html#isaac-sim-app-install-container)
- [Isaac Lab documentation](https://isaac-sim.github.io/IsaacLab/)

Isaac Sim, Isaac Lab, CUDA, PhysX, RTX, and NVIDIA are trademarks or products
of NVIDIA Corporation. This repository is an independent test record and is
not an official certification.
