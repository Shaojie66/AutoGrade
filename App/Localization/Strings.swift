import Foundation

/// Every string the interface shows (CLAUDE.md: no bare strings in views).
/// Technical identifiers (HEVC, ProRes, .cube, fps) stay as they are in both.
enum S {
    // app & menus
    static let appName = Copy(en: "AutoGrade", zh: "AutoGrade")
    static let open = Copy(en: "Open Video…", zh: "打开视频…")
    static let reanalyze = Copy(en: "Analyze Again", zh: "重新分析")
    static let export = Copy(en: "Export…", zh: "导出…")
    static let playback = Copy(en: "Playback", zh: "播放")
    static let play = Copy(en: "Play", zh: "播放")
    static let pause = Copy(en: "Pause", zh: "暂停")
    static let previousFrame = Copy(en: "Previous Frame", zh: "上一帧")
    static let nextFrame = Copy(en: "Next Frame", zh: "下一帧")
    static let shots = Copy(en: "Shots", zh: "镜头")
    static let addCut = Copy(en: "Add Cut Here", zh: "在此添加切点")
    static let removeCut = Copy(en: "Merge with Previous Shot", zh: "合并到上一个镜头")

    // empty state
    static let emptyTitle = Copy(en: "Automatically grade a video shot by shot", zh: "打开视频，自动逐镜头调色")
    static let emptyHint = Copy(en: "Or drop a video here. Supports 8-bit H.264/HEVC in BT.709 (limited or full range).",
                                zh: "也可以将视频拖到这里。支持 BT.709 色彩空间的 8-bit H.264/HEVC 视频（窄范围或全范围）。")

    // analysis
    static let analyzing = Copy(en: "Analyzing", zh: "正在分析")
    static let cancel = Copy(en: "Cancel", zh: "取消")
    static let openFailed = Copy(en: "This video can’t be opened", zh: "无法打开这段视频")
    static let editing = Copy(en: "Reanalyzing shot", zh: "正在重新分析镜头")
    static let ok = Copy(en: "OK", zh: "好")

    // shot list
    static func shot(_ n: Int) -> Copy { Copy(en: "Shot \(n)", zh: "镜头 \(n)") }
    static func frames(_ a: Int, _ b: Int) -> Copy { Copy(en: "Frames \(a)–\(b)", zh: "帧 \(a)–\(b)") }
    static func seconds(_ s: Double) -> Copy {
        let t = String(format: "%.1f", s)
        return Copy(en: "\(t) s", zh: "\(t) 秒")
    }
    static let strength = Copy(en: "Strength", zh: "强度")

    // styles
    static let style = Copy(en: "Style", zh: "风格")
    static let styleFiveK = Copy(en: "FiveK (natural)", zh: "FiveK（自然）")
    static let applyToAllShots = Copy(en: "Apply to All Shots", zh: "应用到所有镜头")
    static let restyling = Copy(en: "Applying style", zh: "正在应用风格")
    static let styleFailed = Copy(en: "Couldn’t apply the style", zh: "无法应用风格")
    static let styleMissingTitle = Copy(en: "Style not installed", zh: "风格未安装")
    static func styleMissingBody(_ id: String) -> Copy {
        Copy(en: "The default style “\(id)” is no longer on this Mac. Videos open in FiveK instead.",
             zh: "默认风格“\(id)”已不在这台 Mac 上，视频将改用 FiveK 打开。")
    }
    static let styles = Copy(en: "Styles", zh: "风格")
    static let showStylesFolder = Copy(en: "Show Styles Folder", zh: "在访达中显示风格文件夹")
    static let stylesNote = Copy(
        en: "Film styles are installed on this Mac only and are not distributed. FiveK weights: research use only, non-commercial; film styles are also under CC BY-SA 4.0.",
        zh: "胶片风格只安装在这台 Mac 上，不对外分发。FiveK 权重仅限研究、不得商用；胶片风格另受 CC BY-SA 4.0 约束。")

