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
    static let emptyHint = Copy(en: "Or drop a video here. Supports 8-bit H.264/HEVC in BT.709.",
                                zh: "也可以将视频拖到这里。支持 BT.709 色彩空间的 8-bit H.264/HEVC 视频。")

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
