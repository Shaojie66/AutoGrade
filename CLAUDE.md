# CLAUDE.md —— AutoGrade 规则

macOS 原生 AI 视频自动调色。本文件是**规则的唯一来源**；`AGENTS.md` 只指向这里。
要改规则，先改这里，再改代码。

## 这个项目是什么

视频进 → 按镜头切分 → 每个镜头由模型（AdaInt, CVPR 2022）生成一个 3D LUT → 套用并导出视频，同时导出每镜头 `.cube`。

- 来历：`~/camera/experiments/adaint/` 的试跑（2026-11-02）。那里的数字是本项目的起点基准，见文末。
- 内置权重：AdaInt **FiveK sRGB**（风格 id `fivek`）。它学的是"把照片修正常"，不是电影感风格。
- 胶片风格（Velvia 50、Ektachrome 100 VS 等）是本机安装的额外模型，不随仓库和 App 分发，见"风格模型"。

## 架构原则

1. **一个进程，运行时没有 Python。** Swift + Metal + CoreML + AVFoundation。Python 只存在于 `research/`，用于模型转换、生成对照数据、将来训练。产品代码不得调用、依赖或打包任何 Python 与 ffmpeg。
2. **对照先于功能。** 每个数值环节（缩放、模型、AiLUT 应用、烘焙、平均、`.cube`）都有黄金数据和 XCTest 对照。基准是**上游官方 C++ CPU 算子**（`research/oracle/`），不是我们自己的 PyTorch 改写。
3. **两遍处理。** 第一遍分析（预测 LUT、切镜、每镜头平均），第二遍渲染。预览和导出读同一份分析结果。
5. **预览像素 = 导出编码前像素；预览显示 = QuickTime 显示。** App 预览与导出走同一组 Metal 算子、同一份每镜头最终 LUT（含强度）；`testPreviewIsByteIdenticalToExport` 逐字节锁定。App 不得有自己的调色或颜色转换代码路径。导出后自检（见"导出"）重新调来源帧时也走同一个 `encodeGradeFrame`。
   上屏走 AVFoundation 的视频显示路径（`AVSampleBufferDisplayLayer`），送入的是和解码器输出**同格式同标签**的帧：8-bit 4:2:0 BT.709 limited（'420v'），带原色/传递函数/矩阵、色度位置 Left 和 `kCVImageBufferCGColorSpaceKey`（由这些标签推导出的 CoreMedia709）。RGB→YUV 用架构原则 4 的同一矩阵；色度取偶数列、上下两行平均（与解码约定的采样位置对应）。**不自己挑 CGColorSpace 或 gamma 去凑**。2026-11-02 实测：CAMetalLayer+`itur_709` 和 BGRA 送显示层都比 QuickTime 亮（同屏整屏截图中心 (128.3, 98.7, 61.3) vs (126.4, 93.7, 52.2)），而导出文件本身无偏（`ExportRoundTripTests`），差在 RGB 上屏这一步。对比分屏由 `Display.metal` 逐像素选源，不重采样。
6. **App 只做界面。** 数值逻辑（切点合并/拆分、强度、取消）都在 Core 并有测试；`App/` 里只有状态、视图和调度。
4. **颜色约定显式写出，不靠默认值。** 视频按 display-referred 处理（FiveK sRGB 权重的输入假设）。改动任一约定都要同时更新对照数据（`research/make_fixtures.py` 是这些约定的可执行定义）：
   - **YUV→RGB**：只接受 8-bit 4:2:0 BT.709 limited range（其他输入报错，不猜）。`Y'=(Y−16)/219`，`Cb'=(Cb−128)/224`，`Cr'=(Cr−128)/224`；`R=Y'+1.5748Cr'`，`G=Y'−0.187324Cb'−0.468124Cr'`，`B=Y'+1.8556Cb'`，截断到 [0,1]。色度双线性上采样，边缘钳位，采样位置 MPEG-2/H.264 默认：亮度 (x,y) 读色度平面连续坐标 (x/2, (y−0.5)/2)。对照的是这个公式，不是 ffmpeg 或 Apple 转换器的输出。
   - **送进模型前的缩放**：双线性，`align_corners=False`，不做抗锯齿（与上游训练一致）。
   - **每镜头 LUT** = `clamp(mean(每帧 AiLUT 在均匀 N³ 格点上的取值), 0, 1)`；预览、导出视频、`.cube` 三者用同一份截断后的 LUT。
   - **8-bit 量化**：`clamp(x,0,1)·255` 后四舍六入五成双（PyTorch `round` / Metal `rint`）。
   - **强度** s∈[0,1]：最终 LUT = `s·shotLUT + (1−s)·identity`（这个写法使 s=1、s=0 在浮点下也严格等于两端；`identity + s·(…)` 做不到），恒等格点值与 `linspace01` 相同。s=0 即原片（三线性对恒等 LUT 精确）。导出视频、`.cube`、预览都用这份最终 LUT。
   - **切点编辑**：每镜头保存未截断的累加和与帧数。删切点 = 累加和相加（精确，不重新分析）；加切点 = 只重新分析被拆的镜头。
   - **风格**：每个镜头有一个风格 id，累加和只在同一风格内相加。换一个镜头的风格 = 只重新分析该镜头；换全部 = 整段重新分析一遍，**保留当前切点**，不重新切镜。加切点时两半继承原风格。删切点时，若两镜头风格相同则累加和直接相加；若不同，合并后的镜头用前一个的风格，后一段先用该风格重新分析再相加（与"合并后沿用前一个镜头的强度"一致）。

