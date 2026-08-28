#!/usr/bin/env python3
"""Decode the pinned LM-028 corpus with FFmpeg's software HEVC decoder only."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import time
from typing import Any


FFMPEG = Path("/opt/homebrew/bin/ffmpeg")
FFPROBE = Path("/opt/homebrew/bin/ffprobe")
ITERATIONS = 30
LONG_EDGE_PIXELS = 1_920 * 1_080
FIXTURES = (
    {
        "name": "libheif-example.heic",
        "sha256": "7f8b363e4936c0666a25f64f3a92fda10bd8e5453be4592530b65a55dd98f3f2",
        "width": 1_280,
        "height": 854,
        "weight": 0.10,
    },
    {
        "name": "libheif-ui-alpha.heic",
        "sha256": "dac399d3bf1019baaf5f88eef8b277087d0643e735db947c42355237bb9d0221",
        "width": 512,
        "height": 512,
        "weight": 0.45,
    },
    {
        "name": "libheif-ui-rainbow.heic",
        "sha256": "4b2ce727f093944975f143ba2b39c4c64511b766d94552f8d51a755916e7f983",
        "width": 451,
        "height": 461,
        "probeWidth": 452,
        "probeHeight": 462,
        "weight": 0.45,
    },
)


def run(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"},
    )


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * quantile) - 1)
    return ordered[index]


def verify_probe(path: Path, expected: dict[str, Any]) -> dict[str, Any]:
    completed = run(
        [
            str(FFPROBE),
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,width,height,pix_fmt",
            "-of",
            "json",
            str(path),
        ]
    )
    streams = json.loads(completed.stdout)["streams"]
    if len(streams) != 1:
        raise RuntimeError(f"{path.name}: expected one primary image")
    stream = streams[0]
    if stream["codec_name"] != "hevc":
        raise RuntimeError(f"{path.name}: expected HEVC payload")
    expected_width = expected.get("probeWidth", expected["width"])
    expected_height = expected.get("probeHeight", expected["height"])
    if stream["width"] != expected_width or stream["height"] != expected_height:
        raise RuntimeError(f"{path.name}: dimension mismatch")
    return stream


def decode_once(path: Path) -> str:
    completed = run(
        [
            str(FFMPEG),
            "-v",
            "error",
            "-hwaccel",
            "none",
            "-threads",
            "1",
            "-c:v",
            "hevc",
            "-i",
            str(path),
            "-map",
            "0:v:0",
            "-f",
            "framemd5",
            "-",
        ]
    )
    frame_lines = [line for line in completed.stdout.splitlines() if line.startswith("0,")]
    if len(frame_lines) != 1:
        raise RuntimeError(f"{path.name}: expected exactly one decoded frame")
    return frame_lines[0].rsplit(",", 1)[1].strip()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: measure-lm028-software-decode.py FIXTURE_ROOT OUTPUT_JSON")
    fixture_root = Path(sys.argv[1]).resolve(strict=True)
    output_path = Path(sys.argv[2]).resolve()
    if not FFMPEG.is_file() or not FFPROBE.is_file():
        raise RuntimeError("pinned local FFmpeg tools are unavailable")

    version = run([str(FFMPEG), "-version"]).stdout.splitlines()[0]
    measurements: list[dict[str, Any]] = []
    weighted_bytes_per_pixel = 0.0
    for expected in FIXTURES:
        path = fixture_root / expected["name"]
        payload = path.read_bytes()
        digest = hashlib.sha256(payload).hexdigest()
        if digest != expected["sha256"]:
            raise RuntimeError(f"{path.name}: fixture digest mismatch")
        stream = verify_probe(path, expected)
        latencies: list[float] = []
        pixel_hashes: set[str] = set()
        for _ in range(ITERATIONS):
            started = time.perf_counter_ns()
            pixel_hashes.add(decode_once(path))
            latencies.append((time.perf_counter_ns() - started) / 1_000_000)
        if len(pixel_hashes) != 1:
            raise RuntimeError(f"{path.name}: decoded pixels were nondeterministic")
        weighted_bytes_per_pixel += expected["weight"] * len(payload) / (
            expected["width"] * expected["height"]
        )
        measurements.append(
            {
                "name": path.name,
                "sha256": digest,
                "byteCount": len(payload),
                "width": stream["width"],
                "height": stream["height"],
                "pixelFormat": stream["pix_fmt"],
                "decodedPixelMD5": next(iter(pixel_hashes)),
                "iterations": ITERATIONS,
                "p50Milliseconds": round(percentile(latencies, 0.50), 3),
                "p95Milliseconds": round(percentile(latencies, 0.95), 3),
                "p99Milliseconds": round(percentile(latencies, 0.99), 3),
            }
        )

    projected_mean = math.ceil(weighted_bytes_per_pixel * LONG_EDGE_PIXELS)
    result = {
        "schemaVersion": 1,
        "decoder": "FFmpeg software hevc (-hwaccel none, one thread)",
        "ffmpegVersion": version,
        "encoderInvocations": 0,
        "videoToolboxInvocations": 0,
        "corpus": measurements,
        "weightedCorpus": {
            "highEntropyWeight": 0.10,
            "uiWeight": 0.90,
            "projectedMeanBytesAt1920x1080": projected_mean,
        },
        "maximumResidentBytes": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=output_path.parent, delete=False
    ) as temporary:
        json.dump(result, temporary, indent=2, sort_keys=True)
        temporary.write("\n")
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, output_path)


if __name__ == "__main__":
    main()