    // subtitles
    static let subtitlesMenu = Copy(en: "Subtitles", zh: "字幕")
    static let generateSubtitles = Copy(en: "Generate Subtitles", zh: "生成字幕")
    static let importSRT = Copy(en: "Import SRT…", zh: "导入 SRT…")
    static let showSubtitles = Copy(en: "Show Subtitles", zh: "显示字幕")
    static let clearSubtitles = Copy(en: "Clear Subtitles", zh: "清除字幕")
    static let recognising = Copy(en: "Recognising speech", zh: "正在识别语音")
    static let downloadingModel = Copy(en: "Downloading the speech model", zh: "正在下载语音模型")
    static let subtitlesFailed = Copy(en: "Couldn’t make subtitles", zh: "无法生成字幕")
    static let subtitlesImported = Copy(en: "Subtitles imported with warnings", zh: "字幕已导入，但有警告")
    static let speechModelTitle = Copy(en: "Download the speech model?", zh: "下载语音模型？")
    static func speechModelBody(_ language: String, _ why: String) -> Copy {
        Copy(en: "Recognition failed (\(why)). If the \(language) speech model is not on this Mac yet, it can be downloaded from Apple. The system manages it, other apps can share it, and recognition then works offline.",
             zh: "识别失败（\(why)）。如果这台 Mac 上还没有“\(language)”的语音模型，可以从 Apple 下载。模型由系统管理、可与其他应用共用，下载后可离线识别。")
    }
    static let download = Copy(en: "Download", zh: "下载")
    static let noSubtitles = Copy(en: "No subtitles yet. Generate them or import an SRT from the Subtitles menu.",
                                  zh: "还没有字幕。可在“字幕”菜单里生成，或导入 SRT。")
    static let deleteCue = Copy(en: "Delete", zh: "删除")
    static let sidebarShots = Copy(en: "Shots", zh: "镜头")
    static let sidebarSubtitles = Copy(en: "Subtitles", zh: "字幕")

    // covers (CLAUDE.md 封面)
    static let sidebarCovers = Copy(en: "Covers", zh: "封面")
    static let findCovers = Copy(en: "Find Cover Frames", zh: "挑选封面帧")
    static let coversHint = Copy(en: "Picks each shot’s sharpest, best-exposed frame, preferring faces and still moments. Covers are graded like the export, without subtitles.",
                                 zh: "从每个镜头里挑出最清晰、曝光最好的一帧，优先有人脸、画面稳定的时刻。封面调色与导出一致，不带字幕。")
    static let findingCovers = Copy(en: "Finding cover frames", zh: "正在挑选封面帧")
    static let coversFailed = Copy(en: "Couldn’t make the covers", zh: "无法生成封面")
    /// Shot and frame numbers count from 1, as in the shot list and the transport.
    static func coverRow(rank: Int, shot: Int) -> Copy {
        Copy(en: "#\(rank) · Shot \(shot)", zh: "第 \(rank) 名 · 镜头 \(shot)")
    }
    static func coverDetail(frame: Int, score: Double) -> Copy {
        let t = String(format: "%.2f", score)
        return Copy(en: "Frame \(frame) · Score \(t)", zh: "第 \(frame) 帧 · 得分 \(t)")
    }
    static func coverPreviewLabel(_ w: Int, _ h: Int) -> Copy {
        Copy(en: "Cover preview, \(w)×\(h)", zh: "封面预览，\(w)×\(h)")
    }
    static func coverPreviewSize(_ w: Int, _ h: Int) -> Copy {
        Copy(en: "\(w)×\(h) — the exported pixels", zh: "\(w)×\(h)，即导出的像素")
    }
    static let coverShortShots = Copy(en: "Shots shorter than 1 s are not considered.", zh: "短于 1 秒的镜头不参加评选。")
    static let coverInclude = Copy(en: "Export this cover", zh: "导出这张封面")
    static let coverShapes = Copy(en: "Shapes", zh: "画幅")
    static let coverOriginal = Copy(en: "Original", zh: "原画幅")
    static let coverFormat = Copy(en: "Format", zh: "格式")
    static let coverPreviewTitle = Copy(en: "Preview shape", zh: "预览画幅")
    static let coverSelectHint = Copy(en: "Select a frame to preview its cover in the main view.", zh: "选中一帧，主画面显示封面预览。")
    static let exportCoversButton = Copy(en: "Export Covers…", zh: "导出封面…")
    static let chooseCoverFolder = Copy(en: "Choose a folder for the covers", zh: "选择存放封面的文件夹")
    static let exportingCovers = Copy(en: "Exporting covers", zh: "正在导出封面")
    static let replaceCoversTitle = Copy(en: "Replace existing covers?", zh: "替换已有的封面？")
    static func replaceCoversBody(_ n: Int) -> Copy {
        Copy(en: "\(n) file(s) with the same names are already in this folder.", zh: "这个文件夹里已有 \(n) 个同名文件。")
    }
    static let coversExported = Copy(en: "Covers exported", zh: "封面已导出")
    static let coversCheckFailed = Copy(en: "Covers exported, but a check failed", zh: "封面已导出，但自检未通过")
    static func coversSummary(_ path: String, count: Int, failures: [String]) -> Copy {
        let notes = failures.map { "\n• \($0)" }.joined()
        return Copy(en: "\(path)\n\n\(count) file(s) written and read back.\(notes)",
                    zh: "\(path)\n\n已写入 \(count) 个文件，并逐一读回核对。\(notes)")
    }
    static let exportSRT = Copy(en: "Also write an SRT file", zh: "同时导出 SRT 文件")
    static let burnSubtitlesOption = Copy(en: "Burn subtitles into the picture", zh: "把字幕烧录进画面")
    static func replaceSRTTitle(_ name: String) -> Copy { Copy(en: "Replace \(name)?", zh: "替换 \(name)？") }
    static let subtitlesNeedMac26 = Copy(en: "Recognising speech needs macOS 26 or later. You can still import an SRT.",
                                         zh: "识别语音需要 macOS 26 或更高版本，仍可导入 SRT。")