## 导出

- **音轨原样复制**：复制来源的第一条音轨，压缩包逐包写入、不重新编码、时间戳不变；音轨比视频长也整条保留，不裁剪。来源有多条音轨时警告；音轨无法原样写进 `.mov` 时跳过并警告，不让导出失败。CLI `--no-audio` / App 导出面板“保留原音轨”可关闭。
  - AAC 开头的编码器垫包：AVAssetReader 按来源的剪辑表跳过垫包，AVAssetWriter 再用自己的方式重建（复制第一个包），所以垫了多个包的来源（主人的 gym：来源 2 个垫包，成片 347 包 vs 346）**压缩字节不会完全相同**。2026-11-03 实测：苹果自己的直通导出（`AVAssetExportPresetPassthrough`）与我们的输出逐字节相同；苹果解码器解出的波形与来源逐点一致（最大差 1.5e-7），仅结尾短 34 个采样；ffmpeg 解码则开头 46 ms 不同、结尾短 46 ms（它对苹果垫包写法的理解不同）。以苹果解码（QuickTime 播放）为准。
- **导出后自检**（`Core/ExportCheck.swift`，借鉴 OpenMontage 的渲染后自检思路，不抄其 AGPL 代码）：每次导出后自动核对成片——视频样本时间戳与分析的 `frameTimes` 逐个相等；宽高、编码与 BT.709 三项颜色标签；音轨应有则有，用苹果解码器把来源与成片解成波形逐点比较（容差见容差表），应无则无；每个镜头中间帧抽查（最多 12 帧），成片解码结果与用同一份最终 LUT 重新调色的来源帧比较，阈值见容差表。
- 2026-11-03 主人 5 段素材实测（Release，负载 8–12）：7 次导出（HEVC 5 次、ProRes 2 次）自检全部通过；画面抽查平均误差 HEVC 0.42–1.42 级、ProRes 0.81–2.27 级；音频解码后最大差 ≤5.4e-7，长度差 0–34 个采样；自检耗时占整次导出 9–12%（伊斯坦布尔 4K：1.48 s / 12.5 s）。
- 自检不通过：**保留文件**，不自动删除；CLI 打印失败项并以退出码 1 结束，App 提示“导出完成，但自检未通过”并列出失败项。

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
| `research/third_party/rawtherapee-film/` | RawTherapee Film Simulation Collection（2015-09-20，HaldCLUT PNG；Pat David、Pavlov Dmitry、Michael Ezra，**CC BY-SA 4.0**） | 从官方 `rawtherapee.com/shared/HaldCLUT.zip` 下载；不进 git，只读。用它生成的训练数据和权重要按 CC BY-SA 4.0 署名并相同方式共享，与 FiveK 的仅限研究同时成立（2026-11-02 主人知情后决定使用） |
| `research/train/` | 风格训练代码：HaldCLUT 读取、数据集与增强、训练、评估 | 进 git；运行一律 `python -I` |
| `research/data/` | 训练输入 | 不进 git；只读使用；记录来源与清单 sha256 |
| `research/data/fivek-dng/` | FiveK 原始 DNG 子集：**只从 MIT 官网** `data.csail.mit.edu/graphics/fivek/img/dng/` 逐个下载，**不用任何镜像**（主人 2026-11-02 决定；Google Drive / OneDrive 的 480p 版均已 404） | `selection.json` 记录选取规则（上游 train/test 清单内固定种子抽样）、文件名、大小、sha256 |
| `research/data/fivek-srgb480/` | 由上面 DNG 渲染的 8-bit sRGB PNG，短边 480 | 只能由 `research/train/render_dng.swift` 生成（macOS Core Image RAW，按相机白平衡与曝光，不做任何调色） |
| `research/runs/<run>/` | 每次训练的配置、日志、checkpoint、报告、转换出的 `.mlpackage` | 不进 git；**训练权重不提交、不推送**（同时受 FiveK 仅限研究与 CC BY-SA 4.0 约束，发布方式待主人决定）；可随时清空重跑 |
| `fixtures/` | 小体积黄金数据（每个文件 < 2 MB，合计 < 20 MB） | 只能由 `research/make_fixtures.py` 生成；进 git |
| `Tools/` | 构建脚本；`install-style.sh` 把 `research/runs/<run>/` 的风格模型编译后装进本机风格目录 | |
| `~/Library/Application Support/AutoGrade/Styles/`（仓库外） | 本机安装的风格模型 `<id>.mlmodelc`，旁边的 `<id>.reference/` 存放 PyTorch 对照数据 | 只能由 `Tools/install-style.sh` 写入；文件名就是风格 id，`fivek` 保留给内置模型；显示名和许可写在模型元数据里（`convert_coreml.py --name-en/--name-zh`）。App 和 CLI 只读、不写；目录不存在时只有 FiveK |
| `licenses/` | 第三方许可原文（FiveK 两份）与对照说明 | 随仓库分发；新增第三方素材或权重时同步更新 |
| `docs/images/` | README 用的真实截图 | 只截 App 窗口，不含桌面或其他应用；写明来源（如界面验收的哪一张）；JPEG ≤ 300 KB |
| `README.md` / `README_EN.md` | 中文主 README 与英文版 | 两份顶部互链并带同一 `README_SYNC` 标记；改一份必须同步另一份，改完跑 qiangshou 的 `validate_readme_pair.py` |
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
- 容差表（改动须写明原因）：导出自检画面抽查：平均误差 ≤4 级、每通道平均偏差 ≤3 级（2026-11-03 实测：正常导出最差 2.40 / 1.27（合成图 ProRes），主人素材最差 2.27 / 0.87；一个镜头漏调色 12.1 / −12.4）；导出自检音轨：解码波形逐点 ≤1e-6，长度差 ≤1 个压缩包（AAC 1024 采样；PCM 0）——比较压缩字节会把正常的 AAC 垫包重建误判为失败（见"导出"）；缩放 ≤1e-5；模型输出 ≤1e-4；AiLUT 应用 8-bit 0 LSB（若为 1 LSB 须写明原因）；65³ 烘焙/平均/应用 8-bit 0 LSB（2026-11-02 实测 0；≤1 的容差放过了 0.1% 的插值权重错误，故收紧）；`.cube` 经 ffmpeg `lut3d` 套用 vs Metal ≤1 LSB（ffmpeg 只在测试里用）。
- 新的回归测试要先看到它失败，再改到通过。
- "0 failures" 不等于测过了：确认测试数量与跳过数量。
- 测速必须附上当时的 `uptime` 和 `ps -Ao %cpu,comm -r | head -5`；这台机器常有 ollama 等负载，交替测量，不要先后各测一次。

