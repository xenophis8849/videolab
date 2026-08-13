# local/vsgpu — VapourSynth + vsjetpack 视频修复运行基座
#
# 0.2.0 相对 0.1.0 的根本改动：**全部改用 PyPI wheel，不再从源码编译任何东西。**
# 0.1.0 是手搓源码构建（zimg master + VapourSynth meson + vs-mlrt cmake），编出来
# 只有 4 个插件命名空间（std/resize/text/trt），而且踩了六轮坑。JET
# (jaded-encoding-thaumaturgy) 已经把整条链打成 wheel 发在 PyPI 上，`vsjetpack`
# 的 extras 就是官方维护的依赖集合。装完是 44 个命名空间，DPIR 实测同样 80 fps
# @640x480（0.1.0 是 78.3），engine 构建反而更快（23.7s vs 37.9s）。
#
# TensorRT 版本问题在这条路线上自动消失：0.1.0 必须把 TRT 钉在 10.16.1，因为
# vs-mlrt 15.16 的 vsmlrt.py 通过 trtexec 建 engine，发的 `--inputIOFormats=fp32:chw`
# 在 TRT 11 已被取消。wheel 路线根本不装 trtexec —— vsjetpack 用 TensorRT 的
# Python binding 在进程内建 engine，所以 mlrt 16.1 + TRT 11.2.1 是上游自己配好的组合。
#
# 基础镜像仍用 nvidia/cuda:12.8.1-base-ubuntu24.04：GPU 节点拉不到 Docker Hub
# (registry-1.docker.io 直接 EOF)，这个镜像是本机唯一已缓存的、且正好是
# Ubuntu 24.04 + Python 3.12 —— vsjetpack 要求 >=3.12，两台宿主机的 3.14 太新。
# 注意 pip 装进来的是 CUDA **13** 系运行时(tensorrt_cu13 / cudnn-cu13 /
# cuda-python 13)，它们自带 .so，不依赖基础镜像的 12.8，实测共存无问题。
#
# 构建必须加 --network=host：容器默认 DNS 走网关，若网关的 DNS 返回不可路由的
# fake-ip（常见于带代理/分流的网关），apt/pip 全部拿不到索引。
#
#   docker build --network=host -t local/vsgpu:0.2.0 .
FROM nvidia/cuda:12.8.1-base-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    LANG=C.UTF-8

# libglib2.0-0 是给 subtext.so 的：不装它 VapourSynth 每次启动都打印
# "Failed to load subtext.so ... libglib-2.0.so.0"。字幕直通要用到这个插件。
# 其余都是纯运行时依赖，没有编译链 —— 这一层刻意保持小。
# libpython3.12t64 必须显式装。Ubuntu 的 python3 是静态链接 libpython 的，
# `vapoursynth config` 靠 dladdr 找 libpython 的绝对路径，找不到就报
# "Failed to determine Python symbol path"，接着 vspipe 全部起不来。
# 它是 python3-pip 的 Recommends 而不是 Depends —— 交互式 `apt install python3-pip`
# 会顺带装上，加了 --no-install-recommends 的 Dockerfile 里就没有。
# 这正是"手动试都好、一进构建就炸"的第二个来源(第一个是 vapoursynth config 本身)。
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip libpython3.12t64 \
        libglib2.0-0t64 \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# nvidia-container-toolkit 不会自己创建 OpenCL ICD，即使
# NVIDIA_DRIVER_CAPABILITIES 里有 compute。缺它 pyopencl 会以
# `clGetPlatformIDs failed: PLATFORM_NOT_FOUND_KHR` 抛出，而 vsscale.get_gpu() /
# is_gpu_available() 走的正是 pyopencl —— 于是一个只是想查 GPU 的调用把整条链打断。
RUN mkdir -p /etc/OpenCL/vendors \
 && echo libnvidia-opencl.so.1 > /etc/OpenCL/vendors/nvidia.icd
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics,video

# ---- VapourSynth 生态 ----
# requirements.lock.txt 是从一次验证通过的安装里 `pip freeze` 出来的，作为
# constraints 用(-c 而不是 -r)：让 pip 照常解析 vsjetpack 的依赖图，但每个版本都钉死。
# 这正是 0.1.0 最痛的地方 —— TRT 的版本是被 apt 的默认解析悄悄换掉的。
#
# extras 必须显式列全。只写 `vsjetpack` 不带 extras 的话，znedi3 / vivtc /
# mvutensils / bm3dcuda 这些插件一个都不会装进来(它们全在 extras 里)，
# 而 Python wrapper 却能 import 成功 —— 直到运行时才报找不到插件。
#   nvidia      -> trt / trt_rtx / ort_cuda / ncnn 后端 + bm3dcuda + bilateralgpu + cudnn
#   source      -> bestsource / lsmas / ffms2 / d2v / dvdsrc2
#   deinterlace -> znedi3 / vivtc / bwdif / dmetrics / sangnom（QTGMC 与 IVTC 的底座）
#   denoise     -> bm3d 全家 / nlm-ispc / dfttest2 / mvutensils / deblock
#   scale/kernels/rg -> descale / resize2 / placebo / zsmooth / awarp
ARG VSJETPACK_VERSION=2.2.0
COPY requirements.lock.txt /tmp/requirements.lock.txt
RUN pip install --no-cache-dir \
        --extra-index-url https://jaded-encoding-thaumaturgy.github.io/vs-wheels/simple \
        -c /tmp/requirements.lock.txt \
        "vsjetpack[nvidia,source,deinterlace,denoise,scale,rg,kernels]==${VSJETPACK_VERSION}" \
 && rm -f /tmp/requirements.lock.txt \
 && python3 -m vapoursynth config \
 && vspipe --version \
 && python3 -c "import vapoursynth as vs; ns=sorted(p.namespace for p in vs.core.plugins()); print(len(ns), ns); assert 'trt' in ns and 'znedi3' in ns and 'vivtc' in ns and 'bm3dcuda' in ns"