    // enhancement (CLAUDE.md 画质增强)
    static let enhanceMenu = Copy(en: "Picture", zh: "画质")
    static let denoise = Copy(en: "Noise Reduction", zh: "降噪")
    static let off = Copy(en: "Off", zh: "关")
    static let denoiseStandard = Copy(en: "Standard", zh: "标准")
    static let denoiseStrong = Copy(en: "Strong", zh: "强")
    static let denoiseNeedsMac26 = Copy(en: "Noise reduction needs macOS 26", zh: "降噪需要 macOS 26")
    static let denoisePreviewNote = Copy(en: "Preview is close; the export is exact", zh: "预览为近似效果，导出精确")
    static let background = Copy(en: "Background", zh: "背景")
    static let backgroundNone = Copy(en: "Unchanged", zh: "不处理")
    static let blurLight = Copy(en: "Blur: Light", zh: "虚化：轻")
    static let blurStandard = Copy(en: "Blur: Standard", zh: "虚化：标准")
    static let blurStrong = Copy(en: "Blur: Strong", zh: "虚化：强")
    static let backgroundWhite = Copy(en: "White", zh: "白色")
    static let backgroundBlack = Copy(en: "Black", zh: "黑色")
    static let backgroundGreen = Copy(en: "Green Screen", zh: "绿幕")
    static let backgroundPeopleOnly = Copy(en: "Only people are kept in front", zh: "只保留画面中的人")
    static let findingPeople = Copy(en: "Finding people", zh: "正在识别人物")
    static let enhanceFailed = Copy(en: "Couldn’t change the picture settings", zh: "无法更改画质设置")
    static func noPeopleInShots(_ shots: [Int]) -> Copy {
        let list = shots.map { String($0 + 1) }.joined(separator: ", ")
        return Copy(en: "No one found in shot \(list): background left as it is",
                    zh: "镜头 \(list) 未识别到人物，背景保持原样")
    }
    static func exportEnhance(_ parts: [Copy]) -> Copy {
        Copy(en: "Picture: " + parts.map(\.en).joined(separator: " · "), zh: "画质：" + parts.map(\.zh).joined(separator: " · "))
    }

