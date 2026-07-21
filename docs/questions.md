# Original Risk Questions

These tests began as research questions about potential problems that might be
encountered in a future robotics and digital-twin implementation. There was no
hardware reproduction, customer scene, observed failure, or measured failure
window. The questions are retained here without project or personal names.

## Questions This VM Can Address

| Priority | Question | What one VM can establish |
|---|---|---|
| 1 | Replicator tiled-camera hang | Whether minimal normal and tiled-camera workloads launch, deliver frames, and scale without hanging on the tested stack. |
| 2 | CosmosWriter on Blackwell | Whether video creation and required RGB, depth, segmentation, and edge outputs are complete and internally consistent. |
| 3 | GPU PhysX CUDA error 719 | Whether repeated fixed workloads keep GPU PhysX active without error 719, another targeted CUDA signature, or observed CPU fallback. |
| 4 | Current software stack | A precise tested configuration covering the GPU, VM mode, OS, driver, containers, Isaac Sim, Isaac Lab, PhysX, Torch, Warp, Replicator, and CosmosWriter. |
| 5 | Isaac Sim 6.0 and Newton | A same-task comparison of the shipped PhysX and Newton MJWarp presets, including launch, stability, throughput, startup, memory, and visual replay. |

## Questions One VM Cannot Answer

- It cannot validate a different GPU model.
- It cannot establish an official supported or certified stack.
- It cannot identify the root cause of a third-party failure without that
  reproduction, scene, configuration, and logs.
- Synthetic tasks cannot certify a future project workload.
- A short RL run cannot establish convergence parity or physics equivalence.
- Performance from a cold container/cache procedure does not predict every
  persistent service or orchestration environment.
- It cannot provide an engineering ETA or product commitment.

## Safe Interpretation

Report the exact configuration, scale, seeds, steps, duration, and signatures
observed. Prefer statements such as:

> The workload completed on the documented configuration for the stated
> envelope without the targeted failure signatures.

Avoid broad claims such as "Blackwell is fixed," "error 719 cannot happen," or
"Newton is a complete replacement for PhysX."
