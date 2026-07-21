# Reference Results: RTX PRO 6000 Blackwell

## Scope

These results were collected on one VM on 2026-07-20 and 2026-07-21. The
workloads were synthetic risk baselines. No third-party failure reproduction or
project scene was available.

## Configuration

| Component | Value |
|---|---|
| GPU | NVIDIA RTX PRO 6000 Blackwell Server Edition |
| GPU exposure | Full PCIe pass-through, 97,887 MiB framebuffer, MIG inactive |
| Guest | Ubuntu 22.04.5 LTS, kernel 5.15.0-181-generic |
| Compute | 32 vCPU, 62 GiB RAM |
| Driver | 595.84, reporting CUDA 13.2 compatibility |
| Docker | 29.6.0 |
| NVIDIA Container Toolkit | 1.19.1, CDI devices present |
| Isaac Sim | 6.0.1, Kit 110.1.2, PhysX 110.1.13, Warp 1.13.0 |
| Isaac Lab | 3.0.0 beta2 post1, bundled Isaac Sim 6.0.1 release candidate build |
| Isaac Lab Python stack | Python 3.12.13, Torch 2.10.0+cu128, Warp 1.13.0, RSL-RL 5.0.1 |

## Matrix

| Test | Result | Key evidence | Limitation |
|---|---|---|---|
| T0 inventory | PASS | Full pass-through GPU, rendering and NVENC exposed | Host hypervisor details unavailable |
| T1 clean launch | PASS | Compatibility check, cold/warm launch, WebRTC and NVENC media | Exact image and VM only |
| T2 GPU PhysX | PASS with lifecycle limitations | 1,024 bodies, 600/600 steps, GPU dynamics/broadphase on `cuda:0`, no targeted CUDA/fallback signature or Xid | Native Kit shutdown hung; recurring nonfatal driver reference-state warning; not a performance baseline |
| T3 PhysX soak | PASS | 16,384 environments, 250 PPO iterations, three seeds, 393,216,000 transitions | Synthetic Ant articulation/contact task on a beta Isaac Lab release |
| T4 tiled cameras | SPLIT | Standalone normal-camera control returned no RGB; Full Streaming delivered 600/600 buffers from 16 tiled cameras at 320 x 240 | 64 cameras, 640 x 480, and exact cross-surface controls remain open |
| T5 CosmosWriter | SPLIT | Standalone delivered 56/60 frames; Full Streaming delivered 60/60 for five modalities, 300 PNGs, and five 60-frame H.264 videos | Depth output was colorized rather than raw metric depth |
| T6 PhysX/Newton | PASS for frozen comparison | Three runs per backend; 78,643,200 transitions total; clean targeted scans and native exits | Different shipped solver blocks; no convergence or numerical-equivalence claim |
| T6 visual replay | PASS for manual observation | Seed checkpoint, 16 Newton environments, real-time policy inference, visible motion through WebRTC | Separate from measured A/B; no camera-observation validation |

## T3 Aggregate

- Runs: 3/3 passing.
- Environments: 16,384 per run.
- PPO iterations: 250 per run.
- Transitions: 131,072,000 per seed; 393,216,000 total.
- Reported training time: 2,124.90 seconds total.
- Peak sampled GPU utilization: 60%.
- Peak sampled framebuffer use: 10,225 MiB.
- Targeted CUDA/PhysX/fallback scan: no matches.
- Kernel Xid scan: no matches.

## T6 Aggregate

| Metric | PhysX | Newton MJWarp |
|---|---:|---:|
| Passing runs | 3/3 | 3/3 |
| Completed transitions | 39,321,600 | 39,321,600 |
| Total reported training time | 622.33 s | 237.56 s |
| Mean training throughput | 63,184 transitions/s | 165,523 transitions/s |
| Total per-run wall time | 841 s | 916 s |
| Mean simulation-start time | 30.86 s | 165.74 s |
| Peak sampled GPU utilization | 17% | 20% |
| Peak sampled framebuffer use | 6,283 MiB | 3,659 MiB |
| Peak sampled power | 99.51 W | 112.83 W |
| Mean final reward at iteration 99 | 3,000.53 | 2,580.59 |
| Mean final episode length at iteration 99 | 825.28 | 602.75 |

For this exact task and 100-iteration envelope, Newton reported 2.62 times
PhysX training throughput. Its mean simulation-start time was 5.37 times
longer, making its summed cold wall time 8.9% longer. Fresh cache directories
were used symmetrically, so this does not predict warm persistent-service
startup.

Final reward and episode length varied by backend and seed. One hundred PPO
iterations do not establish convergence, policy parity, or solver equivalence.

## Open Follow-Up

- Root-cause the T2 native shutdown and driver warning separately.
- Compare identical sensor APIs and launch surfaces for T4/T5.
- Test raw metric depth, larger camera matrices, and longer writer loads.
- Test Newton rendered sensors, center-of-mass APIs, warm services, and other
  shipped Newton backends where required.
- Replace synthetic tasks with representative robots, contacts, sensors, and
  scene content before making deployment decisions.
