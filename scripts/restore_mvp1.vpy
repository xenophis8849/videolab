"""MVP1 修复链 —— 由 vspipe 执行，输出交给 ffmpeg 编码。

    vspipe -c y4m restore_mvp1.vpy - | ffmpeg -i - ...

全部参数走环境变量，因为 vspipe 的 `--arg` 只能传字符串且不方便从 shell 拼。
run_mvp1.sh 是配套的驱动脚本，正常情况下不要直接调这个文件。

设计上的两条硬约束：

1. **整条链在 RGBS(32-bit float) 里跑完再落回 YUV。** DPIR 和 SPAN 都是 RGB 模型，
   如果让每个 scaler 自己做 YUV<->RGB 转换，一条链就要来回两次，每次都过一遍
   chroma 上采样/下采样和取整。这里手动在入口转一次、出口转一次。

2. **色彩矩阵必须显式写死。** 素材的容器标签是 unknown，BestSource 按 480 线
   猜成 BT.601(Matrix=6)，这个猜测是对的，但"对"和"被下游看到"是两回事 ——
   不显式指定，出口的 709 转换就会拿 unknown 去做，结果是整体偏色。
"""

import os
import sys

import vapoursynth as vs
from vskernels import Catrom, Lanczos
from vsscale import DPIR, Backend, GenericOnnxScaler
from vssource import BestSource
from vstools import Matrix, Padder, Primaries, Transfer

core = vs.core

# vskernels 的 resample 是**实例方法**，必须先实例化。
# 直接写 Catrom.resample(clip, ...) 会把 clip 当成 self，报出
# "There is no attribute or namespace named kwargs" 这种和真实原因毫无关系的错。
catrom = Catrom()
lanczos = Lanczos()


def _flag(name: str, default: bool = False) -> bool:
    return os.environ.get(name, "1" if default else "0").lower() in ("1", "true", "yes", "on")


INPUT = os.environ["VL_INPUT"]
FIELD_MODE = os.environ.get("VL_FIELD", "auto")      # auto | progressive | ivtc | qtgmc
DEBLOCK_STRENGTH = float(os.environ.get("VL_DEBLOCK", "10"))
DENOISE = os.environ.get("VL_DENOISE", "off")        # off | bm3d | dpir
DENOISE_SIGMA = float(os.environ.get("VL_DENOISE_SIGMA", "1.0"))
DENOISE_TR = int(os.environ.get("VL_DENOISE_TR", "1"))  # bm3d 的时间半径
UPSCALE_MODEL = os.environ.get("VL_UPSCALE_MODEL", "")
# 瓦片推理。**有些 ONNX 是按固定输入尺寸导出的**，整帧喂进去 TRT 直接报
#   IElementWiseLayer must have inputs with same dimensions
#   Input dimensions were [1,12,480,640] and [1,12,256,256]
# （Phhofm 的 2xPublic_realplksr 系列就是 256 固定尺寸，实测）。这类必须设
# VL_TILE 等于导出时的尺寸。overlap 是瓦片间的重叠，防止接缝 —— 设 0 会在
# 瓦片边界留下可见的格子线。SPAN 是动态尺寸模型，不需要设（VL_TILE=0）。
TILE = int(os.environ.get("VL_TILE", "0"))
OVERLAP = int(os.environ.get("VL_OVERLAP", "16"))
# 枚举名按 vstools 的写法：BT.601 NTSC 的矩阵叫 ST170_M，不是 SMPTE170M；
# 而且 Matrix / Transfer / Primaries 三个枚举的成员名不通用
# （Transfer 里是 BT601，Primaries 里又回到 ST170_M），不能互相套。
MATRIX_IN = Matrix[os.environ.get("VL_MATRIX_IN", "ST170_M")]   # 480/576 线源的默认解读
MATRIX_OUT = Matrix[os.environ.get("VL_MATRIX_OUT", "BT709")]
# 基色是否真的做色域变换。默认做：源标着 ST170_M(SMPTE-C)，只改标签不变换
# 等于让 709 显示器按错误的基色去解，整体偏饱和。关掉它会退成"只转矩阵、
# 基色照抄"，这是很多工具的默认行为，观感差别很小但方向明确 —— 留给 A/B。
CONVERT_PRIMARIES = _flag("VL_CONVERT_PRIMARIES", True)
OUT_DEPTH = int(os.environ.get("VL_DEPTH", "10"))
FRAMES = int(os.environ.get("VL_FRAMES", "0"))       # >0 时只处理前 N 帧，用于 A/B

