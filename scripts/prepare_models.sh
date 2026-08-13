#!/usr/bin/env bash
# 预热模型缓存。跑一次就够，之后 run_mvp1.sh 可以完全断网跑。
#
# 分两类：
#   1. vsscale 自带 provider(DPIR / ArtCNN / Waifu2X) —— 用它自己的 CLI 下到
#      全局缓存 ~/.cache/vsscale/onnx/<provider>/<release>/。
#   2. OpenModelDB 上的第三方 ONNX —— 直接放在 $MODELS 下，用绝对路径喂给
#      GenericOnnxScaler。这类没有版本管理，文件名里带训练步数就是它的版本。
set -euo pipefail

IMAGE=${VL_IMAGE:-local/vsgpu:0.2.0}
CACHE=${VL_CACHE:-$HOME/videolab/cache}
MODELS=${VL_MODELS:-$HOME/videolab/models}

mkdir -p "$CACHE" "$MODELS/openmodeldb"

echo "== 1/2 DPIR (约 499 MB) =="
sudo docker run --rm --network=host \
    -v "$CACHE":/root/.cache/vsscale \
    "$IMAGE" vsscale onnx download DPIR --latest --global -y

echo "== 2/2 2xLiveActionV1_SPAN =="
# jcj83429 训练的 SPAN 2x，官方直接提供 ONNX，不需要 spandrel 转换。
# 训练退化里包含 JPEG/MPEG-4/H264/VP9/H265 压缩、色度二次采样、多次缩放的模糊、
# 过锐化光晕、糟糕去隔行的锯齿 —— 正好是 DVDRip 的伤。
# 它**不做降噪**，所以颗粒会被保留(这是优点，但重颗粒源要先降噪)；
# 作者明确说它处理不了 VHS 退化。
SPAN_URL=https://github.com/jcj83429/upscaling/raw/f73a3a02874360ec6ced18f8bdd8e43b5d7bba57/2xLiveActionV1_SPAN/2xLiveActionV1_SPAN_490000.onnx
if [ ! -f "$MODELS/openmodeldb/2xLiveActionV1_SPAN_490000.onnx" ]; then
    curl -fsSL -o "$MODELS/openmodeldb/2xLiveActionV1_SPAN_490000.onnx" "$SPAN_URL"
fi

echo "完成。缓存:"
du -sh "$CACHE"/* "$MODELS/openmodeldb" 2>/dev/null || true