## 已知坑（试跑中实测）

- MPS 上 `torch.bincount` 统计一帧 1080p 要 7.5 s；`F.interpolate(mode="area")` 尺寸不整除时不支持。research 脚本里做直方图先缩到 160×90 再转 CPU。
- 视频可能是可变帧率：ffmpeg 解码默认会补重复帧（193 帧变 482 帧）。research 脚本解码必须 `-fps_mode passthrough`；Swift 侧以 AVAssetReader 实际读出的样本为准。
- 后台运行的 ffmpeg 要加 `-nostdin`。
- 颜色直方图切镜阈值 0.5 在低饱和（水墨）画面会漏切；当前默认 0.25。
- 反过来，单镜头里大块物体经过也会被误切（2026-11-02 主人的车窗街景 `sd1793455645_2.mov`：公交车进出画面，0.25 阈值切出 14 段，其中 10 段只有 1–2 帧；实际是 1 个连续镜头，`--cut 3` 即不切）。单帧镜头会让 LUT 闪一下；待改进：最短镜头长度或切点前后多帧确认。
- AVAssetWriter 音视频交错（2026-11-03）：只补“不晚于当前视频帧”的音频会让两个输入互相等待而卡死；写入器会让音频领先视频约 7 秒。现在的做法是写入器肯收就写（`AudioPassthrough.pump`），视频写完后再 `drain`，任一输入 10 秒写不进去就报错，不无限等待。`synthetic_av.mp4` 的音频比视频长 7 秒，正是为了让 `drain` 真正被测到。
- `codex exec` 在后台运行必须 `< /dev/null`，否则一直等 stdin（2026-11-02 白等 20 分钟）。
- Codex 的 `workspace-write` 沙箱里 `screencapture` 失败（`could not create image from display`）；界面实操验收需要主人逐次批准 `danger-full-access`。
- 预览显示 vs QuickTime（gym 第 101 帧画面中心 20%，整屏截图，均为 Display P3）：CAMetalLayer+`itur_709` 与 BGRA 送显示层都是 (128.3, 98.7, 61.3)；改为 420v 同标签同色彩空间后 **(126.0, 93.9, 52.0)**，QuickTime (126.4, 93.7, 52.2)，差 ≤0.4 级（2026-11-02）。主人定以 QuickTime 为准 → 架构原则 5。
- 离线预测 QuickTime 显示值：`out/colour/predict.swift`（解码器 YUV → CoreImage → 截图的色彩配置），与 QuickTime 实拍截图差 ≤0.1 级；可在不开界面时先判断改动方向。
- 多屏环境：QuickTime 打开时回到它上次的窗口位置，不跟随前台应用所在的屏；跨屏挪窗口会让辅助功能找不到窗口。截图用 `screencapture f1 f2 f3` 一次截所有屏再挑；截图统一存为 Display P3，跨屏数值可比。