# 后端。默认 TRT；ORT_CUDA 是回退路径 —— 实测慢 5.3 倍(11.0 fps vs 58.7 fps 全链)，
# 但它不需要构建 engine，所以在"换了 GPU/换了 TRT 版本、engine 缓存全废、
# 只想先看一眼结果"的时候有用，也是 TRT 出问题时唯一还能跑的路。
BACKEND_NAME = os.environ.get("VL_BACKEND", "TRT")
# fp16 默认开，但不是所有模型都能自动转成 fp16。vsjetpack 会先把 fp32 的 onnx
# 转一份 fp16 再交给 TRT，这个转换在某些模型上会留下混合精度节点，TRT 直接拒绝：
#   ElementWiseOperation SUM must have same input types. But they are of types Float and Half
# （2xPublic_realplksr_dysample_layernorm 的 /to_img/Add_1 就是，实测）。
# 遇到这种把 VL_FP16=0 退回 fp32，代价是慢一截、显存翻倍，但结果是对的。
# 先别急着退 fp32：TRT 后端有 fp16_blacklist_ops，可以只把出问题的那类算子留在
# fp32、其余照常 fp16。混合精度冲突通常就卡在一两个算子上（本例是 Add）。
FP16 = _flag("VL_FP16", True)
FP16_BLACKLIST = [s for s in os.environ.get("VL_FP16_BLACKLIST", "").split(",") if s]
if BACKEND_NAME == "TRT":
    backend = Backend.TRT(
        fp16=FP16,
        fp16_blacklist_ops=FP16_BLACKLIST or None,
        # bf16 是 fp16 失败时的第一顺位替代，不是 fp32。fp16 的自动转换之所以会
        # 留下混合精度节点，多半是某些常量超出 fp16 的值域被自动降级、而 Cast
        # 没插全；bf16 的指数范围和 fp32 一样，从根上不触发这条路径。
        # 精度上 bf16 尾数比 fp16 少 3 位，但超分是回归任务不是累加，影响很小。
        bf16=_flag("VL_BF16") or None,
        # 瓦片模型的吞吐对 num_streams 敏感得多：一帧要跑 6 次 256x256 的小推理，
        # 单次计算量小、调度延迟占比高，多流并发才能把 GPU 填满。整帧模型没这个问题。
        num_streams=int(os.environ.get("VL_STREAMS", "2")),
        builder_optimization_level=int(os.environ.get("VL_BUILD_OPT", "3")),
        # DPIR drunet 在 640x480 下 engine 约 66 MB，12 GB 级别的卡给 4 GB 构建
        # 空间足够激进；显存不够时 TRT 会自己退回更保守的 tactic，不会失败。
        workspace=4 << 30,
    )
else:
    backend = getattr(Backend, BACKEND_NAME)(fp16=FP16)

# ---- ① 源加载 ----
clip = BestSource.source(INPUT)

