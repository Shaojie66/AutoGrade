# CLAUDE.md —— AutoGrade 规则

macOS 原生 AI 视频自动调色。本文件是**规则的唯一来源**；`AGENTS.md` 只指向这里。
要改规则，先改这里，再改代码。

## 这个项目是什么

视频进 → 按镜头切分 → 每个镜头由模型（AdaInt, CVPR 2022）生成一个 3D LUT → 套用并导出视频，同时导出每镜头 `.cube`。

- 来历：`~/camera/experiments/adaint/` 的试跑（2026-11-02）。那里的数字是本项目的起点基准，见文末。
- 当前权重：AdaInt **FiveK sRGB**。它学的是"把照片修正常"，不是电影感风格；风格训练是后续阶段。

## 架构原则

1. **一个进程，运行时没有 Python。** Swift + Metal + CoreML + AVFoundation。Python 只存在于 `research/`，用于模型转换、生成对照数据、将来训练。产品代码不得调用、依赖或打包任何 Python 与 ffmpeg。
2. **对照先于功能。** 每个数值环节（缩放、模型、AiLUT 应用、烘焙、平均、`.cube`）都有黄金数据和 XCTest 对照。基准是**上游官方 C++ CPU 算子**（`research/oracle/`），不是我们自己的 PyTorch 改写。
3. **两遍处理。** 第一遍分析（预测 LUT、切镜、每镜头平均），第二遍渲染。预览和导出读同一份分析结果。
5. **预览像素 = 导出编码前像素；预览显示 = QuickTime 显示。** App 预览与导出走同一组 Metal 算子、同一份每镜头最终 LUT（含强度）；`testPreviewIsByteIdenticalToExport` 逐字节锁定。App 不得有自己的调色或颜色转换代码路径。
   上屏走 AVFoundation 的视频显示路径（`AVSampleBufferDisplayLayer`），送入的是和解码器输出**同格式同标签**的帧：8-bit 4:2:0 BT.709 limited（'420v'），带原色/传递函数/矩阵、色度位置 Left 和 `kCVImageBufferCGColorSpaceKey`（由这些标签推导出的 CoreMedia709）。RGB→YUV 用架构原则 4 的同一矩阵；色度取偶数列、上下两行平均（与解码约定的采样位置对应）。**不自己挑 CGColorSpace 或 gamma 去凑**。2026-11-02 实测：CAMetalLayer+`itur_709` 和 BGRA 送显示层都比 QuickTime 亮（同屏整屏截图中心 (128.3, 98.7, 61.3) vs (126.4, 93.7, 52.2)），而导出文件本身无偏（`ExportRoundTripTests`），差在 RGB 上屏这一步。对比分屏由 `Display.metal` 逐像素选源，不重采样。
6. **App 只做界面。** 数值逻辑（切点合并/拆分、强度、取消）都在 Core 并有测试；`App/` 里只有状态、视图和调度。
4. **颜色约定显式写出，不靠默认值。** 视频按 display-referred 处理（FiveK sRGB 权重的输入假设）。改动任一约定都要同时更新对照数据（`research/make_fixtures.py` 是这些约定的可执行定义）：
   - **YUV→RGB**：只接受 8-bit 4:2:0 BT.709 limited range（其他输入报错，不猜）。`Y'=(Y−16)/219`，`Cb'=(Cb−128)/224`，`Cr'=(Cr−128)/224`；`R=Y'+1.5748Cr'`，`G=Y'−0.187324Cb'−0.468124Cr'`，`B=Y'+1.8556Cb'`，截断到 [0,1]。色度双线性上采样，边缘钳位，采样位置 MPEG-2/H.264 默认：亮度 (x,y) 读色度平面连续坐标 (x/2, (y−0.5)/2)。对照的是这个公式，不是 ffmpeg 或 Apple 转换器的输出。
   - **送进模型前的缩放**：双线性，`align_corners=False`，不做抗锯齿（与上游训练一致）。
   - **每镜头 LUT** = `clamp(mean(每帧 AiLUT 在均匀 N³ 格点上的取值), 0, 1)`；预览、导出视频、`.cube` 三者用同一份截断后的 LUT。
   - **8-bit 量化**：`clamp(x,0,1)·255` 后四舍六入五成双（PyTorch `round` / Metal `rint`）。
   - **强度** s∈[0,1]：最终 LUT = `s·shotLUT + (1−s)·identity`（这个写法使 s=1、s=0 在浮点下也严格等于两端；`identity + s·(…)` 做不到），恒等格点值与 `linspace01` 相同。s=0 即原片（三线性对恒等 LUT 精确）。导出视频、`.cube`、预览都用这份最终 LUT。
   - **切点编辑**：每镜头保存未截断的累加和与帧数。删切点 = 累加和相加（精确，不重新分析）；加切点 = 只重新分析被拆的镜头。

