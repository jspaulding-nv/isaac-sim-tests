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
| 1 | GPU-PhysX error 719 on Blackwell | **Partial:** repeated fixed workloads completed on the documented RTX PRO 5000 and RTX PRO 6000 Blackwell stacks without error 719, another targeted CUDA signature, an observed CPU fallback, or an Xid. |
| 2 | Isaac Sim 6.0 + Newton | **Partial:** the shipped PhysX and Newton MJWarp presets can be compared on one frozen task for launch, stability, throughput, startup, memory, and visual replay. This is not a feature-parity or production-readiness determination. |
| 3 | Replicator tiled-camera hang on `sm_120` | **Partial:** minimal normal and tiled-camera workloads can be checked for frame delivery, freshness, scaling, and hangs on the tested Full Streaming and standalone surfaces. |
| 4 | CosmosWriter SDG on Blackwell | **Partial:** RGB, colorized depth, segmentation, edge, and video outputs can be checked for completeness and internal consistency on the tested scene. |
| 5 | PRO 5000 specifically | **Partial:** a card-specific T0-T6 run now exists. Compatibility and warm Full Streaming passed, while cold Full Streaming failed health readiness in `await_viewport`. One system is not certification. |
| 6 | Current validated stack for PRO 5000 | **Partial:** the repository records the exact RTX PRO 5000 and RTX PRO 6000 Blackwell configurations. They are tested configurations, not an official supported-stack declaration. |
| 7 | PRO 5000 Blackwell versus RTX 6000 Ada | **Open:** the matched comparison is RTX PRO 5000 Blackwell versus RTX PRO 6000 Blackwell Server Edition. No RTX 6000 Ada was tested, and the Blackwell systems used unlike hosts. |

## Questions These Runs Cannot Answer

- They cannot validate a GPU model that was not tested.
- They cannot provide a GPU-only ranking from unlike host systems.
- They cannot establish an official supported or certified stack.
- They cannot identify the root cause of a third-party failure without that
  reproduction, scene, configuration, and logs.
- Synthetic tasks cannot certify a future project workload.
- A short RL run cannot establish convergence parity or physics equivalence.
- Performance from a cold container/cache procedure does not predict every
  persistent service or orchestration environment.
- They cannot provide an engineering ETA or product commitment.

## Safe Interpretation

Report the exact configuration, scale, seeds, steps, duration, and signatures
observed. Prefer statements such as:

> The workload completed on the documented configuration for the stated
> envelope without the targeted failure signatures.

Avoid broad claims such as "Blackwell is fixed," "error 719 cannot happen," or
"Newton is a complete replacement for PhysX."
