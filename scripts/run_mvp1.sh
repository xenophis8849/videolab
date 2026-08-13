#!/usr/bin/env bash
# MVP1 驱动脚本：在 local/vsgpu 容器里跑 restore_mvp1.vpy，单进程流式编码。
#
#   ./run_mvp1.sh <输入> <输出> [VL_XXX=值 ...]
#
# 为什么是 `vspipe | ffmpeg` 而不是先出中间文件：640x480 的 RGBS 一帧 3.5 MB，
# 一部 90 分钟的片子中间文件就是 500 GB 量级。整条链必须流式。
#
# 音轨、字幕、章节从原文件直通(-map 1)，只有视频轨是新编的。
set -euo pipefail

IN=${1:?用法: run_mvp1.sh <输入> <输出> [VL_XXX=值 ...]}
OUT=${2:?用法: run_mvp1.sh <输入> <输出> [VL_XXX=值 ...]}
shift 2

# 命令行上的 `VL_XXX=值` 要**同时**在宿主机这一层生效，不能只转成 docker 的 -e。
# 本脚本自己也读 VL_* （VL_ENCODER 选编码器、VL_SVT_PRESET、VL_IMAGE、VL_WORK…），
# 那些判断跑在宿主机上。原来只把它们塞给容器，于是
#   run_mvp1.sh in out VL_ENCODER=hevc_nvenc
# 会**静默**退回默认编码器 —— 三个编码器跑出字节数完全相同的文件才发现。
# 只接受 VL_ 前缀且形如 NAME=VALUE 的参数，其余原样拒绝，不做 eval。
for kv in "$@"; do
    case "$kv" in
        VL_[A-Z0-9_]*=*) export "${kv?}" ;;
        *) echo "参数必须形如 VL_NAME=值，收到: $kv" >&2; exit 1 ;;
    esac
done

# 脚本先复制进 /work 再执行，不是直接跑 /scripts 里的那份。原因：vstools 的
# PackageStorage 用 `get_script_path()` 定位 `.vsjet/` 缓存目录 —— 是**.vpy 文件
# 自己所在的目录**，不是 cwd 也不是 $HOME。直接跑 /scripts 下那份会去
# /scripts/.vsjet 建目录，而 /scripts 是只读挂载，报
# `OSError: [Errno 30] Read-only file system`，而且这个错发生在 vspipe 里，
# 下游 ffmpeg 只会说 "Invalid data found when processing input"，很容易看岔。
IMAGE=${VL_IMAGE:-local/vsgpu:0.2.0}
WORK=${VL_WORK:-$HOME/videolab/work}      # .vsjet/ 引擎缓存落在这里，必须持久
CACHE=${VL_CACHE:-$HOME/videolab/cache}   # ONNX 模型缓存(~/.cache/vsscale)
MODELS=${VL_MODELS:-$HOME/videolab/models}
SCRIPTS=${VL_SCRIPTS:-$HOME/videolab/scripts}
# 默认断网跑：模型和 engine 都该是预热好的。首次准备模型时用 VL_NET=host。
NET=${VL_NET:-none}

# SVT-AV1 归档母版参数。preset 4 在 7800X3D 上跑 1280x960 实测约 33 fps
# (整条链的瓶颈在这里 —— GPU 侧是 58.7 fps)，约等于 1:1 实时。
# 分辨率再上去要往 6 调。crf 与 preset 一起决定质量，不要只动一个。
#
# 色彩标签必须走 -svtav1-params，不能只用 ffmpeg 的 -color_primaries/-color_trc：
# 实测那两个在 libsvtav1 下**不生效**，只有 -colorspace 会写进去，产出的文件是
# color_space=bt709 但 transfer/primaries 都是 unknown —— 一个只错一半的标签，
# 比全 unknown 更难发现。
SVT_PRESET=${VL_SVT_PRESET:-4}
SVT_CRF=${VL_SVT_CRF:-26}

mkdir -p "$WORK" "$CACHE" "$(dirname "$OUT")"

if [ "$NET" = none ] && [ ! -d "$CACHE/onnx" ]; then
    echo "错误: 模型缓存 $CACHE/onnx 不存在，断网跑必然失败。" >&2
    echo "先执行: $(dirname "$0")/prepare_models.sh" >&2
    exit 1
fi

IN_DIR=$(realpath "$(dirname "$IN")")
OUT_DIR=$(realpath "$(dirname "$OUT")")
IN_BASE=$(basename "$IN")
OUT_BASE=$(basename "$OUT")

# 逐个 -e，不要用 "${@/#/-e }" —— 那样会把 "-e VL_X=1" 拼成含空格的单个参数，
# docker 会把整串当成一个 flag 名而报 unknown shorthand flag。
docker_env=(-e "VL_INPUT=/in/$IN_BASE")
for kv in "$@"; do
    docker_env+=(-e "$kv")