## 目录约定

| 目录 | 放什么 | 规则 |
|---|---|---|
| `Core/` | `AutoGradeCore` 框架：VideoIO / ShotDetector / Grader / LUT / CubeWriter | 产品逻辑只在这里 |
| `Core/Shaders/` | `.metal` 源码（含 App 预览分屏合成用的 `Display.metal`） | 由 `Tools/build-metallib.sh` 编译，**不交给 Xcode 编译**；App 不另建 metallib |
| `CLI/` | `autograde` 命令行 | 只做参数解析和输出，逻辑在 Core |
| `App/` | SwiftUI 应用 target `AutoGrade` | 子目录：`Model/`（唯一的 `@Observable @MainActor` 状态）、`Service/`（actor，独占引擎）、`Canvas/`、`Panels/`、`Windows/`、`Localization/` |
| `App/Localization/Strings.swift` | 全部界面文案（English / 简体中文） | 界面里不得出现裸字符串；语言运行时切换，不重启。不复制 SpektraLab 代码（GPL-3.0，本项目许可未定） |
| `Tests/` | XCTest（Core） | 对照测试 + 端到端测试 |
| `AppTests/` | XCTest（App 的可测部分） | 目前是语言逻辑；测试自带 UserDefaults suite，不读真实设置 |
| `Resources/Models/` | 转好的 `.mlpackage`、上游 LICENSE | 只能由 `research/convert_coreml.py` 生成 |
| `research/` | Python：独立 `.venv`、转换、对照、训练 | 唯一允许 Python 的地方；运行一律 `python -I` |
| `research/third_party/` | 上游 AdaInt，固定 commit `5678851339dff90becb09c3dec41e7214207ccbc` | `research/fetch_upstream.sh` 拉取；不进 git，只读，视为不可信代码 |
| `fixtures/` | 小体积黄金数据（每个文件 < 2 MB，合计 < 20 MB） | 只能由 `research/make_fixtures.py` 生成；进 git |
| `Tools/` | 构建脚本 | |
| `out/` | 一切生成物（视频、LUT、日志、测速） | 不进 git，可随时整个清空 |
| `build/` | xcodebuild 派生数据 | 不进 git |

命名：Swift 类型 `UpperCamelCase`，文件名与主类型同名；Python 文件 `snake_case.py`；生成物带来源素材名前缀，如 `out/gym_1080p_shot00.cube`。

## 构建与测试

```bash
xcodegen generate                                   # 新增/删除任何文件后都要跑
xcodebuild -project AutoGrade.xcodeproj -scheme AutoGradeCore \
           -derivedDataPath build/DerivedData test   # Core 测试
xcodebuild -project AutoGrade.xcodeproj -scheme AutoGradeAppTests \
           -derivedDataPath build/DerivedData test   # App 语言逻辑测试
xcodebuild -project AutoGrade.xcodeproj -scheme autograde \
           -derivedDataPath build/DerivedData build  # 命令行
build/DerivedData/Build/Products/Debug/autograde <in.mp4> -o out/<name>.mov
xcodebuild -project AutoGrade.xcodeproj -scheme AutoGrade \
           -derivedDataPath build/DerivedData build  # 图形界面
open build/DerivedData/Build/Products/Debug/AutoGrade.app
```

测速用 `-configuration Release`（Debug 下 Swift 循环慢一个数量级）。

research 侧：

```bash
research/fetch_upstream.sh                          # 首次
uv venv --python 3.11 research/.venv && uv pip install --python research/.venv/bin/python -r research/requirements.txt
PATH="$PWD/research/.venv/bin:$PATH" research/.venv/bin/python -I research/make_fixtures.py
```

## 精度与对照纪律

- Metal 一律 `-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise`，部署目标 macOS 15。`ProbeTests` 会在快速数学被打开时失败，这是预期行为，不要绕过。
- 三线性插值**手写**，不用硬件 3D 纹理采样（插值权重精度不足）。
- CoreML 对照在 `cpuAndGPU` + fp32 下进行。ANE / fp16 是性能选项，单独测量、单独记录，不放宽对照容差来迁就它。
- 容差表（改动须写明原因）：缩放 ≤1e-5；模型输出 ≤1e-4；AiLUT 应用 8-bit 0 LSB（若为 1 LSB 须写明原因）；65³ 烘焙/平均/应用 8-bit 0 LSB（2026-11-02 实测 0；≤1 的容差放过了 0.1% 的插值权重错误，故收紧）；`.cube` 经 ffmpeg `lut3d` 套用 vs Metal ≤1 LSB（ffmpeg 只在测试里用）。
- 新的回归测试要先看到它失败，再改到通过。
- "0 failures" 不等于测过了：确认测试数量与跳过数量。
- 测速必须附上当时的 `uptime` 和 `ps -Ao %cpu,comm -r | head -5`；这台机器常有 ollama 等负载，交替测量，不要先后各测一次。

