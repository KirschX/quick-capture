#!/usr/bin/env python3
"""Trim recorded footage into an MP4, looping GIF and contact sheet. Requires ffmpeg."""

import argparse
import json
import math
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("recording", type=Path)
parser.add_argument("cuts", type=Path, help="JSON list of [start seconds, end seconds, speed]")
parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "build/demo/export")
args = parser.parse_args()
if not args.recording.is_file():
    parser.error(f"Recording not found: {args.recording}")
segments = json.loads(args.cuts.read_text())
if not segments:
    parser.error("Provide at least one cut")
for start, end, speed in segments:
    if not all(math.isfinite(n) for n in (start, end, speed)) or not (0 <= start < end and speed > 0):
        parser.error("Each cut needs finite values, 0 <= start < end, and speed > 0")
args.output.mkdir(parents=True, exist_ok=True)


def ffmpeg(*arguments):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *map(str, arguments)], check=True)


filters = []
for n, (start, end, speed) in enumerate(segments):
    filters.append(
        f"[0:v]trim=start={start}:end={end},setpts=(PTS-STARTPTS)/{speed},"
        f"scale=1280:-1:flags=lanczos,pad=iw:ceil(ih/2)*2:0:0,fps=20,setsar=1[s{n}]"
    )
filters.append(
    "".join(f"[s{n}]" for n in range(len(segments)))
    + f"concat=n={len(segments)}:v=1:a=0,tpad=stop_mode=clone:stop_duration=3,format=yuv420p[v]"
)
preview = args.output / "demo.mp4"
ffmpeg("-i", args.recording, "-filter_complex", ";".join(filters), "-map", "[v]",
       "-an", "-c:v", "libx264", "-crf", "18", "-movflags", "+faststart", preview)
ffmpeg("-i", preview, "-filter_complex",
       "fps=15,split[s][p];[p]palettegen=stats_mode=diff[pal];[s][pal]paletteuse=dither=bayer:bayer_scale=4",
       "-loop", "0", args.output / "demo.gif")
duration = sum((end - start) / speed for start, end, speed in segments) + 3
ffmpeg("-i", preview, "-vf", f"fps=1/{duration / 15},scale=480:-1,tile=3x5",
       "-frames:v", "1", args.output / "contact.jpg")
print(f"Review demo.mp4, demo.gif and contact.jpg in {args.output.resolve()} before publishing.")
