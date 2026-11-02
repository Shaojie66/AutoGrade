# AutoGrade

AutoGrade 是 macOS 原生 AI 视频自动调色工具：按镜头分析视频，用 AdaInt（CVPR 2022）生成每镜头 3D LUT，再套用 LUT 导出视频。阶段 0–2 已完成；目前只有命令行，图形界面尚未实现。

运行时使用 Swift、Metal、CoreML 和 AVFoundation，不依赖 Python 或 ffmpeg。Python 仅用于 `research/` 中的模型转换与对照数据生成。

## 环境要求

- macOS 15 或更新版本、Apple Silicon、Xcode 和 `xcodegen`。
- 研究侧使用 `uv` 和 Python 3.11；生成对照数据还需要 `ffmpeg`、`ffprobe` 及原始测试视频。
- 完整测试需要 `ffmpeg`：找不到时，读取 `.cube` 的 ffmpeg 对照测试会跳过。请检查测试数量和跳过数量。

## 构建、测试与运行

在仓库根目录执行。构建前需要 `Resources/Models/AdaIntFiveK.mlpackage`；若缺失，先按下方研究工作流生成。

```bash
xcodegen generate
xcodebuild -project AutoGrade.xcodeproj -scheme AutoGradeCore \
  -derivedDataPath build/DerivedData test
xcodebuild -project AutoGrade.xcodeproj -scheme autograde \
  -configuration Release -derivedDataPath build/DerivedData build
```

新增或删除文件后重新执行 `xcodegen generate`。构建会通过 `Tools/build-metallib.sh` 编译 Metal 算子，并使用 safe math 和 precise fp32 函数。

例如，使用仓库内的合成视频，并同时导出每镜头 `.cube`：

```bash
mkdir -p out
build/DerivedData/Build/Products/Release/autograde fixtures/synthetic_shots.mp4 \
  -o out/synthetic_graded.mov --cube-dir out --cut 0.25 --size 65 --codec hevc
```

命令格式及参数：

```text
autograde <input> -o <output.mov> [--cube-dir DIR] [--cut 0.25] [--size 65] [--codec hevc|prores]
```

- `-o` / `--output`：输出视频路径，容器为 `.mov`。
- `--cube-dir`：可选，按输入文件名前缀导出每镜头 `.cube`。
- `--cut`：颜色直方图 L1 距离切镜阈值，默认 `0.25`。
- `--size`：镜头 LUT 的每轴格点数，默认 `65`，允许 `2...129`。
- `--codec`：输出编码 `hevc` 或 `prores`，默认 `hevc`。`-h` / `--help` 显示用法。

视频或 `.cube` 输出文件已存在时会拒绝覆盖；请使用新的输出路径。

## 工作原理

```text
第一遍：视频 → 解码 → YUV→RGB → 缩放 → AdaInt 逐帧预测 LUT 和 vertices
                                      ↓
             直方图切镜 ← 缩略图    烘焙到均匀 LUT 格点
                    └──── 每镜头累加、平均并截断 → 分析结果

第二遍：同一视频 → 解码 → YUV→RGB → 套用对应镜头 LUT → 编码 .mov
                                             └→ 可选导出每镜头 .cube
```

`Core/AutoGrader.swift` 编排两遍流程；`Core/VideoIO.swift` 负责视频读写，`Core/ShotDetector.swift` 负责切镜，`Core/Grader.swift` 调用 CoreML 模型。`Core/Kernels.swift` 和 `Core/Shaders/Grade.metal` 实现颜色转换、缩放、LUT 烘焙与套用等计算；`Core/CubeWriter.swift` 写出 `.cube`。`CLI/main.swift` 负责参数解析和结果输出。

模型使用 FiveK sRGB 权重。输入按 display-referred 处理；缩放使用双线性插值、`align_corners=False`，每镜头 LUT 是该镜头逐帧烘焙结果的平均值，最后截断到 `[0, 1]`。具体颜色约定见 [CLAUDE.md](CLAUDE.md)。

## 正确性与实测

