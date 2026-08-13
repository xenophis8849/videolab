#!/usr/bin/env bash
# 排除 plksr 表现差的两个混淆因素。基线是 shootout 里同一素材的 plksr-real 那一路。
#
#   ov64      瓦片重叠 16 -> 64。PLKSR 是大核卷积，感受野远大于普通卷积，
#             16 像素的重叠可能不足以消除接缝。
#   nodeblock 关掉链路里的 DPIR 去块效应。plksr 的训练输入是"带压缩伤害的图"，
#             我提前用 DPIR 把伤害清掉了，可能让它无的放矢、转而强化正常边缘。
#
#   VL_SRC=<素材路径> plksr_confounds.sh
set -euo pipefail

M=/models/openmodeldb/2xPublic_realplksr_dysample_layernorm_real_fp32_op17.onnx
OUT=$HOME/videolab/out/shootout
SRC=${VL_SRC:?用法: VL_SRC=<素材路径> plksr_confounds.sh}
BASE=$(basename "${SRC%.*}")

run() {
    local tag=$1; shift
    local dst="$OUT/${BASE}__plksr-real-$tag.mkv"
    [ -f "$dst" ] && { echo "跳过 $tag"; return; }
    echo "=== $tag ==="
    /usr/bin/time -f "  墙钟 %e s" "$HOME/videolab/scripts/run_mvp1.sh" "$SRC" "$dst" \
        VL_UPSCALE_MODEL="$M" VL_FP16=0 VL_TILE=256 "$@" 2>&1 | grep -E "Lsize|墙钟"
}

run ov64      VL_OVERLAP=64
run nodeblock VL_DEBLOCK=0
run ov64-nodeblock VL_OVERLAP=64 VL_DEBLOCK=0
