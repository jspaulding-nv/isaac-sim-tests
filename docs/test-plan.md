# Test Plan

## Objective

Produce a reproducible record for Isaac Sim clean launch, GPU PhysX stability,
tiled cameras, CosmosWriter output, and a same-task PhysX/Newton comparison on
one fully documented GPU VM.

This is proactive platform qualification. It is not incident reproduction,
official certification, or validation of an unstated project workload.

## Change Control

1. Start with read-only discovery.
2. Do not change the GPU driver, Docker daemon, CUDA stack, or system packages
   as part of a test run.
3. Pin container image references and capture image digests.
4. Use a new output directory and refuse to overwrite prior evidence.
5. Record exact workload parameters, seeds, start/finish times, and exit codes.
6. Scan logs for targeted failure signatures and kernel Xids.
7. Keep browser replay outside headless performance measurements.
8. Review generated evidence for private data before publication.

## Common Failure Signatures

At minimum, scan for:

```text
error 719
cudaErrorLaunchFailure
PhysX Internal CUDA error
illegal memory access
CUDA context validation failed
switching to software
GPU solver pipeline failed
GPU Bp pipeline failed
NVRM: Xid
```

## T0: Environment Inventory

**Goal:** Establish exactly what is being tested.

Capture the GPU model, virtualization mode, framebuffer, MIG state, guest OS,
kernel, CPU/RAM, driver, Docker, NVIDIA Container Toolkit, image references,
application versions, and available disk.

```bash
./scripts/collect_inventory.sh
```

**Pass:** GPU identity, resources, driver, and container runtime are
unambiguous.

## T1: Isaac Sim Clean Launch and WebRTC

**Goal:** Confirm compatibility, headless startup, renderer selection, and
browser streaming.

```bash
./scripts/run_compatibility.sh
cp deploy/.env.example deploy/.env
./deploy/start.sh
./deploy/status.sh
```

Observe the exact ready marker in the Kit log and connect to the configured
viewer URL. Record cold and warm startup separately.

**Pass:** Isaac Sim reaches ready state on the intended GPU without a fatal
startup error and the browser receives NVENC media.

## T2: GPU PhysX Smoke

**Goal:** Verify that a known rigid-body workload uses GPU dynamics and the GPU
broadphase on `cuda:0` without a targeted fallback or CUDA failure.

Default workload:

- 1,024 dynamic rigid bodies.
- 600 simulation steps.
- Deterministic seed.
- GPU broadphase and dynamics explicitly enabled.

```bash
./scripts/run_gpu_physx_smoke.sh
```

**Pass:** All steps complete, expected PhysX/CUDA markers are present, the
targeted signature scan is clean, and no kernel Xid is observed.

Treat shutdown behavior as a separate lifecycle result from workload success.

## T3: Isaac Lab GPU PhysX Soak

**Goal:** Exercise articulated bodies and contacts across repeated RL runs.

Start with preflight and a low-cost gate:

```bash
./scripts/run_isaac_lab_preflight.sh
NUM_ENVS=1024 MAX_ITERATIONS=5 ./scripts/run_isaac_lab_training.sh
```

Then run the frozen soak or override it for available hardware:

```bash
NUM_ENVS=16384 MAX_ITERATIONS=250 \
SEEDS_CSV=20260720,20260721,20260722 \
./scripts/run_physx_soak.sh
```

**Pass:** Every seed reaches the planned transition count with `cuda:0`, PhysX
backend, environment-count, and final-step markers; no targeted signature or
Xid is found.

## T4: Tiled-Camera Progression

**Goal:** Detect where camera creation, rendering, synchronization, or buffer
delivery stops making progress.

The default progression is:

1. One normal camera at 320 x 240.
2. One tiled camera at 320 x 240.
3. Sixteen tiled cameras at 320 x 240.
4. Sixty-four tiled cameras at 320 x 240.
5. Sixty-four tiled cameras at 640 x 480.

```bash
./scripts/run_tiled_camera_progression.sh
```

The harness stops at the first failed stage and preserves watchdog state.

For a browser-visible 16-camera replay:

```bash
docker compose --env-file deploy/.env -p isaacsim-tests \
  -f deploy/docker-compose.yml \
  -f deploy/docker-compose.visible-tiled.yml \
  up -d --force-recreate
```

**Pass:** Correctly shaped, nonempty, distinct buffers arrive for every camera
for the planned frame count without a hang or targeted CUDA/Warp signature.

## T5: CosmosWriter

**Goal:** Separate encoding success from ground-truth integrity.

Run the one-line headless variant of the preserved reference:

```bash
./scripts/run_cosmos_writer_headless.sh
```

Run the equivalent workload inside Full Streaming:

```bash
./scripts/run_cosmos_writer_streaming.sh
```

Validate all 60 planned frames for RGB, shaded segmentation, semantic
segmentation, colorized depth, and edges. Independently decode each H.264 file
and compare selected decoded frames with their PNG sources.

**Pass:** Every modality has 60 correctly named 1280 x 720 PNGs, five videos
decode to 60 frames, known semantic colors are present, frames are fresh, and
segmentation/edge geometry is aligned.

Colorized depth is not raw metric depth and must not be reported as such.

## T6: Newton MJWarp Versus PhysX

**Goal:** Compare the shipped backend presets with the same task, trainer,
seeds, environment count, iterations, and image.

Gate Newton first:

```bash
PHYSICS_PRESET=newton_mjwarp EXPECTED_BACKEND=newton \
NUM_ENVS=1024 MAX_ITERATIONS=5 \
./scripts/run_isaac_lab_training.sh
```

Run the frozen alternating-order comparison:

```bash
NUM_ENVS=4096 MAX_ITERATIONS=100 \
SEEDS_CSV=20260720,20260721,20260722 \
./scripts/run_backend_comparison.sh
```

Compare completed runs, transitions, training time/throughput, cold wall time,
simulation startup, memory, power, and final reward. Do not interpret reward
differences as solver equivalence or convergence parity.

After training, replay one Newton checkpoint through the browser:

```bash
PUBLIC_IP=<trusted-host-address> \
SOURCE_CHECKPOINT=/absolute/path/to/model_99.pt \
./scripts/start_newton_visual_replay.sh
```

**Pass:** Both backends complete every frozen run with backend-specific
markers, planned transitions, clean targeted scans, and native exit. The visual
replay is a separate human-observation check.

## Reporting

For each test report `PASS`, `FAIL`, `BLOCKED`, or `INCONCLUSIVE`, followed by:

- Exact image and digest.
- Workload, scale, seeds, steps/iterations, and duration.
- Positive backend/device/final-step evidence.
- Targeted signature and Xid scan status.
- Warnings and lifecycle findings.
- What was not tested.

Never generalize a result beyond the documented hardware, stack, and workload.
