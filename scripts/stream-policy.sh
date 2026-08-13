#!/usr/bin/env bash
# 流保全策略 —— 被 run_mvp1.sh 引用（source），也可单独跑来检查一个文件。
#
#   ./stream-policy.sh <文件>          打印该文件的流构成与容器判定
#   source stream-policy.sh            取得下面的函数
#
# 三件事：
#   1. container_for  —— 按「保留哪些流」决定容器（自动 / 强制）
#   2. audio_args_for —— 每条音轨按自己的声道数定 AAC 码率，不下混
#   3. verify_output  —— 产出验证，是「删除原片」的前置条件
#
# 依据（ffmpeg 8.0.1 实测，不是查文档得来的）：
#   subrip → MP4 需转 mov_text，**无损**（<i> 标签都能往返）
#   ass    → MP4 需转 mov_text，**样式名/Alignment/\pos 定位全丢**
#   ttf 附件 → MP4 **整条命令失败**：Could not find tag for codec ttf
#            且与字幕无关 —— 取消全部字幕后单独一个附件仍然写不出 MP4
#   PGS/VobSub 图形字幕 → MP4 无对应目标格式
#
# **这个文件里的每个函数都依赖 ffprobe/ffmpeg，必须在有它们的地方执行。**
# GPU 节点的宿主机**没有装 ffmpeg**（那是刻意设计：不要在宿主机
# apt install ffmpeg，dpkg 触发器可能执行
# systemctl daemon-reload，会让运行中的容器丢掉 nvidia 设备 cgroup 规则）。
#
# 踩过：把这些函数放在 run_mvp1.sh 里（宿主机执行）时，ffprobe 不
# 存在，**函数不报错而是静默返回空** —— container_for 查不到字幕和附件就一律
# 判 MP4，audio_args_for 返回空串让 ffmpeg 退回默认 128k。在控制端上测全对，
# 因为控制端有 ffmpeg。典型的「工具缺失被当成阴性结果」。
#
# 因此调用方必须把它放进容器里跑。下面这个自检会在缺工具时**直接退出**，
# 不允许静默降级。
set -uo pipefail

for _tool in ffprobe ffmpeg; do
    command -v "$_tool" >/dev/null || {
        echo "stream-policy.sh: 缺少 $_tool。这些函数必须在带 ffmpeg 的环境里执行" >&2
        exit 127
    }
done
unset _tool

# MP4 能无损承载的字幕编码。mov_text 之外，**只有 subrip 系可以转换过去且无损**。
# ass/ssa 技术上转得过去但会毁内容，所以不列入「MP4 可用」。
MP4_SAFE_SUBS='subrip|srt|text|mov_text'

# 每条音轨按声道数定码率。224k 是转码项目为**立体声**定的基准，
# 摊到 5.1 的 6 个声道明显不足（通常要 384–448k）。上限不超过源码率：
# 源本来就低时不必虚抬，那只会让文件变大而听感不变。
aac_bitrate_for_channels() {
    local ch=$1 src_kbps=${2:-0} want
    case "$ch" in
        1|2) want=224 ;;
        3|4|5|6) want=448 ;;
        *) want=640 ;;
    esac
    if [ "$src_kbps" -gt 0 ] && [ "$src_kbps" -lt "$want" ]; then want=$src_kbps; fi
    printf '%dk' "$want"
}