done

# ---- 编码参数：从预设读，不写死 ----
# 预设文件与转码项目同 schema（见 presets-restore-v1.json 的注释）。
# 码率由 `max_bits_per_pixel_frame × 宽 × 高 × 帧率` 推出 —— 用每像素比特而不是
# 「相对源文件大小的倍数」，因为修复输出的像素数是源的 4 倍，按源文件大小卡码率
# 等于把刚重建出来的细节再压回去。
#
# **输出几何和帧率必须问 vspipe，不能从源文件推。** IVTC 会把 29.97 变成
# 23.976，超分会把宽高乘 2，只有跑一遍图构建才知道最终是多少。
# `vspipe -i` 只构建不出帧，代价很小（engine 命中缓存时 0.3 s）。
PRESET_ID=${VL_PRESET:-hevc-nvenc-sdr-high-v2}
PRESETS=${VL_PRESETS:-$HOME/videolab/presets/presets-restore-v1.json}
[ -f "$PRESETS" ] || { echo "错误: 预设文件不存在: $PRESETS" >&2; exit 1; }

# stderr 不能丢。原来这里是 `vspipe -i ... 2>/dev/null`，于是任何构图失败都只剩
# 「无法获取修复链的输出几何」这一句 —— 处理一部非 mod-8 宽度的片子时撞上，
# 唯一的线索被自己删掉了。stderr 收进临时文件：成功时不刷屏（原意保留），
# 失败时整段吐出来。
geomerr=$(mktemp)
geom=$(sudo docker run --rm --gpus all "--network=$NET" \
    -v "$IN_DIR":/in:ro -v "$MODELS":/models:ro -v "$SCRIPTS":/scripts:ro \
    -v "$WORK":/work -v "$CACHE":/root/.cache/vsscale \
    "${docker_env[@]}" "$IMAGE" \
    bash -c "cp /scripts/restore_mvp1.vpy /work/ && cd /work && vspipe -i restore_mvp1.vpy -" 2>"$geomerr") || {
    echo "错误: 无法获取修复链的输出几何。以下是 vspipe 的输出：" >&2
    tail -40 "$geomerr" >&2; rm -f "$geomerr"; exit 1; }
rm -f "$geomerr"
OUT_W=$(sed -n 's/^Width: *//p' <<<"$geom")
OUT_H=$(sed -n 's/^Height: *//p' <<<"$geom")
OUT_FPS=$(sed -n 's/^FPS: *\([0-9]*\)\/\([0-9]*\).*/\1 \2/p' <<<"$geom")
# 总帧数 —— 进度百分比的分母。vspipe -i 本来就给，之前只取了宽高帧率没取它。
OUT_FRAMES=$(sed -n 's/^Frames: *//p' <<<"$geom")
[ -n "$OUT_W" ] && [ -n "$OUT_H" ] && [ -n "$OUT_FPS" ] || {
    echo "错误: 解析输出几何失败" >&2; printf '%s\n' "$geom" >&2; exit 1; }

VENC=$(python3 - "$PRESETS" "$PRESET_ID" "$OUT_W" "$OUT_H" $OUT_FPS <<'PY'
import json, sys
path, pid, w, h, fn, fd = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
presets = {p["id"]: p for p in json.load(open(path))["presets"]}
if pid not in presets:
    sys.exit(f"未知预设 {pid}，可选: {', '.join(presets)}")
v = presets[pid]["video"]
enc = v["encoder"]
# 色彩标签三家写法不同，必须分开给。只写 -colorspace 会留下
# transfer/primaries=unknown —— 一个「只错一半」的标签，比全错更难发现。
if enc == "libsvtav1":
    args = (f"-c:v libsvtav1 -preset {v['svt_preset']} -crf {v['crf']} -pix_fmt yuv420p10le "
            "-svtav1-params color-primaries=1:transfer-characteristics=1:matrix-coefficients=1:color-range=0")
else:
    bitrate = int(v["max_bits_per_pixel_frame"] * w * h * fn / fd)
    args = (f"-c:v {enc} -preset {v['nvenc_preset']} -tune {v['tune']} -rc vbr "
            f"-b:v {bitrate} -maxrate {bitrate} -bufsize {bitrate*2} "
            f"-pix_fmt p010le -profile:v {v['profile']} "
            "-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv")
print(args)
PY
) || { echo "错误: 预设解析失败" >&2; exit 1; }

echo "预设 $PRESET_ID -> 输出 ${OUT_W}x${OUT_H} @ $(awk "BEGIN{printf \"%.3f\", $(echo $OUT_FPS|tr ' ' '/')}") fps"
# 机器可读：调用方靠它算百分比。放在编码开始前输出。
echo "TOTAL_FRAMES=${OUT_FRAMES:-0}"