# `vapoursynth config` 那一步不可省：它把解释器和 libpython 的绝对路径写进
# /root/.config/vapoursynth/vapoursynth.toml，VSScript 靠这份配置初始化。不跑它
# `vspipe --version` 直接失败于 "Python executable and library path couldn't be
# determined"。容易误判的地方是：**在 Python 里 `import vapoursynth` 会顺手把这份
# 配置生成出来**，所以只要先跑过一次 python 就看不到这个错 —— 交互式探索时正常、
# 一进 Dockerfile 就炸，原因就在这。配置落在 $HOME 下，换用户跑容器要重跑一次。

# ---- 插件的系统库依赖 ----
# 这些是 pip 装进来的插件 .so 需要、而基础镜像没有的共享库。刻意放在 pip 层
# **之后**，因为是"装完才知道缺什么"：VapourSynth 加载插件失败时只在 stderr 打一行
# warning 就继续跑，命名空间静静地少几个，直到脚本里用到才报"没有这个滤镜"。
#   libatomic1 -> fmtconv（位深转换/抖动，QTGMC 链上会用到）
#   libx11-6   -> lsmashsource（备用源滤镜；默认走 bestsource，但留着有用）
# 注意 libcuda.so.1 不在这里 —— 它由 nvidia-container-toolkit 在运行时注入，
# 所以 bm3dcuda_rtc / dfttest2_cuda / bilateralgpu_rtc / vszipcu 这几个在
# `docker run` 不带 --gpus all 时必然加载失败，那是正常的，不要去"修"。
RUN apt-get update && apt-get install -y --no-install-recommends \
        libatomic1 libx11-6 \
    && rm -rf /var/lib/apt/lists/*

# ---- 缓存目录 ----
# 两级缓存，都必须挂出来，否则每次起容器都要重下模型、重建 engine：
#   1. ONNX 模型全局缓存 ~/.cache/vsscale/onnx/<provider>/<release>/  (DPIR 一套 499 MB)
#      用 `vsscale onnx download DPIR --latest --global -y` 填充。
#   2. `.vsjet/vsscale/{onnx,artifact}` —— 放 fp16 转换后的 onnx 和构建好的
#      `<hash>.engine`(DPIR 640x480 fp16 约 66 MB)。**它建在 .vpy 脚本自己所在的
#      目录下**，不是 cwd、也不是 $HOME：vstools 的 PackageStorage 用
#      `get_script_path()` 定位，只有拿不到脚本路径时才退回 cwd。所以驱动脚本
#      是把 .vpy 复制进 /work 再执行的，而 /work 必须是挂载卷。
#      engine 按 模型x分辨率x精度xGPUxTRT版本 哈希，换任何一项都会重建(约 24 s)。
VOLUME /root/.cache/vsscale
WORKDIR /work

# ---- ffmpeg ----
# 刻意放在 pip 层**之后**：pip 那层要跑 14 分钟(光 tensorrt_cu13_libs 就 3.8 GB)，
# 放在它前面的话，换个 ffmpeg 版本就要连带把 pip 重跑一遍。
#
# 用 BtbN 的静态 gpl 构建而不是 Ubuntu 24.04 的 ffmpeg 6.1 + SVT-AV1 1.7：
# 归档母版要 SVT-AV1 preset 4-6，日常观看档要 av1_nvenc(Ada 第 8 代 NVENC)。
# **必须是 8.x**：n7.1 的产物里只有 h264_nvenc / hevc_nvenc，没有 av1_nvenc(已实测)。
# 按 autobuild 的日期 tag 钉死具体产物，不要用 `latest` 或 master —— 两者都是移动靶。
ARG FFMPEG_RELEASE=autobuild-2026-08-06-13-39
ARG FFMPEG_BUILD=ffmpeg-n8.1.2-34-g9b6c8969e0-linux64-gpl-8.1
RUN curl -fsSL "https://github.com/BtbN/FFmpeg-Builds/releases/download/${FFMPEG_RELEASE}/${FFMPEG_BUILD}.tar.xz" \
      -o /tmp/ffmpeg.tar.xz \
 && tar -xJf /tmp/ffmpeg.tar.xz -C /tmp \
 && install -m 0755 /tmp/${FFMPEG_BUILD}/bin/ffmpeg /tmp/${FFMPEG_BUILD}/bin/ffprobe /usr/local/bin/ \
 && rm -rf /tmp/ffmpeg.tar.xz /tmp/${FFMPEG_BUILD} \
 && ffmpeg -hide_banner -encoders 2>/dev/null | grep -E 'libsvtav1|av1_nvenc'

# 字体：ffmpeg 的 drawtext 需要 fontconfig 能找到至少一款字体，否则报
# "Cannot find a valid font for the family Sans" 而**整条 filter graph 初始化失败**
# —— 不是只丢标注，是整条命令挂掉。做 A/B 对比图要给每一路打标签，没标签的
# 多路对比图基本没法用。放在最后一层，加它只花几秒。
RUN apt-get update && apt-get install -y --no-install-recommends \
        fonts-dejavu-core fontconfig \
    && rm -rf /var/lib/apt/lists/* \
    && fc-match sans