## 风格模型

- 训练出的风格模型同时受 FiveK（仅限研究、非商用）和 CC BY-SA 4.0 约束：**只在本机安装使用，不进 git、不推送、不打进 App**。别人 clone 后构建出的 App 只有 FiveK，功能完整。
- 安装：`research/convert_coreml.py --checkpoint … --out … --name-en … --name-zh …`（同时写出 `reference/`），然后 `Tools/install-style.sh <run>/<Name>.mlpackage <id>`。
- 对照：`StyleParityTests` 对每个已安装且带 `reference/` 的风格，在 Swift 路径下与 PyTorch 对照，容差 ≤1e-4（与 FiveK 相同）。没有安装时会跳过；汇报时写明跑了几个、跳过几个。
- 导出的 `.cube` 标题行写明风格名和许可简写。
- 界面验收（2026-11-03，Terra 第三轮，comic 6 镜头）：单镜头换 Velvia、工具栏全部换 Ektachrome、默认风格写入 / 恢复 `fivek`、英文文案与设置页均通过。**取消未在界面里验到**：361 帧整段换风格约 3 秒完成，来不及按；取消由 `testCancelledRestyleLeavesTheAnalysisAsItWas` 在 Core 覆盖，“取消后不记住默认风格”（`Project.setStyleForAll`）尚无界面验证，下次界面验收用 `gym_4k.mp4` 补。
- 2026-11-03 实测（Release CLI，负载 42，ollama 在跑）：gym 1080p 整段分析 FiveK 与 Velvia 50 都约 9 ms/帧，换风格不变慢；换一个镜头的风格耗时 ≈ 该镜头帧数 × 9 ms。伊斯坦布尔 4K（`--cut 3`，1 个镜头）第 250 帧天空亮度：原片 170.3 / FiveK 186.4 / Velvia 50 163.7 / Ektachrome 100 VS 162.5，与训练评估（163.4 / 162.4）一致。

## 风格训练

- **日落候选 LUT**（RawTherapee 胶片合集，2026-11-02 在伊斯坦布尔日落第 250 帧实测：相对原片的天空亮度 / 晚霞亮度 / 晚霞饱和度）：
  - **Fuji Velvia 50**（`Color/Fuji/Fuji Velvia 50.png`）：−8 / −23 / +17 —— 首选，先训这个
  - **Kodak Ektachrome 100 VS**（`Color/Kodak/Kodak Ektachrome 100 VS.png`）：−8 / −23 / +17 —— 第二个
  - **Fuji Provia 100F**（`Color/Fuji/Fuji Provia 100F.png`）：−1 / −11 / +11 —— 温和备选
  - 不适合日落：Portra 400（+19，像 FiveK 一样提亮）、Ektar 100（变淡）、Kodachrome 64（偏洋红）、LateSunset / TealOrange（风格化过重）。对照：FiveK 为 +16 / +7 / +31。
