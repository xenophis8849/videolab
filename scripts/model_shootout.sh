#!/usr/bin/env bash
# 超分模型横评：同一份素材、同一条链，只换 ⑤ 那一步的模型。
#
# 三份素材 × 三个模型，输出到 out/shootout/，再生成带标注的 2x2 对比图
# （全画幅一张 + 100% 裁切一张 —— 缩略图上看不出细纹理差别，必须有原像素裁切）。
set -euo pipefail

M=$HOME/videolab/models/openmodeldb
OUT=$HOME/videolab/out/shootout
CMP=$HOME/videolab/compare/shootout
mkdir -p "$OUT" "$CMP"

# 名字:模型路径:额外参数
#   SPAN 是动态尺寸模型，能整帧推理、能吃 fp16 -> 快。
#   realplksr 两个是 256 固定尺寸导出，必须瓦片；而且 vsjetpack 的 fp16 自动转换
#   在它们身上会留下混合精度节点，只能 fp32。两条加起来慢约 23 倍。
MODELS=(
  "span:$M/2xLiveActionV1_SPAN_490000.onnx:"
  "plksr-real:$M/2xPublic_realplksr_dysample_layernorm_real_fp32_op17.onnx:VL_TILE=256 VL_FP16=0"
  "plksr-gan:$M/2xPublic_realplksr_dysample_layernorm_gan_fp32_op17.onnx:VL_TILE=256 VL_FP16=0"
)

for src in "$HOME"/videolab/src/*; do
    [ -f "$src" ] || continue
    base=$(basename "$src"); name=${base%.*}
    for entry in "${MODELS[@]}"; do
        tag=${entry%%:*}; rest=${entry#*:}
        model=${rest%%:*}; extra=${rest#*:}
        dst="$OUT/${name}__${tag}.mkv"
        [ -f "$dst" ] && { echo "跳过（已存在）: $dst"; continue; }
        echo "=== $name / $tag ==="
        # shellcheck disable=SC2086
        /usr/bin/time -f "  墙钟 %e s" \
            "$HOME/videolab/scripts/run_mvp1.sh" "$src" "$dst" \
            VL_UPSCALE_MODEL="/models/openmodeldb/$(basename "$model")" $extra \
            2>&1 | grep -E "^\[auto\]|^\[sar\]|Lsize|墙钟"
    done
done

echo
echo "===== 生成对比图 ====="
"$HOME/videolab/scripts/make_grid.sh" "$OUT" "$CMP"
