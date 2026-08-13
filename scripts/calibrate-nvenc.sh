#!/usr/bin/env bash
# hevc_nvenc 的档位校准 —— 把「高/中/低」从拍脑袋变成可测量的量。
#
#   calibrate-nvenc.sh <素材...>        文件名相对 $HOME/videolab/src/
#   BPPLIST="0.14 0.09 0.055" calibrate-nvenc.sh
#
# 方法直接复用转码项目的 quality-calibrate.sh：
#   - 指标 XPSNR（感知加权，JVET 用于编码器评估）。本机装不了 libvmaf。
#     经验判据：同源对比差 > 0.5 dB 是肉眼可辨的量级。
#   - 只用非病态素材。原脚本注释：叠加噪声的压力片噪声不可压缩，QP22 能跑出
#     175 Mbps，拿它定档位毫无意义。
#
# 但**数值不能复用**：那套 bpp 是为 hevc_vaapi 校的，nvenc 的码率-质量曲线不同。
#
# 与转码校准的关键差别 —— **参照物不是源文件，是修复链的输出。**
# 转码是「源 → 编码」，拿源当参照即可；修复是「源 → 修复 → 编码」，要评的是
# 最后那一步的损失，所以先把修复链的输出落成近无损中间文件当参照，再拿它去扫
# 各档 bpp。这样测出的是编码器的损失，不掺修复本身的改变。
set -uo pipefail

SRCS=${*:?用法: calibrate-nvenc.sh <素材...>（文件名相对 $HOME/videolab/src/）}
BPPLIST=${BPPLIST:-"0.20 0.14 0.11 0.09 0.07 0.055 0.04"}
IMAGE=${VL_IMAGE:-local/vsgpu:0.2.0}
HOME_VL=$HOME/videolab
REFDIR=$HOME_VL/work/calib-ref
OUT=$HOME_VL/work/calib-out
mkdir -p "$REFDIR" "$OUT"

M=/models/openmodeldb/2xLiveActionV1_SPAN_490000.onnx

# 近无损参照。用 ffv1（数学无损）而不是 x264 -qp 0：后者仍会经过一次 8/10bit
# 取整与色度处理，作为"修复链真实输出"的参照不够干净。
build_ref() {
    local src=$1 base=${1%.*} ref="$REFDIR/$base.mkv"
    [ -s "$ref" ] && { echo "$ref"; return; }
    echo "  构建无损参照: $base" >&2
    sudo docker run --rm --gpus all --network=none \
        -v "$HOME_VL/src":/in:ro -v "$REFDIR":/ref \
        -v "$HOME_VL/models":/models:ro -v "$HOME_VL/scripts":/scripts:ro \
        -v "$HOME_VL/work":/work -v "$HOME_VL/cache":/root/.cache/vsscale \
        -e VL_INPUT="/in/$src" -e VL_UPSCALE_MODEL="$M" \
        "$IMAGE" bash -eo pipefail -c "
            cp /scripts/restore_mvp1.vpy /work/
            vspipe -c y4m /work/restore_mvp1.vpy - |
            ffmpeg -hide_banner -loglevel error -y -i - -c:v ffv1 -level 3 -an '/ref/$base.mkv'
        " >&2 || { echo "参照构建失败: $src" >&2; return 1; }
    echo "$ref"
}

printf '%-14s %-8s %10s %10s %9s %8s\n' 素材 bpp 目标kbps 实际kbps XPSNR 用时s
printf '%s\n' "----------------------------------------------------------------------"

for src in $SRCS; do
    base=${src%.*}
    ref=$(build_ref "$src") || continue

    # 几何与帧率从参照本身读 —— 它已经是修复后的输出，不需要再猜
    read -r W H FN FD < <(sudo docker run --rm -v "$REFDIR":/ref:ro "$IMAGE" \
        ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,r_frame_rate -of csv=p=0 "/ref/$base.mkv" \
        | tr ',/' '  ')

    for bpp in $BPPLIST; do
        target=$(awk -v b="$bpp" -v w="$W" -v h="$H" -v n="$FN" -v d="$FD" \
                 'BEGIN{printf "%d", b*w*h*n/d}')
        # **产出必须与参照同容器（都用 mkv）。** MP4 的时基是 1/1000，MKV 是
        # 1/30000；两个输入时基不同时 xpsnr 会逐帧配对错位，亮度分量塌 10 dB
        # 而色度正常 —— 整批校准数据曾这样作废。ffmpeg 会打
        # "not matching timebases found ... results may be incorrect!"，
        # 当时被 grep 掉了没看见。
        o="$base-bpp$bpp.mkv"
        t0=$SECONDS
        sudo docker run --rm --gpus all --network=none \
            -v "$REFDIR":/ref:ro -v "$OUT":/out "$IMAGE" \
            bash -eo pipefail -c "
                ffmpeg -hide_banner -loglevel error -y -i '/ref/$base.mkv' \
                    -c:v hevc_nvenc -preset p6 -tune hq -rc vbr \
                    -b:v $target -maxrate $target -bufsize $((target*2)) \
                    -pix_fmt p010le -profile:v main10 -an '/out/$o'
            " >/dev/null 2>&1 || { echo "  编码失败 $o" >&2; continue; }
        dt=$((SECONDS - t0))

        read -r kbps xp < <(sudo docker run --rm -v "$REFDIR":/ref:ro -v "$OUT":/out:ro \
            "$IMAGE" bash -c "
                bytes=\$(stat -c%s /out/$o)
                dur=\$(ffprobe -v error -show_entries format=duration -of csv=p=0 /out/$o)
                kbps=\$(awk -v b=\$bytes -v d=\$dur 'BEGIN{printf \"%.0f\", b*8/1000/d}')
                # XPSNR 与 y: 之间是两个空格，别用 'XPSNR y' 匹配（转码项目踩过）
                out=\$(ffmpeg -hide_banner -loglevel info -i /out/$o -i /ref/$base.mkv \
                      -lavfi xpsnr -f null - 2>&1)
                # **时基不一致会让结果无声地错 10 dB。** 不允许静默通过 ——
                # 这条警告当时被 grep 掉，导致整批数据作废。
                if printf '%s' \"\$out\" | grep -qi 'not matching timebases'; then
                    echo \"0 TIMEBASE_MISMATCH\"; exit 0
                fi
                line=\$(printf '%s' \"\$out\" | grep -i 'XPSNR' | grep -i 'y:' | tail -1)
                xp=\$(printf '%s' \"\$line\" | sed -n 's/.*[Yy]:[[:space:]]*\([0-9.]*\).*/\1/p')
                echo \"\$kbps \${xp:-NA}\"
            ")
        printf '%-14s %-8s %10s %10s %9s %8s\n' "$base" "$bpp" "$target" "$kbps" "$xp" "$dt"
    done
    printf '%s\n' "----------------------------------------------------------------------"
done

echo
echo "读法：找 XPSNR 开始明显下滑的拐点。相邻档差 > 0.5 dB 才是肉眼可辨的量级；"
echo "差不到 0.5 dB 的两档之间，选码率低的那个。"
