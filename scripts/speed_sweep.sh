#!/usr/bin/env bash
# RealPLKSR 速度扫描：找出 23x 开销里哪些是导出格式造成的、能拿回来多少。
#
# **必须在 GPU 空闲时跑。** 和别的任务抢卡测出来的数字没有意义。
# 每组都用同一份素材、同样 200 帧、engine 缓存各自独立（改精度/瓦片都会换哈希）。
set -euo pipefail

SRC=${VL_SRC:?用法: VL_SRC=<容器内素材路径> speed_sweep.sh}
N=${VL_N:-200}
C=${VL_CONTAINER:-vsp}
M=/models/openmodeldb/2xPublic_realplksr_dysample_layernorm_real_fp32_op17.onnx
SPAN=/models/openmodeldb/2xLiveActionV1_SPAN_490000.onnx

run() {
    local label=$1; shift
    local envs=()
    for kv in "$@"; do envs+=(-e "$kv"); done
    printf '%-46s ' "$label"
    # 只抓 Output 行；失败时把 Critical 打出来，不要静默当成 0
    local out
    out=$(sudo docker exec -w /work -e VL_INPUT="$SRC" -e VL_FRAMES="$N" \
            "${envs[@]}" "$C" vspipe -c y4m /work/restore_mvp1.vpy /dev/null 2>&1) || true
    echo "$out" | grep -E '^Output' || echo "$out" | grep -m1 -E 'Critical|Error' || echo "(无输出，未知失败)"
}

echo "===== 参照 ====="
run "SPAN 整帧 fp16 streams=2"        "VL_UPSCALE_MODEL=$SPAN"
run "SPAN 整帧 fp32 streams=2"        "VL_UPSCALE_MODEL=$SPAN" VL_FP16=0
run "SPAN 瓦片256 fp16 streams=2"     "VL_UPSCALE_MODEL=$SPAN" VL_TILE=256
echo
echo "===== RealPLKSR 扫描 ====="
# fp16 的黑名单必须填**节点名**，不是算子类型 —— vsscale 把它当
# onnxconverter-common 的 node_block_list 用（源码 trt.py:438）。
# /to_img/Add_1 的一路输入来自一个已有的 Cast 节点，其 to 属性写死 FLOAT，
# fp16 转换不会改写它，于是两路精度不一致。屏蔽这一个节点即可，
# 它在 dysample 的末端上采样处，不是主体卷积，留在 fp32 几乎不花钱。
BL=/to_img/Add_1
run "基线 fp32 tile256 ov16 streams=2" "VL_UPSCALE_MODEL=$M" VL_FP16=0 VL_TILE=256
run "fp16 block Add_1 streams=2"       "VL_UPSCALE_MODEL=$M" VL_TILE=256 "VL_FP16_BLACKLIST=$BL"
run "fp16 block Add_1+Cast_1 streams=2" "VL_UPSCALE_MODEL=$M" VL_TILE=256 "VL_FP16_BLACKLIST=$BL,/to_img/Cast_1"
run "bf16 tile256 ov16 streams=2"      "VL_UPSCALE_MODEL=$M" VL_FP16=0 VL_BF16=1 VL_TILE=256
run "fp32 tile256 ov16 streams=4"      "VL_UPSCALE_MODEL=$M" VL_FP16=0 VL_TILE=256 VL_STREAMS=4
run "fp32 tile256 ov16 streams=6"      "VL_UPSCALE_MODEL=$M" VL_FP16=0 VL_TILE=256 VL_STREAMS=6
run "fp16 block + streams=4"           "VL_UPSCALE_MODEL=$M" VL_TILE=256 VL_STREAMS=4 "VL_FP16_BLACKLIST=$BL"
run "fp16 block + streams=6"           "VL_UPSCALE_MODEL=$M" VL_TILE=256 VL_STREAMS=6 "VL_FP16_BLACKLIST=$BL"
run "fp16 block + streams=4 + ov8"     "VL_UPSCALE_MODEL=$M" VL_TILE=256 VL_STREAMS=4 VL_OVERLAP=8 "VL_FP16_BLACKLIST=$BL"
run "fp16 block + streams=4 + opt5"    "VL_UPSCALE_MODEL=$M" VL_TILE=256 VL_STREAMS=4 VL_BUILD_OPT=5 "VL_FP16_BLACKLIST=$BL"
