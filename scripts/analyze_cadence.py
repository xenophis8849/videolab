"""源分析第二步：29.97p 且无梳状伪影时，判断它是"真 30p"还是"被毁过的 24p"。

1995 年的 DVDRip 如果原片是胶片(23.976)，正确的做法是反转电视电影回 23.976p。
但很多老 rip 是用混合场(blend deinterlace)或直接丢场做的 —— 输出确实不梳了，
却留下两种不同的伤：

  * **重复帧**：telecine 后按帧丢弃 -> 每 5 帧里有 1 帧和前一帧几乎完全相同。
    这种可以用 VDecimate 干净地抽回 23.976p，无损。
  * **混合帧**：两场来自不同电影帧被平均 -> 每 5 帧里有 1~2 帧是"鬼影帧"。
    这种抽帧抽不掉，只能 deblend 重建，或者接受 29.97p。

区分办法：看逐帧差分序列有没有周期 5 的结构。重复帧的差分接近 0；
混合帧的差分不为 0 但显著小于相邻帧(因为它是两帧的平均，离两边都近)。

用法: python3 analyze_cadence.py <file> [帧数]
"""

import sys

import vapoursynth as vs
from vssource import BestSource

core = vs.core

path = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 200

clip = BestSource.source(path)
y = clip.resize.Point(format=vs.GRAY8, matrix_in_s="170m")

# 相邻帧绝对差的均值。用 8bit GRAY 就够，这里只要相对大小。
diff = core.std.PlaneStats(y, y[0] + y, prop="D")

vals = []
for i in range(1, min(N, clip.num_frames)):
    vals.append(diff.get_frame(i).props["DDiff"])

mean = sum(vals) / len(vals)
print(f"采样 {len(vals)} 组相邻帧差，均值 {mean:.5f}")

# 按周期 5 分桶，看哪一相位系统性偏低
phases = [[] for _ in range(5)]
for i, v in enumerate(vals):
    phases[i % 5].append(v)
print("周期-5 相位均值:", [f"{sum(p) / len(p):.5f}" for p in phases])

lo = min(sum(p) / len(p) for p in phases)
hi = max(sum(p) / len(p) for p in phases)
print(f"相位最低/最高 = {lo / hi:.2f}")

dups = sum(1 for v in vals if v < mean * 0.05)
near = sum(1 for v in vals if mean * 0.05 <= v < mean * 0.5)
print(f"近乎重复帧(<5%均值): {dups} ({dups / len(vals):.1%})")
print(f"偏低帧(5%~50%均值): {near} ({near / len(vals):.1%})")

if dups / len(vals) > 0.15:
    print("→ 判定: 有周期性重复帧，是被抽帧毁过的 telecine。用 VDecimate 抽回 23.976p。")
elif lo / hi < 0.7:
    print("→ 判定: 存在周期-5 的低差分相位但不是完全重复 —— 高度怀疑混合帧(blend)。"
          "抽帧救不了，需要 deblend，或者接受 29.97p 直接处理。")
else:
    print("→ 判定: 没有 24p 残留结构，就是原生 29.97p。场处理这一步整个跳过。")
