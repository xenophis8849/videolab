"""门槛验证 v2：vsjetpack 2.2.0 + TensorRT 11 能否真的建出 engine 并跑推理。

对照 gate_test.py（源码编译 + vs-mlrt 15.16 + TRT 10.16.1，实测 78.3 fps @ 640x480）。
刻意用合成片而不是真实素材 —— 这一步验的是运行基座，不是画质。
"""
import time

import vapoursynth as vs
from vsscale import DPIR, Backend

core = vs.core

W, H, N = 640, 480, 24

# 造一个带高频细节的片子，避免全平色被 TRT 优化掉、量不出真实吞吐。
base = core.std.BlankClip(width=W, height=H, format=vs.RGBS, length=N, color=[0.5, 0.4, 0.3])
noise = core.std.BlankClip(width=W, height=H, format=vs.GRAYS, length=N, color=[0.0])
noise = core.std.AddBorders(noise.std.Crop(right=W // 2), right=W // 2, color=[1.0])
clip = core.std.MaskedMerge(base, base.std.Invert(), noise)

print(f"输入: {clip.width}x{clip.height} {clip.format.name} {clip.num_frames}帧", flush=True)

t0 = time.time()
res = DPIR.DrunetDeblock(strength=10, backend=Backend.TRT(fp16=True, num_streams=1)).scale(clip)
print(f"图构建完成 {time.time() - t0:.1f}s（含模型下载 / TRT engine 构建或加载）", flush=True)

t1 = time.time()
for i, f in enumerate(res.frames()):
    if i == 0:
        print(f"首帧 {time.time() - t1:.1f}s", flush=True)
done = time.time()
print(f"{N} 帧耗时 {done - t1:.2f}s -> {N / (done - t1):.1f} fps @ {W}x{H}", flush=True)
print("门槛通过: TensorRT engine 构建 + 推理均成功", flush=True)
