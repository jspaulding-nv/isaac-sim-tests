#!/usr/bin/env python3
"""Crop a replay GIF and discard source metadata before publication."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageSequence


def parse_crop(value: str) -> tuple[int, int, int, int]:
    try:
        crop = tuple(int(part) for part in value.split(","))
    except ValueError as error:
        raise argparse.ArgumentTypeError("crop must contain four integers") from error
    if len(crop) != 4:
        raise argparse.ArgumentTypeError("crop must be LEFT,TOP,RIGHT,BOTTOM")
    left, top, right, bottom = crop
    if min(crop) < 0 or right <= left or bottom <= top:
        raise argparse.ArgumentTypeError("crop bounds must define a positive rectangle")
    return left, top, right, bottom


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a publication-safe GIF using a fixed pixel crop."
    )
    parser.add_argument("input", type=Path, help="Source GIF")
    parser.add_argument("output", type=Path, help="Sanitized GIF")
    parser.add_argument(
        "--crop",
        type=parse_crop,
        required=True,
        metavar="LEFT,TOP,RIGHT,BOTTOM",
        help="Crop rectangle in source pixels",
    )
    parser.add_argument(
        "--start-frame",
        type=int,
        default=0,
        help="Discard frames before this zero-based index (default: 0)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.input.is_file():
        raise SystemExit(f"Input GIF does not exist: {args.input}")

    with Image.open(args.input) as source:
        if source.format != "GIF":
            raise SystemExit(f"Input is not a GIF: {args.input}")
        width, height = source.size
        left, top, right, bottom = args.crop
        if right > width or bottom > height:
            raise SystemExit(f"Crop {args.crop} exceeds source dimensions {source.size}")

        default_duration = source.info.get("duration", 100)
        loop = source.info.get("loop", 0)
        source_frame_count = getattr(source, "n_frames", 1)
        if not 0 <= args.start_frame < source_frame_count:
            raise SystemExit(
                f"--start-frame must be between 0 and {source_frame_count - 1}"
            )
        frames: list[Image.Image] = []
        durations: list[int] = []
        for index, frame in enumerate(ImageSequence.Iterator(source)):
            if index < args.start_frame:
                continue
            durations.append(frame.info.get("duration", default_duration))
            frames.append(frame.convert("RGB").crop(args.crop))

    if not frames:
        raise SystemExit("Input GIF contains no frames")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        args.output,
        format="GIF",
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=loop,
        disposal=1,
        optimize=True,
    )

    with Image.open(args.output) as result:
        if result.size != (right - left, bottom - top):
            raise SystemExit(f"Output dimensions are incorrect: {result.size}")
        output_frames = getattr(result, "n_frames", 1)
        output_duration = sum(
            frame.info.get("duration", 0) for frame in ImageSequence.Iterator(result)
        )
        if output_duration != sum(durations):
            raise SystemExit(
                f"Playback-duration mismatch: expected {sum(durations)} ms, "
                f"wrote {output_duration} ms"
            )

    print(
        f"Wrote {args.output}: {len(frames)}/{source_frame_count} source frames, "
        f"{output_frames} encoded frames, "
        f"{right - left}x{bottom - top}, {sum(durations)} ms"
    )


if __name__ == "__main__":
    main()