## 已知坑（试跑中实测）

- MPS 上 `torch.bincount` 统计一帧 1080p 要 7.5 s；`F.interpolate(mode="area")` 尺寸不整除时不支持。research 脚本里做直方图先缩到 160×90 再转 CPU。
- 视频可能是可变帧率：ffmpeg 解码默认会补重复帧（193 帧变 482 帧）。research 脚本解码必须 `-fps_mode passthrough`；Swift 侧以 AVAssetReader 实际读出的样本为准。
- 后台运行的 ffmpeg 要加 `-nostdin`。
- 颜色直方图切镜阈值 0.5 在低饱和（水墨）画面会漏切；当前默认 0.25。
- `codex exec` 在后台运行必须 `< /dev/null`，否则一直等 stdin（2026-11-02 白等 20 分钟）。
- Codex 的 `workspace-write` 沙箱里 `screencapture` 失败（`could not create image from display`）；界面实操验收需要主人逐次批准 `danger-full-access`。
- 预览显示 vs QuickTime（gym 第 101 帧画面中心 20%，整屏截图，均为 Display P3）：CAMetalLayer+`itur_709` 与 BGRA 送显示层都是 (128.3, 98.7, 61.3)；改为 420v 同标签同色彩空间后 **(126.0, 93.9, 52.0)**，QuickTime (126.4, 93.7, 52.2)，差 ≤0.4 级（2026-11-02）。主人定以 QuickTime 为准 → 架构原则 5。
- 离线预测 QuickTime 显示值：`out/colour/predict.swift`（解码器 YUV → CoreImage → 截图的色彩配置），与 QuickTime 实拍截图差 ≤0.1 级；可在不开界面时先判断改动方向。
- 多屏环境：QuickTime 打开时回到它上次的窗口位置，不跟随前台应用所在的屏；跨屏挪窗口会让辅助功能找不到窗口。截图用 `screencapture f1 f2 f3` 一次截所有屏再挑；截图统一存为 Display P3，跨屏数值可比。

## 界面实操验收的安全规则（2026-11-02 事故后定）

2026-11-02 子 agent 用 System Events 发键盘事件时，Claude 桌面端抢到前台，路径文字和回车落进了主人正在输入的另一个会话，发出了一条混杂消息。因此：

- **只在主人确认"现在不用电脑"后才做界面实操**；每次都要主人当场同意，不沿用上一次的批准。
- **禁止向"当前前台应用"发键盘事件**（`keystroke` / `key code`）。只用针对目标进程的辅助功能动作（`click button` / `click menu item` / `AXPress` / 设置 `AXValue`）。
- 打开文件用 `open -a <App> <file>`，不走打开面板。
- 任何一步前先确认前台进程是目标应用；不是就停下并报告，不重试。
- 脚本一次只做一个动作，不批量串联回车等确认类按键。
- 发现输入落到别的应用：立即停止，如实报告，不去撤回或补救那个应用里的内容。

## 起点基准（试跑数字，阶段 2 要复现）

| 项 | 数值 |
|---|---|
| MPS 改写 vs 官方 CPU 算子（a4739.jpg, 3008×2000） | 8-bit 0 LSB |
| 切镜 `gym_1080p.mp4` / `comic_multishot.mp4`（阈值 0.25） | 3 段 [0–45, 46–143, 144–192] / 6 段 [0–31, 32–76, 77–140, 141–204, 205–293, 294–360] |
| 65³ 烘焙 vs 原始 AiLUT（gym） | 最大 3 LSB |
| 帧间闪烁最大值 逐帧 → 每镜头（comic） | 7.8 → 2.9 级 |
| MPS 单帧（负载 18–21 下） | 1080p 10 ms，4K 33 ms |

## 许可与素材

- AdaInt 代码 Apache-2.0。FiveK 训练出的权重**可能仅限研究用途，未核实**；在核实前项目不公开发布、不分发权重。
- 测试视频是即梦生成内容，整段视频不进 git，只把抽出的少量帧缩小后放进 `fixtures/`。

## 红线（必须先问主人）

- 删除文件、目录或 git 历史（`out/`、`build/` 的生成物除外）
- 修改 `.env`、密钥、token、CI/CD 配置
- git push、git rebase、git reset --hard、强制推送；建远程仓库
- 安装全局依赖或修改系统配置（`research/.venv` 内的包不算）
- 公开发布

## 分工

- 代码与本规则文件：Claude 直接做。
- README 等长文档：交给 Codex `gpt-6.1-terra`（xhigh）写，Claude 核对后再交付。
