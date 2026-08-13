#!/usr/bin/env bash
# 生成 A/B 对比图：左 = 源用 Lanczos 放大 2x，右 = 修复链输出。
#
# 为什么左边要缩放：只有在**同一输出几何**下比较，看到的差别才是这条链真正买到
# 的东西。跟原始 352x480 并排看，差别里有一大半只是"放大了"。
#
# **目标尺寸必须从输出文件读，不能写死 iw*2:ih*2。** 非方形像素的源（DVD 常见
# 352x480 SAR 20:11，显示 4:3）正确输出是 1280x960 而不是 704x960 —— 写死 2 倍
# 会让左右两侧**一起**错成压扁的 0.73:1，长宽比 bug 在对比图里就完全看不出来。
# 已经这样交付过一次。从输出读尺寸还有个好处：右边几何一旦错了，左边不会跟着错，
# 图会明显不对称。
#
#   ./make_compare.sh <源> <修复后> <输出目录> <时间点...>
set -euo pipefail

SRC=${1:?}
OUT=${2:?}
DIR=${3:?}
shift 3

IMAGE=${VL_IMAGE:-local/vsgpu:0.2.0}
mkdir -p "$DIR"

SRC_DIR=$(realpath "$(dirname "$SRC")"); SRC_B=$(basename "$SRC")
OUT_DIR=$(realpath "$(dirname "$OUT")"); OUT_B=$(basename "$OUT")
CMP_DIR=$(realpath "$DIR")
NAME=${OUT_B%.*}

# 用 `-of csv=p=0` 取逗号分隔再切，不要写 `csv=p=0:s=' '` —— ffprobe 8.x 的
# textformat 解析不了带空格的 s 选项，会报 "Failed to parse option string"。
OWH=$(sudo docker run --rm -v "$OUT_DIR":/enc:ro "$IMAGE" \
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=p=0 "/enc/$OUT_B")
OW=${OWH%%,*}
OH=${OWH##*,}
OH=${OH%$'\r'}
echo "对比目标几何: ${OW}x${OH}（取自输出文件）"

for t in "$@"; do
    tag=$(echo "$t" | tr ':.' '__')
    # 容器里必须 `set -e`：不然中间某条 ffmpeg 失败，最后的 rm 成功，
    # docker run 返回 0，外层的 set -e 也拦不住 —— 会安静地产出空目录。
    # 也不要用 drawtext 标注左右：镜像里没有任何字体，drawtext 会
    # 报 "Cannot find a valid font for the family Sans" 而整条 filter 初始化失败。
    # 改用一条 8 px 的黄色竖条分隔，左恒为源、右恒为修复后。
    sudo docker run --rm \
        -v "$SRC_DIR":/src:ro -v "$OUT_DIR":/enc:ro -v "$CMP_DIR":/cmp \
        "$IMAGE" bash -eo pipefail -c "
        ffmpeg -hide_banner -loglevel error -y -ss $t -i /src/$SRC_B -frames:v 1 \
            -vf 'scale=$OW:$OH:flags=lanczos,setsar=1' /cmp/_a.png
        ffmpeg -hide_banner -loglevel error -y -ss $t -i /enc/$OUT_B -frames:v 1 \
            -vf setsar=1 /cmp/_b.png
        ffmpeg -hide_banner -loglevel error -y -i /cmp/_a.png -i /cmp/_b.png \
            -filter_complex '[0:v]pad=iw+8:ih:0:0:yellow[a];[a][1:v]hstack' \
            /cmp/${NAME}_${tag}.png
        rm -f /cmp/_a.png /cmp/_b.png
    "
    echo "  $DIR/${NAME}_${tag}.png"
done