    // reframe
    static let aspect = Copy(en: "Frame", zh: "画幅")
    static let aspectOriginal = Copy(en: "Original", zh: "原始")
    static let aspectVertical = Copy(en: "Vertical 9:16", zh: "竖屏 9:16")
    static let aspectHorizontal = Copy(en: "Horizontal 16:9", zh: "横屏 16:9")
    static let detectingSubjects = Copy(en: "Finding the subject", zh: "正在识别主体")
    static let reframeFailed = Copy(en: "Couldn’t reframe the video", zh: "无法重构画幅")
    static let compareOutput = Copy(en: "Output", zh: "成片")
    static let cropFixed = Copy(en: "Crop: fixed", zh: "裁切：自动固定")
    static let cropFollow = Copy(en: "Crop: following", zh: "裁切：自动跟随")
    static let cropManual = Copy(en: "Crop: manual", zh: "裁切：手动")
    static let resetCrop = Copy(en: "Automatic", zh: "恢复自动")
    static let cropPosition = Copy(en: "Crop position", zh: "裁切位置")
    static let dragCropHint = Copy(en: "Drag to move this shot’s crop", zh: "拖动可调整本镜头的裁切位置")
    static func exportFrame(_ name: String, _ w: Int, _ h: Int) -> Copy {
        Copy(en: "Frame: \(name) · \(w)×\(h)", zh: "画幅：\(name) · \(w)×\(h)")
    }

    // preview
    static let compareSplit = Copy(en: "Split", zh: "分屏")
    static let compareOriginal = Copy(en: "Original", zh: "原片")
    static let compareGraded = Copy(en: "Graded", zh: "调色")
    static func frameOf(_ i: Int, _ n: Int) -> Copy { Copy(en: "Frame \(i + 1) of \(n)", zh: "第 \(i + 1) 帧，共 \(n) 帧") }
    static func playbackRate(_ fps: Double, _ dropped: Int) -> Copy {
        let f = String(format: "%.1f", fps)
        return Copy(en: "\(f) fps · \(dropped) dropped", zh: "\(f) fps · 丢帧 \(dropped)")
    }

    // export
    static let exportTitle = Copy(en: "Export", zh: "导出")
    static let codec = Copy(en: "Codec", zh: "编码")
    static let alsoCubes = Copy(en: "Export a .cube file for each shot", zh: "为每个镜头导出一个 .cube 文件")
    static let chooseCubeFolder = Copy(en: "Choose a folder for the .cube files", zh: "选择存放 .cube 文件的文件夹")
    static let exporting = Copy(en: "Exporting", zh: "正在导出")
    static let exportDone = Copy(en: "Export finished", zh: "导出完成")
    static let exportFailed = Copy(en: "Export failed", zh: "导出失败")
    static let exportCheckFailed = Copy(en: "Export finished, but the check failed", zh: "导出完成，但自检未通过")
    static let checkingExport = Copy(en: "Checking the export", zh: "正在检查导出文件")
    static let keepAudio = Copy(en: "Keep the original audio", zh: "保留原音轨")
    static let noAudioInSource = Copy(en: "This video has no audio track.", zh: "这段视频没有音轨。")
    /// The export alert: where it went and what the check found. Failures and
    /// warnings are the Core's own diagnostics, shown as they are.
    static func exportSummary(_ path: String, frames: Int, sampled: Int, audioPackets: Int?,
                              failures: [String], warnings: [String]) -> Copy {
        let notes = (warnings + failures).map { "\n• \($0)" }.joined()
        let en = audioPackets.map { "\(frames) frames, audio copied (\($0) packets)" } ?? "\(frames) frames, no audio"
        let zh = audioPackets.map { "\(frames) 帧，已复制音轨（\($0) 个包）" } ?? "\(frames) 帧，无音轨"
        return Copy(en: "\(path)\n\nChecked: \(en); \(sampled) frames compared with their grade.\(notes)",
                    zh: "\(path)\n\n已自检：\(zh)；抽查 \(sampled) 帧，与调色结果比对。\(notes)")
    }
    static let showInFinder = Copy(en: "Show in Finder", zh: "在访达中显示")
    static let replaceCubesTitle = Copy(en: "Replace existing .cube files?", zh: "替换已有的 .cube 文件？")
    static func replaceCubesBody(_ n: Int) -> Copy {
        Copy(en: "This folder already has \(n) files with the same names.",
             zh: "此文件夹中已有 \(n) 个同名文件。")
    }
    static let replace = Copy(en: "Replace", zh: "替换")
    static let start = Copy(en: "Export…", zh: "导出…")

    // settings
    static let settings = Copy(en: "Settings", zh: "设置")
    static let language = Copy(en: "Language", zh: "语言")
    static let followSystem = Copy(en: "System Default", zh: "跟随系统")
    static let english = Copy(en: "English", zh: "English")
    static let chinese = Copy(en: "简体中文", zh: "简体中文")
}
