#!/usr/bin/env bash
# 通用四路 2x2 带标注对比图。make_grid.sh 把四路写死成
# Lanczos/span/real/gan，换一组参数就没法用了，这个不限定内容。
#
#   grid4.sh <输出png> <时间点> <文件1> <标签1> ... <文件4> <标签4>
#
# 出两张：<输出png> 全画幅，<输出png 去后缀>_crop.png 是 100% 原像素中心裁切。
# **两张都要**：缩略图上看不出细纹理差别，只有原像素裁切能判；但全画幅才看得出
# 整体观感（过锐、色偏、接缝）。
set -euo pipefail

DST=$(realpath -m "${1:?}"); T=${2:?}; shift 2
IMAGE=${VL_IMAGE:-local/vsgpu:0.2.0}
CW=${VL_CROP_W:-640}
CH=${VL_CROP_H:-480}

[ $# -eq 8 ] || { echo "需要正好 4 组 <文件> <标签>" >&2; exit 1; }

DSTDIR=$(dirname "$DST"); mkdir -p "$DSTDIR"
NAME=$(basename "${DST%.*}")

files=(); labels=()
for i in 0 1 2 3; do
    f=$(realpath "$1"); shift
    [ -s "$f" ] || { echo "文件不存在或为空: $f" >&2; exit 1; }
    files+=("$f"); labels+=("$1"); shift
done

# 每个文件可能在不同目录，逐个单独挂载进去
mounts=(); ins=()
for i in 0 1 2 3; do
    mounts+=(-v "$(dirname "${files[$i]}")":/m$i:ro)
    ins+=("/m$i/$(basename "${files[$i]}")")
done

read -r W H < <(sudo docker run --rm "${mounts[0]}" "${mounts[1]}" "$IMAGE" \
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
    -of csv=p=0 "${ins[0]}" | tr ',' ' ')
cx=$(( (W - CW) / 2 )); cy=$(( (H - CH) / 2 )); fs=$(( H / 24 ))
echo "几何 ${W}x${H}，裁切 ${CW}x${CH} @ ${cx},${cy}"

# -e 必须排在镜像名**之前**，放后面 docker 会把它当成传给 bash 的参数，
# 环境变量根本不会进容器，而脚本里 ${IN0} 展开成空字符串、ffmpeg 报"文件不存在"，
# 错得离题万里。
envs=()
for i in 0 1 2 3; do
    envs+=(-e "IN$i=${ins[$i]}" -e "LB$i=${labels[$i]}")
done

sudo docker run --rm "${mounts[@]}" -v "$DSTDIR":/out "${envs[@]}" "$IMAGE" bash -eo pipefail -c "
  lbl() { echo \"drawtext=text='\$1':x=16:y=16:fontsize=$fs:fontcolor=yellow:box=1:boxcolor=black@0.65\"; }
  for i in 0 1 2 3; do
    eval \"src=\\\${IN\$i}\"; eval \"lb=\\\${LB\$i}\"
    ffmpeg -hide_banner -loglevel error -y -ss $T -i \"\$src\" -frames:v 1 \
      -vf \"scale=$W:$H:flags=lanczos,setsar=1,\$(lbl \"\$lb\")\" /out/_g\$i.png
    ffmpeg -hide_banner -loglevel error -y -ss $T -i \"\$src\" -frames:v 1 \
      -vf \"scale=$W:$H:flags=lanczos,setsar=1,crop=$CW:$CH:$cx:$cy,\$(lbl \"\$lb\")\" /out/_c\$i.png
  done
  ffmpeg -hide_banner -loglevel error -y -i /out/_g0.png -i /out/_g1.png -i /out/_g2.png -i /out/_g3.png \
    -filter_complex '[0][1]hstack[t];[2][3]hstack[b];[t][b]vstack' /out/$NAME.png
  ffmpeg -hide_banner -loglevel error -y -i /out/_c0.png -i /out/_c1.png -i /out/_c2.png -i /out/_c3.png \
    -filter_complex '[0][1]hstack[t];[2][3]hstack[b];[t][b]vstack' /out/${NAME}_crop.png
  rm -f /out/_g[0-3].png /out/_c[0-3].png
"

echo "  -> $DSTDIR/$NAME.png"
echo "  -> $DSTDIR/${NAME}_crop.png"
