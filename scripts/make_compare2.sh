#!/usr/bin/env bash
# 两个**输出**之间的对比（不涉及源）。用于比较两组参数，例如去噪开/关。
# 左 = 第一个文件，右 = 第二个，中间黄线。
#
#   ./make_compare2.sh <A.mkv> <B.mkv> <输出目录> <时间点...>
set -euo pipefail

A=${1:?}; B=${2:?}; DIR=${3:?}; shift 3
IMAGE=${VL_IMAGE:-local/vsgpu:0.2.0}
mkdir -p "$DIR"

A_DIR=$(realpath "$(dirname "$A")"); A_B=$(basename "$A")
B_DIR=$(realpath "$(dirname "$B")"); B_B=$(basename "$B")
CMP=$(realpath "$DIR")
NAME="${A_B%.*}__vs__${B_B%.*}"

for t in "$@"; do
    tag=$(echo "$t" | tr ':.' '__')
    sudo docker run --rm -v "$A_DIR":/a:ro -v "$B_DIR":/b:ro -v "$CMP":/cmp \
        "$IMAGE" bash -eo pipefail -c "
        ffmpeg -hide_banner -loglevel error -y -ss $t -i /a/$A_B -frames:v 1 -vf setsar=1 /cmp/_1.png
        ffmpeg -hide_banner -loglevel error -y -ss $t -i /b/$B_B -frames:v 1 -vf setsar=1 /cmp/_2.png
        ffmpeg -hide_banner -loglevel error -y -i /cmp/_1.png -i /cmp/_2.png \
            -filter_complex '[0:v]pad=iw+8:ih:0:0:yellow[a];[a][1:v]hstack' /cmp/${NAME}_${tag}.png
        rm -f /cmp/_1.png /cmp/_2.png
    "
    echo "  $DIR/${NAME}_${tag}.png"
done