# ---- 分辨率上限：宽或高任一 > 1280 一律拒绝 ----
# 用「任一维度」而不是「只看宽」：竖屏 1080p 是 1080x1920，只看宽（1080）会
# 放过去，然后被超分成 2160x3840。这跟当初选 1920 阈值时是同一个理由。
#
# 阈值 1280 覆盖 DVD/VCD/720p（1280x720 正好卡在边界内），排除 1080p 及以上。
# 设计决定：修复档只对 ≤1280 的源开放。
#
# 为什么硬拦而不是警告：这条链是为低分辨率源选的型（2x 超分 + 针对低分辨率
# 压缩伤害训练的 SPAN）。1080p 进来会被超分成 3840x2160，按像素数是 480 线的
# 9 倍 —— 90 分钟的片子约 10 小时，而 MVP2 对 1080p 的设计本来就是**不超分**。
MAX_DIM = 1280
if max(clip.width, clip.height) > MAX_DIM:
    raise ValueError(
        f"源分辨率 {clip.width}x{clip.height} 超出 MVP1 上限"
        f"（宽或高任一不得大于 {MAX_DIM}）。1080p 以上属于 MVP2，尚未实现。"
    )

# ---- ② 场处理 ----
# **不能只看 `_FieldBased` 来选分支。** 那样凡是带隔行标记的源一律送 QTGMC，
# 而目标片源里绝大多数 DVD 是胶片经 3:2 telecine 的 —— 底层只有 23.976 个真实
# 时刻，QTGMC bob 成 59.94p 多出来的帧全是插出来的，既不保留细节又让编码时间和
# 码率翻倍，正确做法是 IVTC 回 23.976p。判据必须是 VFM 的匹配序列，
# 详见 analyze_fields.py 的文件头（那里记了两个已经踩过的假信号）。
field = FIELD_MODE
if field == "auto":
    fb = clip.get_frame(0).props.get("_FieldBased", 0)
    if fb == 0:
        field = "progressive"
    else:
        y8 = clip.resize.Point(format=vs.YUV420P8, matrix_in=MATRIX_IN)
        probe = core.vivtc.VFM(y8, order=(1 if fb == 2 else 0), mode=0)
        n = min(250, clip.num_frames)
        seq = "".join("pcnbu"[probe.get_frame(i).props.get("VFMMatch", 1)] for i in range(n))
        # 匹配之后仍然梳 = VFM 找不到能拼出干净逐行帧的场配对 = 真隔行录像。
        # 胶片源这个数接近 0（实测两份胶片源分别是 0.0% 和 0.4%）。
        still_combed = sum(bool(probe.get_frame(i).props.get("_Combed", 0)) for i in range(n)) / n
        c_ratio = seq.count("c") / n
        # 3:2 pulldown 的匹配分布固定 c:p = 60:40，且呈周期 5 的重复。
        agree5 = sum(
            max(seq[ph::5].count(ch) for ch in set(seq[ph::5])) for ph in range(5)
        ) / n
        # 主判据是 still_combed：它区分的是**胶片源 vs 真隔行录像**，而这正是
        # ivtc/qtgmc 的分界。周期一致度只区分 cadence 干不干净 —— 两者都该走 IVTC，
        # 所以它**不参与选分支**，只用来提示需要人眼抽查。
        # （这里踩过：一开始把 agree5>0.65 也写进条件，结果 cadence 有断点的胶片源
        # 被送去 QTGMC 双倍帧率，等于把 24 个真采样插成 60 帧。断点会让全局固定
        # 相位的一致度虚低，用它当门槛必然误判。）
        field = "ivtc" if still_combed < 0.05 and abs(c_ratio - 0.6) < 0.08 else "qtgmc"
        note = ""
        if field == "ivtc" and agree5 < 0.85:
            note = "  ⚠ cadence 有断点，断点处可能掉帧或留梳，需人眼抽查"
        print(
            f"[auto] c={c_ratio:.0%} 周期5一致度={agree5:.0%} 匹配后仍梳={still_combed:.1%}"
            f" -> {field}{note}",
            file=sys.stderr,
        )

if field == "ivtc":
    from vsdeinterlace import vdecimate, vfm
    clip = vdecimate(vfm(clip))
