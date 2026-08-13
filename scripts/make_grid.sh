#!/usr/bin/env bash
# 四路 2x2 带标注对比图：Lanczos 基线 / SPAN / plksr-real / plksr-gan。
#
# 每份素材出两张：
#   *_full.png  全画幅，看整体观感（油画感、过锐、色彩）
#   *_crop.png  100% 原像素裁切，看细纹理 —— **缩略图上分不出模型差别，必须有这张**
#
#   ./make_grid.sh <shootout输出目录> <对比图目录>
set -euo pipefail

OUT=$(realpath "${1:?}")
CMP=$(realpath "${2:?}")
IMAGE=${VL_IMAGE:-local/vsgpu:0.2.0}
SRC=$(realpath "${VL_SRC:-$HOME/videolab/src}")
T=${VL_TIME:-00:00:15}
CW=${VL_CROP_W:-640}      # 100% 裁切窗口
CH=${VL_CROP_H:-480}
mkdir -p "$CMP"

for f in "$OUT"/*__span.mkv; do
    name=$(basename "$f" __span.mkv)
    # 只处理三路都齐的素材：横评还在跑时也能先出已完成的那几组。
    # 不加这个守卫的话，缺文件会让 ffmpeg 失败、set -e 直接中止整个循环，
    # 已经跑完的组也拿不到图。
    missing=0
    for tag in plksr-real plksr-gan; do
        [ -s "$OUT/${name}__${tag}.mkv" ] || missing=1
    done
    if [ "$missing" = 1 ]; then echo "跳过 $name（三路未齐）"; continue; fi
    src=$(ls "$SRC/$name".* | head -1)
    src_b=$(basename "$src")

    read -r W H < <(sudo docker run --rm -v "$OUT":/o:ro "$IMAGE" \
        ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=p=0 "/o/$(basename "$f")" | tr ',' ' ')
    echo "$name: 目标 ${W}x${H}"

    # 裁切窗口取画面中心；标注字号按画幅缩放，太小在 2x2 拼图里看不清。
    cx=$(( (W - CW) / 2 )); cy=$(( (H - CH) / 2 ))
    fs=$(( H / 24 ))

    sudo docker run --rm -v "$SRC":/src:ro -v "$OUT":/o:ro -v "$CMP":/cmp "$IMAGE" \
      bash -eo pipefail -c "
        lbl() { echo \"drawtext=text='\$1':x=16:y=16:fontsize=$fs:fontcolor=yellow:box=1:boxcolor=black@0.65\"; }

        # 基线：源缩放到与输出完全相同的几何（不是写死 2x —— 非方形像素源会错）
        ffmpeg -hide_banner -loglevel error -y -ss $T -i '/src/$src_b' -frames:v 1 \
          -vf \"scale=$W:$H:flags=lanczos,setsar=1,\$(lbl 'Lanczos (no AI)')\" /cmp/_0.png
        i=1
        for tag in span plksr-real plksr-gan; do
          ffmpeg -hide_banner -loglevel error -y -ss $T -i \"/o/${name}__\$tag.mkv\" -frames:v 1 \
            -vf \"setsar=1,\$(lbl \"\$tag\")\" /cmp/_\$i.png
          i=\$((i+1))
        done
        ffmpeg -hide_banner -loglevel error -y -i /cmp/_0.png -i /cmp/_1.png -i /cmp/_2.png -i /cmp/_3.png \
          -filter_complex '[0][1]hstack[t];[2][3]hstack[b];[t][b]vstack' /cmp/${name}_full.png

        # 100% 裁切：先裁再标注，保证是原像素，没有任何缩放
        ffmpeg -hide_banner -loglevel error -y -ss $T -i '/src/$src_b' -frames:v 1 \
          -vf \"scale=$W:$H:flags=lanczos,setsar=1,crop=$CW:$CH:$cx:$cy,\$(lbl 'Lanczos (no AI)')\" /cmp/_c0.png
        i=1
        for tag in span plksr-real plksr-gan; do
          ffmpeg -hide_banner -loglevel error -y -ss $T -i \"/o/${name}__\$tag.mkv\" -frames:v 1 \
            -vf \"setsar=1,crop=$CW:$CH:$cx:$cy,\$(lbl \"\$tag\")\" /cmp/_c\$i.png
          i=\$((i+1))
        done
        ffmpeg -hide_banner -loglevel error -y -i /cmp/_c0.png -i /cmp/_c1.png -i /cmp/_c2.png -i /cmp/_c3.png \
          -filter_complex '[0][1]hstack[t];[2][3]hstack[b];[t][b]vstack' /cmp/${name}_crop.png

        rm -f /cmp/_[0-9].png /cmp/_c[0-9].png
      "
    echo "  -> $CMP/${name}_full.png  $CMP/${name}_crop.png"
done