`Tests/` 将各数值环节与 `fixtures/` 对照。AiLUT 和均匀 LUT 算子的基准是上游官方 C++ CPU 算子；缩放和模型输出与 PyTorch 对照。`fixtures/manifest.json` 记录数据形状、类型和 SHA-256，测试读取时检查。容差表见 [CLAUDE.md 的精度与对照纪律](CLAUDE.md#精度与对照纪律)。

以下为 **2026-11-02 在 Apple M4 Max** 上的实测记录，并非本次重新运行的结果：

- XCTest：13 个，0 失败，0 跳过。
- 缩放最大误差 `1.2e-7`；CoreML vs PyTorch 的 LUT 最大误差 `3.6e-7`、vertices 最大误差 `1.8e-7`。
- AiLUT 套用在 4 张图上均为 8-bit `0 LSB`；`33³` 烘焙与镜头平均最大误差均为 `0.0`；`65³` 镜头 LUT 套用为 `0 LSB`。
- 解码平面与 ffmpeg 对照有 0 个样本不同；YUV→RGB 与项目颜色约定的最大误差为 `1.2e-7`。这里的颜色转换基准是约定公式，而不是 ffmpeg 的转换结果。
- ffmpeg `lut3d` 读取本项目 `.cube` 并套用，与 Metal 结果最大相差 `1 LSB`；`.cube` 文本与 research 侧逐字节一致，对照数据重新生成也逐字节一致。
- 变异检验中，将插值权重乘以 `0.999` 或将 YUV 系数 `1.5748` 改为 `1.57`，对应测试会失败；`65³` 容差因此从 `≤1 LSB` 收紧到 `0 LSB`。

端到端试跑的切镜与起点基准一致：`gym_1080p.mp4` 为 3 段 `[0–45, 46–143, 144–192]`；`comic_multishot.mp4` 为 6 段 `[0–31, 32–76, 77–140, 141–204, 205–293, 294–360]`。输出为 HEVC、带 BT.709 标签，帧数与原片一致。

速度仅供参考：Release 构建、机器负载 23–25、`ollama` 占用 200% 以上 CPU 时，4K 分析约 `15–17 ms/帧`、渲染约 `14–17 ms/帧`；1080p 分析约 `5–9 ms/帧`、渲染约 `5 ms/帧`。模型推理稳态约 `2.4–4.4 ms/帧`；进程首次调用 CoreML 有一次性编译开销，该次平均约 `30 ms/帧`。

## research 工作流

以下命令在仓库根目录执行，Python 均以 `-I` 运行。`research/fetch_upstream.sh` 固定上游 AdaInt commit；目标目录已存在但不是指定 commit 时，脚本报错退出，不会删除它。

```bash
research/fetch_upstream.sh
uv venv --python 3.11 research/.venv
uv pip install --python research/.venv/bin/python -r research/requirements.txt
research/.venv/bin/python -I research/convert_coreml.py
```

转换脚本生成 `Resources/Models/AdaIntFiveK.mlpackage`，并将保存后的 CoreML 模型与 PyTorch 对照；生成模型会写入该路径。随后可生成或验证对照数据：

```bash
PATH="$PWD/research/.venv/bin:$PATH" research/.venv/bin/python -I research/make_fixtures.py
PATH="$PWD/research/.venv/bin:$PATH" research/.venv/bin/python -I research/make_fixtures.py --verify
```

生成脚本需要上游仓库的素材，以及 `~/camera/experiments/adaint/data/` 下的 `gym_1080p.mp4`、`comic_multishot.mp4`。直接生成会覆盖 `fixtures/` 中对应文件；`--verify` 在临时目录重新生成并逐字节比较。`research/oracle/ailut.py` 使用上游 CPU 算子作为对照。

## 已知限制

- 输入仅支持 8-bit 4:2:0 BT.709 limited range；10-bit、HDR、ProRes 输入和全范围视频会被拒绝。没有色彩矩阵标签时按 BT.709 处理并警告。
- 不保留音频，不处理视频旋转元数据。
- 第一版切镜使用颜色直方图，可处理硬切，不能识别叠化；`gym` 素材第 96 帧附近就是叠化。低饱和画面需使用阈值 `0.25`。
- FiveK 权重学的是“把照片修正常”，不是电影感风格，可能提亮刻意压暗的画面；风格训练是后续阶段。
- 已存在的输出文件不会被覆盖。

## 许可与素材

AdaInt 代码采用 Apache-2.0；FiveK 训练出的权重可能仅限研究用途，许可尚未核实。核实前不公开发布项目、不分发权重。测试视频为即梦生成内容，整段视频不进 git，仅将少量抽帧缩小后放入 `fixtures/`。

## 项目规则

架构、目录、颜色约定、精度容差、已知坑和操作红线以 [CLAUDE.md](CLAUDE.md) 为准。
