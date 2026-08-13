"""场结构判定 —— 取代 analyze_source.py 里那段基于 `_Combed` 的判据。

**为什么原来的判据是错的：** `vivtc.VFM` 输出帧上的 `_Combed` 表示"匹配完之后
这一帧**还**梳不梳"，不是"源梳不梳"。VFM 干得好的时候 `_Combed` 恰恰是 0 ——
于是一个标准的 3:2 telecine 源会被读成"没有梳状伪影，按逐行处理"，
正好把最该做的一步跳掉。已经在一份标准 telecine 素材上踩到这个假阴性。

正确的判据是**匹配序列本身**：

  * 3:2 pulldown  -> VFMMatch 呈严格周期 5 的重复模式，且分布恰好 c:p = 60:40
  * telecine 但有断点 -> 分布仍是 60:40，但周期一致度掉到 0.65~0.85（片子里
                     有电影段和录像段混剪，或剪辑点破坏了 cadence）
  * 真隔行         -> 匹配散乱，分布也不是 60:40
  * 原生逐行       -> 匹配几乎全是 c（当前帧）

**VDecimate 的保留率不是证据。** 它固定每 5 帧丢 1，所以任何源都会给出 0.800 ——
原生逐行的素材也是 0.800。只打印出来供参考，不参与判定。这是本文件的
第二个假信号（第一个是 `_Combed`）。

用法: python3 analyze_fields.py <file> [帧数]
"""

import sys
from collections import Counter

import vapoursynth as vs
from vssource import BestSource

core = vs.core

MATCH_NAMES = "pcnbu"

path = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 250

clip = BestSource.source(path)
props0 = clip.get_frame(0).props
fb = props0.get("_FieldBased", 0)
print(f"clip: {clip.width}x{clip.height} {clip.num_frames}帧 "
      f"{clip.fps_num}/{clip.fps_den}  _FieldBased={fb} "
      f"({ {0: '逐行', 1: '底场优先', 2: '顶场优先'}.get(fb, '?') })")

y8 = clip.resize.Point(format=vs.YUV420P8, matrix_in_s="170m")
N = min(N, clip.num_frames)

# order 跟随源标注：_FieldBased 2 = TFF -> order=1
order = 1 if fb != 1 else 0
matched = core.vivtc.VFM(y8, order=order, mode=0)

seq = []
combed_after = 0
for i in range(N):
    p = matched.get_frame(i).props
    seq.append(MATCH_NAMES[p.get("VFMMatch", 1)])
    combed_after += bool(p.get("_Combed", 0))

s = "".join(seq)
print(f"VFM 匹配序列(前 60): {s[:60]}")
print(f"匹配分布: {dict(Counter(s))}")
print(f"匹配后仍梳: {combed_after}/{N} ({combed_after / N:.1%})  "
      f"← 这个数低只说明 VFM 干得好，不能反推源是逐行的")

# 周期性检测：把序列按各个周期折叠，看哪个周期下每个相位的取值最一致。
best = None
for period in range(2, 9):
    agree = 0
    for phase in range(period):
        col = s[phase::period]
        if col:
            agree += Counter(col).most_common(1)[0][1]
    score = agree / len(s)
    if best is None or score > best[1]:
        best = (period, score)
    print(f"  周期 {period}: 相位一致度 {score:.1%}")
print(f"最佳周期 = {best[0]}，一致度 {best[1]:.1%}")

dec = core.vivtc.VDecimate(matched)
print(f"VDecimate: {matched.num_frames} -> {dec.num_frames} 帧 "
      f"(保留 {dec.num_frames / matched.num_frames:.3f}) —— 仅供参考，不是证据，见文件头")

c_ratio = s.count("c") / len(s)
p_ratio = s.count("p") / len(s)
# 3:2 pulldown 的匹配分布是固定的 c:p = 3:2。允许 5 个百分点的偏差。
telecine_dist = abs(c_ratio - 0.6) < 0.05 and abs(p_ratio - 0.4) < 0.05

print()
if c_ratio > 0.9:
    print("→ 判定: **原生逐行**。场处理整个跳过。")
elif best[0] == 5 and telecine_dist and best[1] > 0.85:
    print("→ 判定: **干净的 3:2 telecine**。走 VIVTC（VFM + VDecimate）还原 23.976p。")
elif best[0] == 5 and telecine_dist:
    print(f"→ 判定: **telecine 但 cadence 有断点**（周期一致度只有 {best[1]:.1%}）。"
          "常见于电影段和录像段混剪的片子。VIVTC 仍是对的，但断点处会掉帧或留梳；"
          "断点多到无法接受时改走 QTGMC 保 29.97p。**这种片子必须人眼抽查断点附近。**")
elif fb != 0:
    print("→ 判定: **真隔行**（匹配无 3:2 结构）。走 QTGMC。")
else:
    print("→ 判定: 不干净 —— 可能是混合场序或被 blend 过。"
          "需要人眼看片段再定，不要自动选分支。")