elif field == "qtgmc":
    from vsdeinterlace import QTempGaussMC
    # 注意调用形式：clip 传给 .deinterlace()，不是构造函数 —— 构造函数只吃
    # 关键字参数（各阶段的调参），`QTempGaussMC(clip)` 会报
    # "takes 1 positional argument but 2 were given"。
    #
    # 默认输出**双倍帧率**（29.97i -> 59.94p，每场一帧）。这是 QTGMC 的本来用法，
    # 但**只在源确实是真隔行录像时才成立**：那种源的两场采样于相隔 1/60 s 的不同
    # 时刻，59.94 个时刻是源里实有的，抽成 29.97p 等于永久扔掉一半时间分辨率。
    # 胶片源不该走到这里（上面的 auto 会送去 ivtc）；手工指定 VL_FIELD=qtgmc 处理
    # 胶片源时，双倍出来的帧是插值产物，不是保留下来的细节。
    # 代价是帧数翻倍 -> 编码时间翻倍、码率大幅上升。VL_QTGMC_RATE=single 抽回原帧率。
    clip = QTempGaussMC().deinterlace(clip)
    if os.environ.get("VL_QTGMC_RATE", "double") == "single":
        # SelectEvery 自己会把 fps 除以 cycle，**不要**再补一个 AssumeFPS ——
        # 那样会得到 14.985 fps（踩过）。
        clip = clip.std.SelectEvery(cycle=2, offsets=0)
elif field != "progressive":
    raise ValueError(f"未知的 VL_FIELD: {field}")

if FRAMES:
    clip = clip[:FRAMES]

# ---- ③ 复合视频伪影（默认关，A/B 后再定）----
# vinverse 是 YUV 域的滤镜，所以放在转 RGB 之前做，避免多一次来回转换。
if _flag("VL_COMPOSITE"):
    from vsdeinterlace import vinverse
    clip = vinverse(clip)

# ---- ③b 非方形像素校正 ----
# **必须在超分之前做，而且不能省。** DVD / VCD 源普遍是非方形像素：
# 352x480 配 SAR 20:11 才显示成 4:3。整条链如果直接按存储像素走，输出就是
# 704x960 的方形像素，显示比例 0.73:1 —— 横向压扁 1.82 倍。这个 bug 交付过一次，
# 而且没被对比图抓到，因为对比脚本两侧都加了 setsar=1，两边一起错就看不出来。
#
# 放在超分之前而不是之后：SR 模型是在方形像素的自然图像上训练的，喂横向压扁的
# 画面等于让它见到"窄脸、椭圆",判断会变差。先校正几何再让模型工作。
# 代价是模型输入像素变多(352->640 是 1.8 倍)，比正确性次要。
sar_n = clip.get_frame(0).props.get("_SARNum", 1)
sar_d = clip.get_frame(0).props.get("_SARDen", 1)
if sar_n != sar_d:
    square_w = round(clip.width * sar_n / sar_d / 2) * 2   # 保持偶数，YUV420 要求
    print(f"[sar] {clip.width}x{clip.height} SAR {sar_n}:{sar_d}"
          f" -> 方形像素 {square_w}x{clip.height}", file=sys.stderr)
    clip = lanczos.scale(clip, square_w, clip.height)

# ---- 进入 RGB 浮点工作空间 ----
rgb = catrom.resample(clip, vs.RGBS, matrix_in=MATRIX_IN)

