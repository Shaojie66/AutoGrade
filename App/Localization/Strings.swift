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
