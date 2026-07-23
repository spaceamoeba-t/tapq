"""Loading `tapq capture` recordings and label segments into training windows.

Capture files come from `tapq capture --format jsonl|csv` (per-axis format from
Phase 0). Label files are the same JSONL segment format `tapq replay --labels`
consumes: {"start": s, "end": s, "label": "nod"}, in the capture's own timestamp
clock, where a segment spans the complete command (a `nod` segment covers the full
double nod, a `tap` segment the full double tap).
"""

import csv
import json
from pathlib import Path

import numpy as np

from . import layout

_AXIS_KEYS = [
    "user_acceleration_x", "user_acceleration_y", "user_acceleration_z",
    "rotation_rate_x", "rotation_rate_y", "rotation_rate_z",
    "gravity_x", "gravity_y", "gravity_z",
]


def load_capture(path):
    """Returns (timestamps [T], raw channels [T, 9]) in CHANNEL_NAMES order.

    Rejects magnitude-only captures from before per-axis capture: the encoder's
    contract needs signed axes.
    """
    path = Path(path)
    text = path.read_text()
    if path.suffix in (".jsonl", ".json") or text.lstrip().startswith("{"):
        rows = [json.loads(line) for line in text.splitlines() if line.strip()]
        _require_axis_fields(rows[0].keys() if rows else [], path)
        timestamps = np.array([row["timestamp"] for row in rows], dtype=np.float64)
        channels = np.array(
            [[row[key] for key in _AXIS_KEYS] for row in rows], dtype=np.float32)
    else:
        reader = csv.DictReader(text.splitlines())
        rows = list(reader)
        _require_axis_fields(reader.fieldnames or [], path)
        timestamps = np.array([float(row["timestamp"]) for row in rows], dtype=np.float64)
        channels = np.array(
            [[float(row[key]) for key in _AXIS_KEYS] for row in rows], dtype=np.float32)
    return timestamps, channels


def _require_axis_fields(fields, path):
    missing = [key for key in _AXIS_KEYS if key not in fields]
    if missing:
        raise ValueError(
            f"{path} lacks per-axis columns {missing}; re-record with a current "
            "`tapq capture` (magnitude-only captures cannot train the encoder)")


def load_labels(path):
    """Returns [(start, end, class_index)] sorted by start."""
    segments = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        label = record["label"]
        if label not in layout.CLASSES or label == "quiet":
            raise ValueError(f"unknown label '{label}' in {path}")
        start, end = float(record["start"]), float(record["end"])
        if start > end:
            raise ValueError(f"label segment start {start} is after end {end} in {path}")
        segments.append((start, end, layout.CLASSES.index(label)))
    return sorted(segments)


def windows(timestamps, channels, hop=8, gap_reset_seconds=0.5):
    """Slices a capture into scaled [N, WINDOW_LENGTH, 9] windows plus center times.

    Mirrors ``EncoderWindowBuilder``: windows never span a stream gap.
    """
    scaled = layout.scale(channels)
    length = layout.WINDOW_LENGTH
    starts, centers, slices = [], [], []
    run_start = 0
    for index in range(len(timestamps)):
        if index > 0 and (
            timestamps[index] < timestamps[index - 1]
            or timestamps[index] - timestamps[index - 1] > gap_reset_seconds
        ):
            run_start = index
        if index - run_start + 1 >= length and (index - run_start + 1 - length) % hop == 0:
            begin = index + 1 - length
            slices.append(scaled[begin:index + 1])
            starts.append(timestamps[begin])
            centers.append((timestamps[begin] + timestamps[index]) / 2)
    if not slices:
        return np.zeros((0, length, layout.CHANNEL_COUNT), np.float32), np.zeros(0)
    return np.stack(slices), np.array(centers)


def label_windows(centers, segments):
    """A window takes the class of the segment covering its center; quiet otherwise."""
    labels = np.zeros(len(centers), dtype=np.int64)
    for start, end, class_index in segments:
        labels[(centers >= start) & (centers <= end)] = class_index
    return labels


def load_manifest(path):
    """Manifest: JSON array of {"capture": path, "labels": path?}. Paths are
    relative to the manifest file. Entries without labels contribute unlabeled
    windows (pretraining); labeled entries contribute (window, class) pairs.
    """
    manifest_path = Path(path)
    entries = json.loads(manifest_path.read_text())
    labeled_x, labeled_y, unlabeled = [], [], []
    for entry in entries:
        capture = manifest_path.parent / entry["capture"]
        timestamps, channels = load_capture(capture)
        x, centers = windows(timestamps, channels)
        if len(x) == 0:
            continue
        if entry.get("labels"):
            segments = load_labels(manifest_path.parent / entry["labels"])
            labeled_x.append(x)
            labeled_y.append(label_windows(centers, segments))
        else:
            unlabeled.append(x)

    empty = np.zeros((0, layout.WINDOW_LENGTH, layout.CHANNEL_COUNT), np.float32)
    return (
        np.concatenate(labeled_x) if labeled_x else empty,
        np.concatenate(labeled_y) if labeled_y else np.zeros(0, np.int64),
        np.concatenate(unlabeled) if unlabeled else empty,
    )