- 训练目标是固定 LUT 时，模型最多逼近"直接套 LUT"（主人已知并接受）。
- **velvia50_v1**（2026-11-03，`research/runs/velvia50_v1/`，权重不进 git）：FiveK 官网 DNG 子集 800 训练 / 200 测试，从 FiveK 权重微调 45,000 步，MPS 用时 92 分钟（开始时负载 44、结束时 4）。200 张测试图上模型 vs Velvia 目标：**PSNR 50.8 dB、平均误差 0.57 级、p99 2.4 级**（起点 FiveK 权重 18.9 dB / 26.7 级）。主人视频帧：伊斯坦布尔日落平均 0.5–0.6 级，天空亮度跟随 Velvia（170.3 → 目标 163.0 / 模型 163.4，FiveK 181.7）；车窗街景 p99 12.5 级（过曝天空处）。CoreML vs PyTorch 3.0e-7。验收第 1–5 条通过。
- **ektachrome100vs_v1**（2026-11-03，同一数据与超参）：用时 87 分钟（开始负载 10.7）。200 张测试图：**PSNR 46.5 dB、平均 0.90 级、p99 4.4 级**（起点 19.3 dB / 25.2 级）。伊斯坦布尔日落平均 0.6–0.9 级，天空 170.3 → 目标 163.2 / 模型 162.4；车窗街景 p99 25.7 级（过曝天空处，两款里最差）。CoreML vs PyTorch 2.4e-7。验收第 6 条通过。比 Velvia 难学一些（验证曲线在 45–48 dB 间波动）。

## 界面实操验收的安全规则（2026-11-02 事故后定）

2026-11-02 子 agent 用 System Events 发键盘事件时，Claude 桌面端抢到前台，路径文字和回车落进了主人正在输入的另一个会话，发出了一条混杂消息。因此：

- **优先在 MacBook Air 上做**（2026-11-03 主人决定）：Pro 是主人正在用的机器，键盘焦点会被抢（2026-11-03 Terra 两次因前台变成 `Electron` 中止）。做法：Release 版 `AutoGrade.app` 与测试视频复制到 Air 的 `~/AutoGradeTest/`，Terra 留在 Pro 上，通过 `ssh air` 用 `osascript` / `screencapture` 操作 Air，截图与导出文件拷回 Pro 的 `out/ui/` 再核对。Air 上 `sshd-keygen-wrapper` 需要“辅助功能”和“屏幕录制”权限（主人 2026-11-03 开启，测完提醒主人可以关掉）。Air 平时是 Pro 的第三块屏（`AirDisplayReceiver`），实操结束后把它切回前台。风格模型不复制到 Air（训练权重只在 Pro 本机使用），需要胶片风格的实操仍在 Pro 上做。
- 在 Air 上做：主人同意这次实操、批准 `danger-full-access` 即可，不要求主人离开 Pro。**在 Pro 上做：只在主人确认"现在不用电脑"后才做**；两种情况都是每次当场同意，不沿用上一次的批准。
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

- **本项目代码：PolyForm Noncommercial 1.0.0**（`LICENSE`，官方原文不改，首行 `Required Notice:`；2026-11-02 主人决定，与 FiveK 的非商业限制一致）。README 口径写 source-available / 源码公开、非商业免费、商用需另行授权，**不得称 Open Source**。
- AdaInt 代码 Apache-2.0（`Resources/Models/AdaInt-LICENSE.txt`）。从 AdaInt 移植的部分（`research/oracle/ailut.py` 模型与算子封装、`Grade.metal` 的 AiLUT/LUT 算子）仍属 Apache-2.0，文件头注明来源与改动；新增移植代码照此办理。
- MIT-Adobe FiveK 两份许可（2026-11-02 从官网 `legal/` 核实，原文在 `licenses/`）：**只能为自己的研究使用，不得以商业利益或报酬为目的**；分发图片副本须附版权声明和许可全文；不得用 Adobe/MIT 名义背书。许可只讲图片，没讲训练出的权重；本项目**按"仅限研究、不得商用"对待权重**。
- `fixtures/demo_*` 来自 FiveK 图片 `a4739`（属 `LicenseAdobeMIT`），所以 `licenses/FiveK-LicenseAdobeMIT.txt` 必须随仓库一起分发。
- 远程仓库 `github.com/Shaojie66/AutoGrade`：2026-11-02 主人决定**公开**（在核实 FiveK 许可之后）。公开只为研究、非商用；任何商用、或把权重/FiveK 内容用于收费产品前先问主人。
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