# ---- 流保全与容器判定 ----
# 修复侧的映射本来就是保全的（`-map 1 -map -1:v` 带走音轨/字幕/附件，章节
# 默认也跟着走，已实测）。真正要改的是音频编码与容器：
#   - 音频从 `-c:a copy` 改为逐轨 AAC，码率按各自声道数定，不下混
#   - 容器按「保留的流 MP4 能否无损承载」自动选，可强制
#
# **策略必须在容器里算，不能在宿主机算。** GPU 节点的宿主机没有 ffmpeg（刻意的，
# 见 stream-policy.sh 的文件头），在这里调 ffprobe 会静默返回空，于是一律判
# MP4、音频退回默认 128k —— 已经这样错过一次，而且在控制端上
# 测不出来（控制端有 ffmpeg）。
policy=$(sudo docker run --rm \
    -v "$IN_DIR":/in:ro -v "$SCRIPTS":/scripts:ro "$IMAGE" \
    bash -c ". /scripts/stream-policy.sh
             printf 'AUDIO=%s\n' \"\$(audio_args_for '/in/$IN_BASE')\"
             printf 'CONTAINER=%s\n' \"\$(container_for '/in/$IN_BASE' '${VL_CONTAINER:-auto}')\"") || {
    echo "错误: 流策略计算失败" >&2; exit 1; }
AUDIO_ARGS=${policy#*AUDIO=}; AUDIO_ARGS=${AUDIO_ARGS%%$'\n'*}
CONTAINER=${policy##*CONTAINER=}
[ -n "$CONTAINER" ] || { echo "错误: 容器判定为空" >&2; exit 1; }
# 容器决定扩展名。输出名由调用方给，这里只在扩展名不符时纠正。
case "$OUT_BASE" in
    *.mkv|*.mp4) OUT_BASE="${OUT_BASE%.*}.$CONTAINER" ;;
    *)           OUT_BASE="$OUT_BASE.$CONTAINER" ;;
esac
# MP4 装不下附件；容器判为 mp4 时必然是「没有需要保留的附件」，显式丢掉以免
# ffmpeg 因为一个死重量的字体而整条命令失败。
DROP_ATTACH=''
[ "$CONTAINER" = mp4 ] && DROP_ATTACH='-map -1:t'
# 字幕：MP4 只能走 mov_text，MKV 原样 copy。
SUB_CODEC='-c:s copy'
[ "$CONTAINER" = mp4 ] && SUB_CODEC='-c:s mov_text'

sudo docker run --rm --gpus all "--network=$NET" \
    -v "$IN_DIR":/in:ro \
    -v "$OUT_DIR":/out \
    -v "$MODELS":/models:ro \
    -v "$SCRIPTS":/scripts:ro \
    -v "$WORK":/work \
    -v "$CACHE":/root/.cache/vsscale \
    "${docker_env[@]}" \
    "$IMAGE" \
    bash -o pipefail -c "
        cp /scripts/restore_mvp1.vpy /work/ &&
        vspipe -c y4m /work/restore_mvp1.vpy - |
        ffmpeg -hide_banner -y -nostats -progress pipe:1 -i - -i '/in/$IN_BASE' \
            -map 0:v:0 -map 1 -map -1:v $DROP_ATTACH \
            $VENC \
            $AUDIO_ARGS $SUB_CODEC \
            '/out/$OUT_BASE'
    " | sed -u -n 's/^frame=/PROGRESS_FRAME=/p'
# 退出码必须取 PIPESTATUS[0]。`... | sed ... || exit $?` 取的是 **sed** 的状态，
# sed 几乎永远成功，ffmpeg/vspipe 的失败会被整条吞掉。
enc_rc=${PIPESTATUS[0]}
[ "$enc_rc" -eq 0 ] || exit "$enc_rc"

# ---- 产出验证 ----
# 不是可选步骤：它是「删除原片」的前置条件，也是唯一能抓住「编码静默失败」的
# 环节。之前编完就当成功，一次失败会被当成完成。
# 同样必须在容器里跑 —— 宿主机没有 ffprobe，在外面跑会把每一次都判成失败。
if sudo docker run --rm \
        -v "$IN_DIR":/in:ro -v "$OUT_DIR":/out:ro -v "$SCRIPTS":/scripts:ro "$IMAGE" \
        bash -c ". /scripts/stream-policy.sh
                 verify_output '/out/$OUT_BASE' '/in/$IN_BASE'"; then
    echo "产出验证通过: $OUT_DIR/$OUT_BASE"
    # 机器可读的最终路径。**调用方不能自己拼扩展名** —— 容器判定会把 .mkv
    # 改写成 .mp4（或反过来），写死后缀的调用方会取不到文件。
    echo "OUTPUT=$OUT_DIR/$OUT_BASE"
else
    echo "产出验证未通过（上面是具体问题）" >&2
    exit 1
fi
