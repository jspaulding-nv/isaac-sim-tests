# Results: RTX PRO 5000 Blackwell

## Scope

These results were collected on one system on 2026-07-23 and 2026-07-24.
The workloads were synthetic risk baselines. No third-party failure
reproduction or representative project scene was available.

The matched workloads used the same driver, image digests, tasks, scales, and
seeds as the
[RTX PRO 6000 Blackwell reference](tested-configuration.md). T3 and T6 used
the same fresh-cache procedure. The RTX PRO 5000 evidence records repository
commit `1166bc6d6a5e446d76498b68a8fa59ee069a07ab`; the existing public RTX PRO
6000 artifacts do not independently identify a commit, so commit equality is
not claimed. The host CPU, RAM, virtualization exposure, kernel, storage, and
cache environment differed, so cross-system timing is not an isolated GPU
benchmark.

## Configuration

| Component | Value |
|---|---|
| GPU | NVIDIA RTX PRO 5000 Blackwell |
| GPU exposure | Full device, 48,935 MiB framebuffer, compute capability 12.0, ECC enabled, MIG disabled |
| Virtualization | `systemd-detect-virt` reported `none`; this records the observed exposure and does not prove physical ownership |
| System | Ubuntu 22.04.5 LTS, kernel 5.15.0-177-generic |
| Compute | AMD Ryzen 7 7800X3D, 16 logical CPUs, 124 GiB RAM |
| Driver | 595.84, reporting CUDA 13.2 compatibility |
| Docker | 29.6.0 |
| NVIDIA Container Toolkit | 1.19.1, CDI devices present |
| Repository | `1166bc6d6a5e446d76498b68a8fa59ee069a07ab` |
| Isaac Sim image | `nvcr.io/nvidia/isaac-sim@sha256:783444c706538aa76cf5126e911ddc5e618779e6105305ad4af4260362a30aa9` |
| Isaac Lab image | `nvcr.io/nvidia/isaac-lab@sha256:18b95be31ec02017fec4c7f1cf51aac9bb7ea9fd868d0f051f5d71837b54bc5f` |
| Isaac Sim | 6.0.1; Isaac Lab image bundled 6.0.1-rc.7 |
| Isaac Lab Python stack | Python 3.12.13, Torch 2.10.0+cu128, Warp 1.13.0, RSL-RL 5.0.1 |

## Matrix

| Test | Result | Key evidence | Limitation |
|---|---|---|---|
| T0 inventory | **PASS** | GPU identity, framebuffer, `sm_120`, rendering, NVENC, CDI, and CUDA container access verified | Hypervisor detector returned `none`; underlying ownership was not independently established |
| T1 compatibility | **PASS** | System check passed at 12.654 s; app ready at 12.680 s | Exact image and system only |
| T1 Full Streaming | **SPLIT** | Cold launch failed health readiness in `await_viewport` without a fatal, CUDA 719, or Xid; unchanged direct-Compose warm retry loaded at 29.011 s, became ready at 29.026 s, and passed WebRTC/input observation | Cold-launch root cause and wrapper cache-ownership issue remain open |
| T2 GPU PhysX | **PASS with lifecycle limitation** | 1,024 bodies, 600/600 steps, GPU dynamics and broadphase on `cuda:0`, no targeted CUDA/fallback signature or Xid | Documented one-shot process-exit path bypassed native framework shutdown |
| T2 visual replay | **PASS** | User observed 1,024 falling and resetting bodies; final controlled replay required no browser recovery action | Earlier blank observations were consistent with paused local playback but were not root-caused |
| T3 PhysX soak | **PASS** | 16,384 environments, 250 PPO iterations, three seeds, 393,216,000 transitions | Synthetic Ant task on a beta Isaac Lab track |
| T4 tiled cameras | **SPLIT** | Standalone normal-camera control produced no RGB; Full Streaming delivered 600/600 buffers from 16 tiled cameras at 320 x 240 | Standalone used the documented one-shot process-exit path; larger camera cases and representative scenes remain open |
| T5 CosmosWriter | **SPLIT** | Standalone delivered 55/60 frames; Full Streaming delivered and independently validated 60/60 frames for five modalities | Depth was colorized rather than raw metric depth |
| T6 PhysX/Newton | **PASS** | Three runs per backend; 78,643,200 transitions total; expected backend/device markers and native exits | Different shipped solver blocks; no convergence or numerical-equivalence claim |
| T6 visual replay | **PASS** | Seed checkpoint, 16 Newton environments, real-time policy inference, user-observed Ant motion | No sanitized browser capture or visual-performance telemetry was retained |

## T1 Launch and Streaming

The compatibility check passed and the application reported ready. The first
cold Full Streaming attempt remained in `await_viewport` and failed health
readiness without a fatal, CUDA 719, or Xid signature. A scripted warm retry
then encountered root-owned runtime-cache permission errors. This was a
wrapper/cache-ownership issue, not evidence of a GPU failure. An unchanged
direct-Compose warm retry loaded at 29.011 seconds, reported ready at 29.026
seconds, and passed WebRTC and input observation.

## T2 GPU PhysX

The matched workload used seed 20260720, 1,024 rigid bodies, 600 physics
steps at 1/60 s, `cuda:0`, GPU broadphase, GPU dynamics, and Fabric.

| Metric | Value |
|---|---:|
| Completed steps | 600/600 |
| Step wall time | 1.869862 s |
| Mean step time | 3.116437 ms |
| Simulated real-time factor | 5.347988x |
| Peak sampled GPU utilization | 45% |
| Peak sampled framebuffer | 770 MiB |
| Peak sampled power | 73.78 W |

