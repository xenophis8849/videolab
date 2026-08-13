# videolab

A restoration pipeline for low-resolution live-action video — DVD rips, old TV
recordings, home video (480i/576i/480p/576p/720p). It deinterlaces or reverses
telecine, removes compression artifacts, upscales 2×, and re-encodes to a
modern 10-bit master.

One command, one pass, no intermediate files:

```sh
./scripts/run_mvp1.sh input.mkv output.mkv
```

## Why this exists

Old low-resolution live-action material arrives with a specific set of injuries,
and they have to be undone in the right order: 3:2 pulldown or interlacing,
MPEG-2/H.264 compression artifacts, non-square pixels, BT.601 primaries. An
upscaler on its own addresses none of them, and the field/cadence step is the one
that decides everything downstream — run QTGMC on a film source and half the
frames you keep are interpolated from nothing.

The existing tools sit on either side of that gap. General upscaling front ends
are upscaler-plus-frame-interpolator: fixed ncnn backends, no way to bring your
own ONNX, and no inverse telecine at all. Restoration suites that do exist tend
to bundle photo-domain models and a YADIF-only deinterlacer. On the other end,
generative video restoration genuinely invents texture, but the standalone models
want a data-centre GPU; on 12 GB the community builds run around 4 s/frame, which
is roughly six days for a feature film.

What was missing was the unglamorous middle: a cadence-correct, end-to-end chain
that runs at roughly real time on one consumer GPU and leaves audio, subtitles
and chapters alone. This is that. It is deliberately opinionated — the model and
encoder choices below are the ones that won measured comparisons, not the ones
with the largest parameter count. A 1.6 MB upscale model trained on video
compression artifacts beats a 30 MB model trained on photographs and JPEG, by an
order of magnitude in PSNR and 23× in speed.

## What it does

```
① load source (BestSource)
② field handling, decided automatically from the source
     telecine    → VIVTC, restored to 23.976p
     interlaced  → QTGMC, double-rate 59.94p
     progressive → skipped
③ non-square pixel correction (DVD SAR 20:11 → square pixels)
④ compression-artifact removal (DPIR, TensorRT fp16)
⑤ 2× upscale (2xLiveActionV1_SPAN)
⑥ BT.601 → BT.709 with a real gamut conversion, 10-bit output
⑦ encode; audio, subtitles and chapters are passed through untouched
```

Field handling is decided from VFM's match sequence, not from a combing metric —
3:2 pulldown has a fixed c:p ≈ 60:40 distribution, and getting this wrong is the
difference between a clean 23.976p film transfer and interpolating half the
frames from nothing.

The whole chain is streamed (`vspipe | ffmpeg`). A 640×480 RGBS frame is 3.5 MB,
so an intermediate file for a 90-minute feature would be around 500 GB.

## Stack

| | |
| --- | --- |
| Runtime | Docker image `local/vsgpu:0.2.0`, built from `nvidia/cuda:12.8.1-base-ubuntu24.04` |
| Frame server | VapourSynth R78 + vsjetpack 2.2.0 (45 plugin namespaces) |
| Inference | vs-mlrt 16.1 on TensorRT 11.2.1 (ort_cuda / ncnn / ov available as fallbacks) |
| Models | DPIR (artifact removal), 2xLiveActionV1_SPAN (upscale) |
| Encoder | FFmpeg 8.1 — SVT-AV1 by default, `av1_nvenc` / `hevc_nvenc` selectable |

Versions are pinned in `docker/vsgpu/requirements.lock.txt`.

## Requirements

- Any CUDA-capable NVIDIA GPU, with the container toolkit installed. Nothing here
  is tied to a particular card — the TensorRT engine is built at runtime against
  whatever GPU it finds, and 12 GB is comfortable rather than required at these
  resolutions.
- Docker
- ~16 GB of disk for the image, ~500 MB for the model cache

## Deployment

**1. Build the runtime image**

```sh
sudo docker build -t local/vsgpu:0.2.0 docker/vsgpu/
```

**2. Warm the model cache** — run once; after this the pipeline runs with no network.

```sh
./scripts/prepare_models.sh
```

**3. Run**

```sh
./scripts/run_mvp1.sh input.mkv output.mkv
./scripts/run_mvp1.sh input.mkv output.mkv VL_ENCODER=hevc_nvenc VL_SVT_PRESET=6
```

Configuration is by `VL_*` variables, accepted either from the environment or as
`NAME=VALUE` arguments; see the header of `scripts/run_mvp1.sh`. The most useful
ones are `VL_ENCODER`, `VL_SVT_PRESET`, `VL_SVT_CRF`, `VL_IMAGE` and `VL_WORK`.

TensorRT engines are cached under `VL_WORK`; the first run at a new resolution
spends about 25 s building one, later runs start in under a second.

### Optional: two-machine setup

`scripts/restore-video` is a front end for the case where the GPU lives on a
different machine from where you work. It wakes the GPU node, holds it awake,
uploads each file, runs the chain, fetches the result back and cleans up the
remote staging directory. It takes a file or a directory (recursive), and picks
the output container from what the source actually contains.

```sh
restore-video input.mkv                 # → ./restored/input.mp4 or .mkv
restore-video --dry-run /path/to/series # list what would be processed
```

Set `VL_NODE` to the SSH host name of the GPU node. The node must be reachable
by SSH key and able to run Docker.

## Performance

The numbers below come from one machine — an RTX 4070 Ti (12 GB) with a Ryzen 7
7800X3D — on a 480-line source going to 1280×960. They are a reference point, not
a requirement: any CUDA-capable card runs the same chain, faster or slower.

| Stage | Throughput |
| --- | --- |
| DPIR | 86 fps |
| SPAN 2× | 183 fps |
| Full GPU chain | 58.7 fps |
| SVT-AV1 preset 4 (CPU) | 43 fps ← bottleneck |
| End to end | 40–43 fps |

A 45-minute episode takes about 33 minutes; a 90-minute feature about an hour.
Switching to NVENC moves the bottleneck back to the GPU chain and saves roughly
30% of the wall clock, at a real cost in bitrate efficiency — worth it for a
viewing copy, not for an archival master.

## Limits

- The QTGMC branch has not been exercised on genuinely interlaced video.
- No objective quality metric (VMAF) is wired in.
- No face restoration, no segmented or resumable processing: an interrupted job
  starts over.
- Not built for anime — the upscale model is trained on live-action degradations.
  It also does not denoise, so heavy grain should be handled before it, and the
  author of the model states it does not address VHS degradation.

## License

MIT. See `LICENSE`.