# 判定容器。mode = auto|mp4|mkv；keep_subs 是保留的字幕流索引（空=全部）。
# 回声 "mp4" 或 "mkv"，并把不可用的理由写到 stderr。
container_for() {
    local src=$1 mode=${2:-auto} keep_subs=${3:-} reasons=()
    local subs attach
    subs=$(ffprobe -v error -select_streams s -show_entries stream=codec_name \
        -of csv=p=0 "$src" 2>/dev/null)
    attach=$(ffprobe -v error -select_streams t -show_entries stream=codec_name \
        -of csv=p=0 "$src" 2>/dev/null)

    # 附件单独就能挡住 MP4，与字幕无关（已实测）。但附件是否保留取决于
    # 是否还留着 ASS 轨 —— 见 attachments_needed。
    if [ -n "$attach" ] && attachments_needed "$src" "$keep_subs"; then
        reasons+=("字体附件（$(printf '%s' "$attach" | tr '\n' ' ')）MP4 无法承载")
    fi
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        if ! printf '%s' "$c" | grep -qiE "^($MP4_SAFE_SUBS)$"; then
            reasons+=("字幕流 $c 进 MP4 会损坏或不被支持")
        fi
    done <<<"$subs"

    case "$mode" in
        mkv) printf 'mkv'; return ;;
        mp4)
            if [ ${#reasons[@]} -gt 0 ]; then
                printf '强制 MP4，但以下内容会丢失或损坏：\n' >&2
                printf '  - %s\n' "${reasons[@]}" >&2
            fi
            printf 'mp4'; return ;;
        auto)
            if [ ${#reasons[@]} -gt 0 ]; then
                printf '容器自动选择 MKV，因为：\n' >&2
                printf '  - %s\n' "${reasons[@]}" >&2
                printf 'mkv'
            else
                printf 'mp4'
            fi
            return ;;
    esac
}

# 字体附件是否需要保留：只要还留着任意 ass/ssa 字幕轨就需要。
# 没有 ASS 的字体是死重量，而且正是它挡住 MP4。
attachments_needed() {
    local src=$1 keep=${2:-} i=0 codec
    while IFS= read -r codec; do
        [ -n "$codec" ] || continue
        if [ -z "$keep" ] || printf '%s' " $keep " | grep -q " $i "; then
            printf '%s' "$codec" | grep -qiE '^(ass|ssa)$' && return 0
        fi
        i=$((i+1))
    done < <(ffprobe -v error -select_streams s -show_entries stream=codec_name \
             -of csv=p=0 "$src" 2>/dev/null)
    return 1
}

# 逐条音轨生成 AAC 参数。不下混：不设 -ac，AAC 编码器沿用源声道布局。
audio_args_for() {
    local src=$1 idx=0 line ch kbps
    while IFS=, read -r ch kbps; do
        [ -n "$ch" ] || continue
        [ "$kbps" = "N/A" ] || [ -z "$kbps" ] && kbps=0 || kbps=$((kbps/1000))
        printf -- '-c:a:%d aac -b:a:%d %s ' "$idx" "$idx" \
            "$(aac_bitrate_for_channels "$ch" "$kbps")"
        idx=$((idx+1))
    done < <(ffprobe -v error -select_streams a \
             -show_entries stream=channels,bit_rate -of csv=p=0 "$src" 2>/dev/null)
}

# 产出验证 —— **删除原片的前置条件**。没有它，一次静默的编码失败就等于毁素材。
verify_output() {
    local out=$1 src=$2 tol=${3:-0.25} issues=()
    [ -s "$out" ] || { echo "产出不存在或为空"; return 1; }

    local d_out d_src
    d_out=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" 2>/dev/null)
    d_src=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null)
    if [ -z "$d_out" ]; then issues+=("产出无法解析时长（可能损坏）"); fi

    # 时长容差沿用转码项目的 0.25 s。注意：IVTC 会把 29.97 变 23.976，
    # 帧数变但**时长不变**，所以时长仍是有效判据。
    if [ -n "$d_out" ] && [ -n "$d_src" ]; then
        awk -v a="$d_out" -v b="$d_src" -v t="$tol" \
            'BEGIN{d=a-b; if(d<0)d=-d; exit !(d>t)}' \
            && issues+=("时长偏差 $(awk -v a="$d_out" -v b="$d_src" 'BEGIN{printf "%.2f", a-b}') s 超过容差 ${tol} s")
    fi

    # 流数量：产出的音轨/字幕数不得少于源（视频轨允许不同，修复会换掉）。
    # `local c_out c_src` 不能和赋值写在一起再靠 `&&` 串联 —— local 的返回值
    # 会让后面的判断串味，而且 grep -c 在无匹配时退出 1，赋值语句会把它带出来。
    local n c_out c_src
    for n in a s; do
        c_out=$(ffprobe -v error -select_streams "$n" -show_entries stream=index \
                -of csv=p=0 "$out" 2>/dev/null | grep -c . || true)
        c_src=$(ffprobe -v error -select_streams "$n" -show_entries stream=index \
                -of csv=p=0 "$src" 2>/dev/null | grep -c . || true)
        if [ "${c_out:-0}" -lt "${c_src:-0}" ]; then
            issues+=("$n 流数量 $c_out < 源的 $c_src")
        fi
    done

    # 能否真正解出第一帧 —— 只看 ffprobe 元数据会漏掉「头正常但数据损坏」
    ffmpeg -v error -i "$out" -frames:v 1 -f null - >/dev/null 2>&1 \
        || issues+=("无法解码首帧")

    if [ ${#issues[@]} -gt 0 ]; then printf '%s\n' "${issues[@]}"; return 1; fi
    return 0
}

# 单独运行时打印诊断。用 ${BASH_SOURCE[0]:-} 兜底：被 zsh source 时
# BASH_SOURCE 不存在，直接引用会在 `set -u` 下报 parameter not set。
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    f=${1:?用法: stream-policy.sh <文件>}
    echo "流构成:"
    ffprobe -v error -show_entries stream=index,codec_type,codec_name,channels \
        -of csv=p=0 "$f" 2>/dev/null | sed 's/^/  /'
    echo "章节: $(ffprobe -v error -show_entries chapter=id -of csv=p=0 "$f" 2>/dev/null | grep -c .)"
    echo "音频参数: $(audio_args_for "$f")"
    echo -n "容器(auto): "; container_for "$f" auto
    echo
fi