The RTX PRO 6000 reference did not retain a comparable T2 timing baseline, so
no cross-system T2 performance ratio is reported.

Earlier browser attempts appeared blank while local video playback was paused.
Selecting Play restored the stream. The final controlled replay passed without
that recovery action; the earlier playback state was resolved operationally,
not root-caused.

## T3 PhysX Soak

- Runs: 3/3 passing.
- Environments: 16,384 per run.
- PPO iterations: 250 per run.
- Seeds: 20260720, 20260721, and 20260722.
- Transitions: 131,072,000 per seed; 393,216,000 total.
- Reported training time: 478.37 seconds total.
- Derived aggregate throughput: 821,991 transitions/s.
- Outer wall time: 676 seconds.
- Peak sampled GPU utilization: 92%.
- Peak sampled framebuffer use: 7,885 MiB.
- Peak sampled power: 194.50 W.
- Targeted CUDA/PhysX/fallback scan: no matches.
- Supplemental kernel Xid scan: no matches.

The RTX PRO 6000 reference completed the same transitions in 2,124.90 seconds,
or 185,052 derived transitions/s. The observed ratio was 4.442x. This is an
end-to-end ratio between unlike systems, not a GPU-only speedup.

## T4 and T5 Split Findings

T4 reproduced the reference surface split. The standalone one-camera control
returned no RGB after 120 warm-up updates. Full Streaming delivered 600/600
buffers from 16 tiled cameras at 320 x 240, with 0.088860-second first-buffer
latency and 19.896891 seconds of measured replay time. The user observed the
completed 600/600 mosaic. The browser video initially entered a paused local
playback state; server signaling and encoding remained active.

The T4 standalone control used the same documented one-shot process-exit
lifecycle path as T2 rather than native framework shutdown.

T5 standalone requested 60 frames but produced 55 frames per modality,
275 PNGs, and five 55-frame H.264 files after Replicator writer-drain
timeouts. The reference produced 56/60; one run per system is insufficient to
interpret the one-frame difference.

T5 Full Streaming produced 60/60 RGB, shaded-segmentation, semantic-
segmentation, colorized-depth, and edge frames: 300 PNGs and five independently
decoded 60-frame H.264 videos. Built-in and independent validation passed. The
successful run emitted 120 nonfatal graph-cycle warnings; their root cause was
not investigated.

## T6 Aggregate

Each backend used 4,096 environments, 100 PPO iterations, three seeds, and
39,321,600 transitions. All six runs passed.

| Metric | PhysX | Newton MJWarp |
|---|---:|---:|
| Passing runs | 3/3 | 3/3 |
| Completed transitions | 39,321,600 | 39,321,600 |
| Total reported training time | 99.11 s | 71.38 s |
| Mean training throughput | 396,747 transitions/s | 550,877 transitions/s |
| Total per-run wall time | 198 s | 348 s |
| Mean simulation-start time | 9.54 s | 61.35 s |
| Peak sampled GPU utilization | 59% | 59% |
| Peak sampled framebuffer use | 4,023 MiB | 1,399 MiB |
| Peak sampled power | 122.03 W | 139.13 W |
| Mean final reward at iteration 99 | 2,414.69 | 3,328.92 |
| Mean final episode length at iteration 99 | 810.37 | 694.64 |

For this exact task and 100-iteration envelope, Newton reported 1.388x PhysX
training throughput. Its mean simulation-start time was 6.427x as long, making
its summed cold wall time 1.758x as long.

The same within-system ratios on the RTX PRO 6000 reference were 2.620x
training throughput, 5.370x simulation startup, and 1.089x summed cold wall
time. Cross-system reported training-throughput ratios were 6.279x for PhysX
and 3.328x for Newton in favor of the RTX PRO 5000 test system. Host
differences are substantial, so none of these ratios isolate GPU performance.

Final reward and episode length varied by backend and seed. One hundred PPO
iterations do not establish convergence, policy parity, or solver equivalence.

## Warnings and Limitations

- Supplemental kernel-ring-buffer scans found no NVIDIA Xid after any
  applicable test. This bounded observation does not prove that CUDA 719 or an
  Xid cannot occur in a different or longer workload.
- Successful workloads had no targeted CUDA 719, illegal-memory,
  backend-fallback, or fatal signature. T4 and T5 standalone scans preserved
  their expected workload errors.
- A recurring nonfatal NVIDIA reference-state warning with status `0x00000056`
  appeared around rendering workloads and was also present in the RTX PRO 6000
  reference.
- The T6 visual replay recorded late stream-busy messages immediately before
  client disconnect, plus minor adapter and dynamic-transform compatibility
  warnings. The already-observed motion, targeted scan, Xid scan, and
  controlled teardown still passed.
- No representative customer robot, scene, sensor graph, contact workload, or
  original third-party failure reproduction was supplied.
- The maximum tested T3 scale was 16,384 environments; higher capacity was not
  tested.
- T5 did not test longer writer loads. T6 covered one Ant task and the two
  shipped presets only.
- This Blackwell-to-Blackwell comparison does not answer the open RTX 6000 Ada
  procurement question.

## Curated JSON

- [T3 PhysX soak](rtx-pro-5000-t3-physx-soak.json)
- [T4 tiled-camera replay](rtx-pro-5000-t4-tiled-camera-replay.json)
- [T5 CosmosWriter Full Streaming](rtx-pro-5000-t5-cosmos-full-streaming.json)
- [T6 backend comparison](rtx-pro-5000-t6-backend-comparison.json)