# ---- ④a 去压缩伪影 ----
# DPIR 的输入宽高必须能被 8 整除 —— vsscale 在 calc_tilesize() 里硬性检查，
# 不满足就抛 "Tile size (W, H) must be divisible by 8"，而且是在构图阶段抛，
# 连 vspipe -i 都过不去。
#
# **不能指望源天然满足。** 上面 ③b 的方形像素校正只保证结果是偶数：
#   720x480 SAR 32:27（16:9 DVD） -> 854（854/8 = 106.75）
#   非标 SAR 的源同样会算出非 8 倍数的宽度。
# 常见的几个比例恰好都整除（352->640、640、720x480 4:3 -> 640），所以容易漏。
#
# 补边而不是裁边：裁掉最多 7 列是真实画面的损失，还会改掉显示比例。
# 镜像补而不是黑边：黑边在画面边缘造出一条人为的硬边界，DPIR 会把它当成块效应
# 去"修"，污染紧邻的真实像素。补完立刻裁回原尺寸。
def _mod8(clip: vs.VideoNode, fn):
    padder = Padder.from_mod(clip, mod=8, min=0)
    if not (padder.left or padder.right or padder.top or padder.bottom):
        return fn(clip)                      # 已经整除：一个节点都不多加
    return padder.crop(fn(padder.mirror(clip)))


if DEBLOCK_STRENGTH > 0:
    rgb = _mod8(rgb, DPIR.DrunetDeblock(strength=DEBLOCK_STRENGTH, backend=backend).scale)

# ---- ④b 去噪（默认关）----
# **实测结论：在测试素材上不值得开。** 低 sigma(1.0)与不去噪的 PSNR 44.3 dB，
# 肉眼不可分 —— 因为 DPIR 去块效应已经把噪声带走了；sigma 6 才可见（38.0 dB，
# 码率 −12%），但抹掉细纹理，而且**任何一档都让墙钟从 24.25 s 涨到 32.2 s(+33%)**。
#
# 那 33% 不是"用掉了 GPU 余量"，是余量根本没那么大：编码器单独能跑 43 fps，
# 而不是整条链的合并观测值 33 fps。免费预算只有 1/43−1/59 = 6.3 ms/帧，
# 只塞得下 158 fps 以上的环节；BM3D 是 36 fps，塞不进去。
# **教训：合并观测吞吐不等于单段独立能力，拿它算余量必然高估。**
#
#   bm3d -> 时空块匹配。tr>=1 时跨帧做，对胶片颗粒和随机噪声最有效，
#           而且因为是时序的，静止区域能把细节"攒"回来。低 sigma 保纹理。
#   dpir -> DPIR 的去噪权重(drunet_color)，单帧 CNN。对结构性噪声更狠，
#           但没有时序约束，颗粒会在时间轴上闪。
if DENOISE == "bm3d":
    from vsdenoise import bm3d
    # RGB 输入会在 OPP 色彩空间里处理（BM3D 本来的做法），不需要手动转。
    rgb = bm3d(rgb, sigma=DENOISE_SIGMA, tr=DENOISE_TR,
               profile=bm3d.Profile.NORMAL, backend=bm3d.Backend.CUDA_RTC)
elif DENOISE == "dpir":
    # 同一个 mod-8 约束，去噪权重也走 DPIR。
    rgb = _mod8(rgb, DPIR.DrunetDenoise(strength=DENOISE_SIGMA, backend=backend).scale)
elif DENOISE != "off":
    raise ValueError(f"未知的 VL_DENOISE: {DENOISE}")

# ---- ⑤ 2x 超分 ----
if UPSCALE_MODEL:
    scaler_kwargs = {"backend": backend}
    if TILE:
        scaler_kwargs |= {"tilesize": TILE, "overlap": OVERLAP}
    rgb = GenericOnnxScaler(UPSCALE_MODEL, **scaler_kwargs).scale(
        rgb, rgb.width * 2, rgb.height * 2
    )

# ---- ⑥ 色彩 + 位深 ----
out_fmt = getattr(vs, f"YUV420P{OUT_DEPTH}")
resample_kwargs = {"matrix": MATRIX_OUT, "transfer": Transfer.BT709}
if CONVERT_PRIMARIES:
    resample_kwargs["primaries"] = Primaries.BT709
out = catrom.resample(rgb, out_fmt, **resample_kwargs)

out.set_output()
