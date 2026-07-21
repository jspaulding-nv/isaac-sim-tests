#!/usr/bin/env python3
"""Build a deterministic T5 CosmosWriter modality contact sheet."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


MODALITIES = (
    ("rgb", "RGB"),
    ("shaded_seg", "Shaded segmentation"),
    ("segmentation", "Semantic segmentation"),
    ("depth", "Colorized depth"),
    ("edges", "Edges"),
)
SOURCE_SIZE = (1280, 720)
FRAME_COUNT = 60
MARGIN = 32
GAP = 24
HEADER_HEIGHT = 126
LABEL_HEIGHT = 58
FOOTER_HEIGHT = 64
BACKGROUND = "#0d1117"
PANEL_BACKGROUND = "#161b22"
TEXT = "#f0f6fc"
MUTED_TEXT = "#9da7b3"
BORDER = "#30363d"


def load_font(size: int, bold: bool = False) -> ImageFont.ImageFont:
    filename = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    path = Path("/usr/share/fonts/truetype/dejavu") / filename
    if path.exists():
        return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Combine one synchronized T5 frame from all five modalities."
    )
    parser.add_argument("clip_dir", type=Path, help="Path to the CosmosWriter clip_0000 directory")
    parser.add_argument("--frame", type=int, default=30, help="Zero-based frame index (default: 30)")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("media/t5-cosmoswriter.png"),
        help="Output PNG path",
    )
    return parser.parse_args()


def source_path(clip_dir: Path, modality: str, frame: int) -> Path:
    return clip_dir / modality / f"{modality}_{frame:04d}.png"


def main() -> None:
    args = parse_args()
    if not 0 <= args.frame < FRAME_COUNT:
        raise SystemExit(f"--frame must be between 0 and {FRAME_COUNT - 1}")

    sources = [(source_path(args.clip_dir, key, args.frame), label) for key, label in MODALITIES]
    missing = [str(path) for path, _ in sources if not path.is_file()]
    if missing:
        raise SystemExit("Missing source images:\n" + "\n".join(missing))

    panel_width, image_height = SOURCE_SIZE
    panel_height = LABEL_HEIGHT + image_height
    canvas_width = (MARGIN * 2) + (panel_width * 3) + (GAP * 2)
    canvas_height = HEADER_HEIGHT + (panel_height * 2) + GAP + FOOTER_HEIGHT
    canvas = Image.new("RGB", (canvas_width, canvas_height), BACKGROUND)
    draw = ImageDraw.Draw(canvas)

    title_font = load_font(42, bold=True)
    subtitle_font = load_font(24)
    label_font = load_font(28, bold=True)
    footer_font = load_font(22)

    draw.text((MARGIN, 24), "T5-C CosmosWriter synchronized outputs", fill=TEXT, font=title_font)
    draw.text(
        (MARGIN, 78),
        f"Frame {args.frame:04d} of {FRAME_COUNT:04d} | {SOURCE_SIZE[0]} x {SOURCE_SIZE[1]} per modality",
        fill=MUTED_TEXT,
        font=subtitle_font,
    )

    top_positions = [MARGIN + index * (panel_width + GAP) for index in range(3)]
    second_row_width = (panel_width * 2) + GAP
    second_row_start = (canvas_width - second_row_width) // 2
    bottom_positions = [second_row_start, second_row_start + panel_width + GAP]
    positions = [
        (top_positions[0], HEADER_HEIGHT),
        (top_positions[1], HEADER_HEIGHT),
        (top_positions[2], HEADER_HEIGHT),
        (bottom_positions[0], HEADER_HEIGHT + panel_height + GAP),
        (bottom_positions[1], HEADER_HEIGHT + panel_height + GAP),
    ]

    for (path, label), (x, y) in zip(sources, positions, strict=True):
        with Image.open(path) as source:
            image = source.convert("RGB")
            if image.size != SOURCE_SIZE:
                raise SystemExit(f"Unexpected dimensions for {path}: {image.size}")
            draw.rectangle(
                (x - 1, y - 1, x + panel_width, y + panel_height),
                fill=PANEL_BACKGROUND,
                outline=BORDER,
                width=2,
            )
            draw.text((x + 18, y + 11), label, fill=TEXT, font=label_font)
            canvas.paste(image, (x, y + LABEL_HEIGHT))

    footer_y = canvas_height - FOOTER_HEIGHT + 17
    draw.text(
        (MARGIN, footer_y),
        "Depth is a colorized visualization, not raw metric depth. Source pixels are unaltered.",
        fill=MUTED_TEXT,
        font=footer_font,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.output, format="PNG", optimize=True, compress_level=9)
    print(f"Wrote {args.output} ({canvas_width}x{canvas_height})")


if __name__ == "__main__":
    main()
