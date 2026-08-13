"""源分析：判断素材是逐行 / 真隔行 / telecine，以及色彩标签是否可信。

输出的是决策依据，不是画面 —— MVP1 pipeline 的第 ② 步（场处理）走哪条分支
完全由这一步定，选错了后面的去噪和超分都救不回来。

用法: python3 analyze_source.py <file>
"""

import sys

import vapoursynth as vs
from vssource import BestSource

core = vs.core

path = sys.argv[1]
# BestSource 而不是 lsmas/ffms2：帧精确定位，不需要先建索引文件，
# 对老片这种时间戳不干净的源最不容易错帧。
clip = BestSource.source(path)

print(f"clip: {clip.width}x{clip.height} {clip.format.name} "
      f"{clip.num_frames}帧 {clip.fps_num}/{clip.fps_den}")

props = clip.get_frame(0).props
interesting = ("_FieldBased", "_Matrix", "_Transfer", "_Primaries", "_ColorRange",
               "_ChromaLocation", "_DurationNum", "_DurationDen")
print("首帧 props:", {k: props.get(k, "<缺失>") for k in interesting})

# VFM 只用来量指标，不真的做匹配输出 —— 这里关心的是 combed 帧占比。
y = clip.resize.Point(format=vs.YUV420P8) if clip.format.bits_per_sample != 8 else clip
matched = core.vivtc.VFM(y, order=1, mode=0)

N = min(clip.num_frames, 300)
combed = 0
cycles: dict[int, int] = {}
for i in range(N):
    p = matched.get_frame(i).props
    if p.get("_Combed", 0):
        combed += 1
    m = p.get("VFMMatch")
    if m is not None:
        cycles[m] = cycles.get(m, 0) + 1

print(f"VFM 采样 {N} 帧: combed {combed} ({combed / N:.1%})")
print(f"  match 分布 (0=p 1=c 2=n 3=b 4=u): {dict(sorted(cycles.items()))}")

if combed / N > 0.10:
    print("→ 判定: 有明显梳状伪影。若 match 集中在 p/c 交替 -> telecine，走 VIVTC；"
          "若散布 -> 真隔行，走 QTGMC")
else:
    print("→ 判定: 基本无梳状伪影，可按逐行处理（仍需确认不是场混合/blend）")

if props.get("_Matrix", 2) == 2:
    print("→ 色彩矩阵未标注。480i/480p 源按 BT.601 (Matrix=6) 解读，"
          "输出前显式转 BT.709 或打正确 tag —— 不处理会整体偏色。")
