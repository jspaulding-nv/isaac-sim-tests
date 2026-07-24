# Visual Replay Media

Published browser captures and generated evidence visuals from the RTX PRO
6000 Blackwell reference run:

- `t2-gpu-physx.gif`: repeating 1,024-body GPU PhysX replay.
- `t4-tiled-cameras.gif`: 16-view tiled-camera replay and PASS overlay.
- `t5-cosmoswriter.png`: synchronized validated output modalities. Rebuild it
  from retained T5 output with:

  ```bash
  python3 scripts/build_t5_contact_sheet.py /path/to/clip_0000 \
    --frame 30 --output media/t5-cosmoswriter.png
  ```
- `t6-newton-ant.gif`: 16-environment Newton Ant policy replay.

The RTX PRO 5000 visual replays passed manual observation, but no sanitized
browser image or recording was retained for publication. Do not interpret
these reference captures as RTX PRO 5000 media.

The replay GIFs were cropped to remove browser chrome and unrelated UI. The
crop is deterministic and preserves frame timing:

```bash
python3 scripts/sanitize_replay_gif.py input.gif output.gif \
  --crop LEFT,TOP,RIGHT,BOTTOM [--start-frame N]
```

Parameters used for the published files:

| Output | Crop | Opening trim |
|---|---|---|
| `t2-gpu-physx.gif` | `31,83,671,443` | None |
| `t4-tiled-cameras.gif` | `79,94,641,505` | None |
| `t6-newton-ant.gif` | `31,83,671,443` | 4 frames |

Before committing media, inspect the complete browser frame for private IP
addresses, bookmarks, account avatars, hostnames, notifications, and unrelated
application content. Crop or redact those elements. Keep individual files
small enough for normal Git hosting; use Git LFS for large recordings.
