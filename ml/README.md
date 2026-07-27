# TapQ-1 training pipeline

Training and Core ML export for **TapQ-1 stage 1**: a ~70k-parameter
LIMU-BERT-style transformer that classifies 1.28 s windows of AirPods head-motion
IMU (25 Hz, 9 channels) into gesture atoms — `quiet`, `nod`, `shake`,
`tilt_left`, `tilt_right`, `tap`, `swipe_up`, `swipe_down`. The Swift runtime
(`EncoderMotionPipeline`) turns those window scores into the same doubled
commands as the deterministic heuristics, which remain the offline fallback.

## The contract

`tapq1/layout.py` mirrors `Sources/TapQDetectionBaseline/EncoderContract.swift`
exactly: channel order, fixed physical scaling (accel ÷ 2 g, gyro ÷ 8 rad/s,
gravity as-is, all clipped to [-1, 1]), window length 32, and class order.
The Swift test suite pins these values; exported models embed the layout version
in metadata and `CoreMLMotionScorer` refuses to load a mismatch. Change the
contract only by bumping `VERSION` on both sides.

Label semantics: a segment spans the **complete command** the wearer performed.
A `nod` segment covers the full double nod; a `tap` segment covers the full
double tap (both transients fit inside one window, so the model learns the
doubled pattern for taps, while nod/tilt doubling stays deterministic in Swift).
Confounder recordings (bud adjustments, scratching, desk motion, typing) go in
the manifest **without** label files — their windows train `quiet` and drive
pretraining.

## Setup

```sh
cd ml
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Workflow

1. **Record** with the Phase 0 tooling (per-axis format is required):

   ```sh
   tapq capture --duration 60 --output data/session-01.jsonl
   ```

2. **Label** each recording as JSONL segments in the capture's own timestamp
   clock (same format `tapq replay --labels` consumes):

   ```json
   {"start": 12.4, "end": 14.1, "label": "nod"}
   ```

3. **Manifest** — `data/manifest.json`, paths relative to the manifest:

   ```json
   [
     {"capture": "session-01.jsonl", "labels": "session-01.labels.jsonl"},
     {"capture": "confounders-desk.jsonl"}
   ]
   ```

4. **Pretrain** on everything (masked reconstruction, no labels needed):

   ```sh
   python -m tapq1.pretrain --manifest data/manifest.json --out checkpoints/pretrained.pt
   ```

5. **Train** the joint head (time-warp/rotation/noise augmentation built in):

   ```sh
   python -m tapq1.train --manifest data/manifest.json \
       --pretrained checkpoints/pretrained.pt --out checkpoints/tapq1.pt
   ```

6. **Export** to Core ML with the embedded contract:

   ```sh
   python -m tapq1.export --checkpoint checkpoints/tapq1.pt --out models/tapq1.mlpackage
   ```

7. **Evaluate offline** against the heuristic baseline on held-out recordings —
   the go/no-go gate before the model ever runs live:

   ```sh
   tapq replay --input data/holdout.jsonl --labels data/holdout.labels.jsonl \
       --encoder-model models/tapq1.mlpackage
   ```

8. **Shadow live**, then promote only after the diagnostics agree:

   ```sh
   tapq serve --encoder-model models/tapq1.mlpackage                        # shadow (default)
   tapq serve --encoder-model models/tapq1.mlpackage --encoder-mode primary
   ```

## Smoke test

No captured data yet? Verify the whole pipeline on synthetic motion:

```sh
python -m tapq1.smoke                                    # train + budget checks
python -m tapq1.smoke --export /tmp/tapq1-smoke.mlpackage  # + Core ML export
```

The smoke export is also the quickest way to exercise `tapq replay
--encoder-model` and the serve shadow mode before real training.

## Privacy

Raw captures and checkpoints stay local; nothing here uploads anything. Keep
`data/` and `checkpoints/` out of version control.
