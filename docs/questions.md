# Original Risk Questions

These tests began as research questions about potential problems that might be
encountered in a future robotics and digital-twin implementation. There was no
hardware reproduction, customer scene, observed failure, or measured failure
window. The questions are retained here without project or personal names.

## Source Inquiry and Current Coverage

The source inquiry is reproduced in recognizable, lightly edited form in the
root [question-coverage matrix](../README.md#questions-covered). The current
scope is summarized here.

| # | Source topic | What the current package can establish |
|---|---|---|
| 1 | GPU-PhysX error 719 on Blackwell | **Partial:** repeated fixed workloads can show whether GPU PhysX remains active without error 719, another targeted CUDA signature, or an observed CPU fallback on the documented RTX PRO 6000 stack. |
| 2 | Isaac Sim 6.0 + Newton | **Partial:** the shipped PhysX and Newton MJWarp presets can be compared on one frozen task for launch, stability, throughput, startup, memory, and visual replay. This is not a feature-parity or production-readiness determination. |
| 3 | Replicator tiled-camera hang on `sm_120` | **Partial:** minimal normal and tiled-camera workloads can be checked for frame delivery, freshness, scaling, and hangs on the tested Full Streaming and standalone surfaces. |
| 4 | CosmosWriter SDG on Blackwell | **Partial:** RGB, colorized depth, segmentation, edge, and video outputs can be checked for completeness and internal consistency on the tested scene. |
| 5 | PRO 5000 specifically | **Open:** no PRO 5000 was available. Clean launch on the RTX PRO 6000 is a control, not card-specific evidence. |
| 6 | Current validated stack for PRO 5000 | **Partial:** the repository records the exact RTX PRO 6000 configuration, but cannot convert it into a PRO 5000 or official supported-stack result. |
| 7 | PRO 5000 Blackwell versus RTX 6000 Ada | **Open:** neither a PRO 5000 nor an RTX 6000 Ada was tested. The same suite must be run on both cards for a defensible comparison. |

## Questions One VM Cannot Answer

- It cannot validate a different GPU model.
- It cannot recommend between two GPU models without matched runs on both.
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
