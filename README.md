# AutoGrade

AutoGrade 是 macOS 原生 AI 视频自动调色工具：按镜头分析视频，用 AdaInt（CVPR 2022）生成每镜头 3D LUT，再套用 LUT 导出视频。阶段 0–3 已完成，提供图形界面和命令行。

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
xcodebuild -project AutoGrade.xcodeproj -scheme AutoGradeAppTests \
  -derivedDataPath build/DerivedData test
xcodebuild -project AutoGrade.xcodeproj -scheme AutoGrade \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/AutoGrade.app
xcodebuild -project AutoGrade.xcodeproj -scheme autograde \
  -configuration Release -derivedDataPath build/DerivedData build
```

新增或删除文件后重新执行 `xcodegen generate`。构建会通过 `Tools/build-metallib.sh` 编译 Metal 算子，并使用 safe math 和 precise fp32 函数。

也可直接用已构建的 App 打开视频：

```bash
open -a build/DerivedData/Build/Products/Debug/AutoGrade.app fixtures/synthetic_shots.mp4
```

图形界面快捷键：

| 操作 | 快捷键 |
|---|---|
| 打开视频 | `⌘O` |
| 导出 | `⌘E` |
| 播放 / 暂停 | `空格` |
| 上一帧 / 下一帧 | `←` / `→` |
| 在播放头处加切点 | `⌘K` |
| 合并到上一个镜头 | `⌘⌫` |

命令行例如使用仓库内的合成视频，并同时导出每镜头 `.cube`：

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

## 使用图形界面

1. 使用 `⌘O`、将视频拖入窗口，或用上面的 `open -a` 命令打开视频。打开后自动分析，可在进度界面取消。
2. 左侧镜头列表显示调色后的缩略图、帧范围、时长及每镜头强度滑块（0–100%）；点击镜头可定位。预览可选分屏、仅原片或仅调色，分屏时可拖动分割线。
3. 时间线显示镜头与切点，可拖动定位；用空格播放或暂停，`←` / `→` 逐帧移动。在播放头处用 `⌘K` 加切点，用 `⌘⌫` 将当前镜头合并到上一个镜头。加切点只重新分析被拆的镜头，两半沿用原强度；合并时将两个镜头的累加和相加，不重新分析，沿用前一个镜头的强度。
4. 用 `⌘E` 导出，选择 HEVC 或 ProRes 422，并可同时为每个镜头导出 `.cube`。视频重名时，保存面板确认替换后先写入同目录临时文件，成功后再替换；`.cube` 重名会另行弹窗确认。
5. 在设置中选择跟随系统、English 或简体中文，语言立即生效，无需重启。

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

预览和导出使用同一份分析结果、含强度的最终 LUT 和 Metal 调色算子；预览分屏由 `Core/Shaders/Display.metal` 逐像素选择原片或调色画面，再经 `AVSampleBufferDisplayLayer` 显示。

## 正确性与实测

`Tests/` 将各数值环节与 `fixtures/` 对照。AiLUT 和均匀 LUT 算子的基准是上游官方 C++ CPU 算子；缩放和模型输出与 PyTorch 对照。`fixtures/manifest.json` 记录数据形状、类型和 SHA-256，测试读取时检查。容差表见 [CLAUDE.md 的精度与对照纪律](CLAUDE.md#精度与对照纪律)。

以下为 **2026-11-02 在 Apple M4 Max** 上的实测记录，并非本次重新运行的结果：

- XCTest：AutoGradeCore 22 个、AutoGradeAppTests 3 个，全部通过，0 跳过；新增测试均通过针对性的代码变异验证，改坏后会失败。
- 缩放最大误差 `1.2e-7`；CoreML vs PyTorch 的 LUT 最大误差 `3.6e-7`、vertices 最大误差 `1.8e-7`。
- AiLUT 套用在 4 张图上均为 8-bit `0 LSB`；`33³` 烘焙与镜头平均最大误差均为 `0.0`；`65³` 镜头 LUT 套用为 `0 LSB`。
- 解码平面与 ffmpeg 对照有 0 个样本不同；YUV→RGB 与项目颜色约定的最大误差为 `1.2e-7`。这里的颜色转换基准是约定公式，而不是 ffmpeg 的转换结果。
- ffmpeg `lut3d` 读取本项目 `.cube` 并套用，与 Metal 结果最大相差 `1 LSB`；`.cube` 文本与 research 侧逐字节一致，对照数据重新生成也逐字节一致。
- 变异检验中，将插值权重乘以 `0.999` 或将 YUV 系数 `1.5748` 改为 `1.57`，对应测试会失败；`65³` 容差因此从 `≤1 LSB` 收紧到 `0 LSB`。

端到端试跑的切镜与起点基准一致：`gym_1080p.mp4` 为 3 段 `[0–45, 46–143, 144–192]`；`comic_multishot.mp4` 为 6 段 `[0–31, 32–76, 77–140, 141–204, 205–293, 294–360]`。输出为 HEVC、带 BT.709 标签，帧数与原片一致。

阶段 3 的证据与实操记录：

- `testPreviewIsByteIdenticalToExport` 验证预览像素与导出编码前像素逐字节相同。`ExportRoundTripTests` 将 HEVC 导出按项目解码约定读回，实测各通道平均偏差的绝对值 ≤0.71 级；测试断言阈值为小于 1.5 级。
- 预览颜色以 QuickTime 为准：送入 `AVSampleBufferDisplayLayer` 的帧与解码器输出同为 8-bit 4:2:0 BT.709 limited（`420v`），使用相同标签和色彩空间。`gym` 第 101 帧画面中心 20% 的整屏截图（Display P3）中，预览为 `(126.0, 93.9, 52.0)`，QuickTime 为 `(126.4, 93.7, 52.2)`，各通道相差 ≤0.4 级；此前使用 CAMetalLayer 或 BGRA 送显示层时为 `(128.3, 98.7, 61.3)`。
- `gym_1080p` 为可变帧率，平均约 24 fps；播放显示 24.0 fps、丢帧 0。
- 界面实操中，打开分析得到 3 个镜头（帧 0–45、46–143、144–192）；在界面第 97 帧（内部第 96 帧）加切点后得到 4 个，合并后恢复 3 个。中英文切换生效，底部按钮与帧号在两种语言下均单行显示。

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

- 输入仅支持 8-bit 4:2:0 BT.709 limited range；10-bit、HDR、ProRes 输入和全范围视频会被拒绝，因此本项目导出的 ProRes 也不能作为输入。没有色彩矩阵标签时按 BT.709 处理并警告。
- 预览和导出都没有声音；不处理视频旋转元数据。
- 关闭 App 后切点与强度不保留；没有撤销 / 重做，也没有批处理。
- 镜头缩略图先缩小再调色，以 `CGImage` 显示，是近似结果，颜色可能与预览略有不同；以预览为准。
- 切镜使用颜色直方图，可处理硬切，不能识别叠化；`gym` 素材第 96 帧附近就是叠化，需要手动加切点。低饱和画面需使用阈值 `0.25`。
- FiveK 权重学的是“把照片修正常”，不是电影感风格，可能提亮刻意压暗的画面；风格训练是后续阶段。
- 命令行不会覆盖已有视频或 `.cube`；图形界面的替换方式见上方使用说明。

## 许可与素材

AdaInt 代码采用 Apache-2.0。模型权重用 MIT-Adobe FiveK 训练；FiveK 的两份许可（2026-11-02 核实，原文见 [`licenses/`](licenses/README.md)）只允许为自己的研究使用、不得用于商业目的，许可没有专门讲训练出的权重，本项目按“仅限研究、不得商用”对待。`fixtures/demo_*` 来自 FiveK 图片 `a4739`，受 `LicenseAdobeMIT` 约束，分发时须附许可全文。测试视频为即梦生成内容，整段视频不进 git，仅将少量抽帧缩小后放入 `fixtures/`。

## 项目规则

架构、目录、颜色约定、精度容差、已知坑和操作红线以 [CLAUDE.md](CLAUDE.md) 为准。界面自动化实操验收须遵守其中的[安全规则](CLAUDE.md#界面实操验收的安全规则2026-11-02-事故后定)：仅用辅助功能动作、不发送键盘事件，且每次需主人当场同意。
