import AutoGradeCore
import CoreML
import Foundation

let usage = """
usage: autograde <input> -o <output.mov> [--style fivek] [--cube-dir DIR] [--cut 0.25] [--size 65] [--codec hevc|prores] [--no-audio] [--reframe 9:16|16:9]
                 [--subtitles srt|burn|both] [--subtitle-lang zh-CN] [--subtitle-file in.srt]
                 [--denoise 0.5] [--background blur|white|black|green|#RRGGBB] [--background-strength 0.6]
       autograde --list-styles
       autograde --list-languages
       autograde --download-speech-model zh-CN

  Grades every shot of <input> with AdaInt and writes <output.mov>.
  --style      style id (default fivek, the built-in FiveK sRGB weights); others are
               installed by Tools/install-style.sh, see --list-styles
  --list-styles  print the installed styles and exit
  --cube-dir   also write one .cube per shot into DIR
  --cut        shot-cut threshold, colour-histogram L1 distance (default 0.25)
  --size       shot LUT lattice size (default 65)
  --codec      output codec (default hevc)
  --no-audio   do not copy the source's audio track (copied as it is by default)
  --reframe    crop to 9:16 (1080x1920) or 16:9 (1920x1080), following the subject
  --subtitles  srt: write <output>.srt; burn: draw them into the picture; both (macOS 26+ to recognise)
  --subtitle-lang  recognition language (default zh-CN); see --list-languages
  --subtitle-file  use this SRT instead of recognising speech
  --download-speech-model LANG  download that language's system speech model (network; needed once)
  --denoise S  temporal noise reduction, strength 0-1 (macOS 26+)
  --background behind people: blur, or a flat colour (white, black, green, #RRGGBB)
  --background-strength S  blur strength 0-1 (default 0.6; sigma = 3% of the height at 1)
  --reframe-csv FILE  also write each frame's crop and subject (frame, seconds, shot, mode, centre, origin,
               length, subject source / x / y)
  Input must be 8-bit 4:2:0 BT.709 limited range. After writing, the output is checked
  (timestamps, BT.709 tags, audio, sampled frames); a failed check exits with status 1
  and keeps the file.
"""

struct Options {
    var input: URL
    var output: URL
    var cubeDir: URL?
    var cut = ShotDetector.defaultThreshold
    var size = 65
    var codec = OutputCodec.hevc
    var style = StyleCatalog.builtinID
    var audio = true
    var reframe: Aspect?
    var reframeCSV: URL?
    var subtitles: String?        // srt | burn | both
    var subtitleLang = "zh-CN"
    var subtitleFile: URL?
    var enhance = EnhanceSettings()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("autograde: \(message)\n".utf8))
    exit(1)
}

func convert<T>(_ text: String, _ make: (String) -> T?, _ message: String) -> T {
    guard let v = make(text) else { fail(message) }
    return v
}

func parse(_ args: [String]) -> Options {
    var input: URL?, output: URL?, cubeDir: URL?
    var cut = ShotDetector.defaultThreshold, size = 65, codec = OutputCodec.hevc, style = StyleCatalog.builtinID
    var audio = true
    var reframe: Aspect?
    var reframeCSV: URL?
    var subtitles: String?, subtitleLang = "zh-CN", subtitleFile: URL?
    var denoise: Float?, background: String?, backgroundStrength = BackgroundEffect.defaultBlurStrength
    var it = args.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) needs a value\n\n\(usage)") }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "-o", "--output": output = URL(fileURLWithPath: value(arg))
        case "--cube-dir": cubeDir = URL(fileURLWithPath: value(arg), isDirectory: true)
        case "--cut": cut = convert(value(arg), Float.init, "--cut wants a number")
        case "--size": size = convert(value(arg), Int.init, "--size wants an integer")
        case "--codec": codec = convert(value(arg), OutputCodec.init(rawValue:), "--codec is hevc or prores")
        case "--style": style = value(arg)
        case "--no-audio": audio = false
        case "--reframe": reframe = convert(value(arg), Aspect.init(rawValue:), "--reframe is 9:16 or 16:9")
        case "--reframe-csv": reframeCSV = URL(fileURLWithPath: value(arg))
        case "--subtitles":
            let v = value(arg)
            guard ["srt", "burn", "both"].contains(v) else { fail("--subtitles is srt, burn or both") }
            subtitles = v
        case "--subtitle-lang": subtitleLang = value(arg)
        case "--subtitle-file": subtitleFile = URL(fileURLWithPath: value(arg))
        case "--denoise":
            let v = convert(value(arg), Float.init, "--denoise wants a strength 0-1")
            guard (0...1).contains(v) else { fail("--denoise wants a strength 0-1") }
            denoise = v
        case "--background": background = value(arg)
        case "--background-strength":
            let v = convert(value(arg), Float.init, "--background-strength wants 0-1")
            guard (0...1).contains(v) else { fail("--background-strength wants 0-1") }
            backgroundStrength = v
        case "--list-languages": listLanguages(); exit(0)
        case "--download-speech-model": downloadModel(value(arg)); exit(0)
        case "--list-styles": listStyles(); exit(0)
        case "-h", "--help": print(usage); exit(0)
        default:
            if arg.hasPrefix("-") || input != nil { fail("unexpected argument \(arg)\n\n\(usage)") }
            input = URL(fileURLWithPath: arg)
        }
    }
    guard let input, let output else { fail(usage) }
    guard (2...129).contains(size) else { fail("--size must be in 2...129") }
    if denoise != nil && !EnhanceSettings.denoiseAvailable { fail("--denoise needs macOS 26 or later") }
    let effect: BackgroundEffect? = background.map {
        guard let e = BackgroundEffect(name: $0, strength: backgroundStrength) else {
            fail("--background is blur, white, black, green or #RRGGBB")
        }
        return e
    }
    return Options(input: input, output: output, cubeDir: cubeDir, cut: cut, size: size, codec: codec, style: style, audio: audio, reframe: reframe,
                   reframeCSV: reframeCSV, subtitles: subtitles, subtitleLang: subtitleLang, subtitleFile: subtitleFile,
                   enhance: EnhanceSettings(denoise: denoise, background: effect))
}

func listLanguages() {
    guard #available(macOS 26.0, *) else { fail("speech recognition needs macOS 26 or later") }
    do {
        for id in try Transcriber.supportedLanguages() {
            let state = try Transcriber.locale(for: id).map { try Transcriber.modelState($0).rawValue } ?? "unsupported"
            print("  \(id.padding(toLength: 8, withPad: " ", startingAt: 0)) \(state)")
        }
    } catch {
        fail("\(error)")
    }
}

func downloadModel(_ identifier: String) {
    guard #available(macOS 26.0, *) else { fail("speech recognition needs macOS 26 or later") }
    do {
        guard let locale = try Transcriber.locale(for: identifier) else { fail("\(identifier) is not supported; see --list-languages") }
        let before = try Transcriber.modelState(locale)
        print("\(locale.identifier): \(before.rawValue)")
        guard before == .needsDownload else { return }
        try Transcriber.downloadModel(locale) { p in print(String(format: "  downloading %.0f%%", p * 100)) }
        print("\(locale.identifier): \(try Transcriber.modelState(locale).rawValue)")
    } catch {
        fail("\(error)")
    }
}

func listStyles() {
    do {
        let catalog = try StyleCatalog(kernels: GradeKernels(metal: try MetalContext()), directory: StyleCatalog.defaultDirectory)
        for warning in catalog.warnings { print("warning: \(warning)") }
        print("styles in \(StyleCatalog.defaultDirectory.path):")
        for s in catalog.styles {
            print("  \(s.id.padding(toLength: 18, withPad: " ", startingAt: 0))\(s.nameEN) / \(s.nameZH)\(s.isBuiltin ? " (built in)" : "")")
        }
    } catch {
        fail("\(error)")
    }
}

func ms(_ seconds: Double, _ frames: Int) -> String { String(format: "%6.2f ms/frame", seconds * 1000 / Double(max(frames, 1))) }

let options = parse(Array(CommandLine.arguments.dropFirst()))
do {
    let engine = try AutoGrader()
    print("autograde \(AutoGrade.version) — \(engine.metal.device.name)")
    for warning in engine.catalog.warnings { print("warning: \(warning)") }
    guard let style = engine.catalog.style(options.style) else {
        fail("no style \"\(options.style)\" is installed; see --list-styles")
    }
    let analysis = try engine.analyze(options.input, lutSize: options.size, cutThreshold: options.cut, style: style.id)
    let info = analysis.info
    for warning in analysis.warnings { print("warning: \(warning)") }
    print("\(options.input.lastPathComponent): \(info.width)x\(info.height), \(analysis.frameCount) frames, "
          + "\(analysis.shots.count) shots, LUT \(options.size)^3, cut \(options.cut), style \(style.id) (\(style.nameEN))")
    for (k, shot) in analysis.shots.enumerated() { print(String(format: "  shot %02d: frames %d-%d", k, shot.first, shot.last)) }
    let a = analysis.times
    print("analyze: decode \(ms(a.decode, a.frames)), yuv→rgb \(ms(a.convert, a.frames)), resize \(ms(a.resize, a.frames)), "
          + "predict \(ms(a.predict, a.frames)), bake \(ms(a.bake, a.frames)), detect+avg \(ms(a.detect, a.frames))")
    var path: CropPath?
    if let aspect = options.reframe {
        let track = try engine.detectSubjects(options.input, analysis: analysis)
        let p = Reframe.path(track: track, shots: analysis.shots, frameTimes: analysis.frameTimes, width: info.width,
                             height: info.height, aspect: aspect, overrides: Array(repeating: nil, count: analysis.shots.count))
        print(String(format: "reframe %@: crop %.1fx%.1f -> %dx%d; subject: %d faces, %d people, %d saliency, %d none; %@ (%.2f s)",
                     aspect.rawValue, p.length.x, p.length.y, p.outputSize.width, p.outputSize.height,
                     track.count(.face), track.count(.human), track.count(.saliency),
                     track.samples.filter { $0 == nil }.count, ms(track.seconds, analysis.frameCount), track.seconds))
        for (k, mode) in p.modes.enumerated() {
            let shot = analysis.shots[k], c = p.centers[shot.first...shot.last]
            print(String(format: "  shot %02d: %@, centre %.3f-%.3f", k, mode.rawValue, c.min()!, c.max()!))
        }
        path = p
        if let csv = options.reframeCSV {
            var text = "frame,seconds,shot,mode,centre,origin_x,origin_y,length_x,length_y,subject,subject_x,subject_y\n"
            for f in 0..<analysis.frameCount {
                let k = analysis.shotIndex(forFrame: f), o = p.origins[f], s = track.samples[f]
                text += String(format: "%d,%.6f,%d,%@,%.6f,%.3f,%.3f,%.3f,%.3f,%@,%.4f,%.4f\n", f, analysis.frameTimes[f].seconds, k,
                               p.modes[k].rawValue, p.centers[f], o.x, o.y, p.length.x, p.length.y,
                               s?.source.rawValue ?? "none", s?.center.x ?? -1, s?.center.y ?? -1)
            }
            try text.write(to: csv, atomically: true, encoding: .utf8)
        }
    }
    // subtitles (CLAUDE.md 字幕): an SRT given, or recognised on this Mac
    var cues: [SubtitleCue]?
    if let mode = options.subtitles {
        if let file = options.subtitleFile {
            let parsed = Subtitles.parseSRT(try String(contentsOf: file, encoding: .utf8))
            for w in parsed.warnings { print("warning: \(file.lastPathComponent): \(w)") }
            cues = parsed.cues
            print("subtitles: \(parsed.cues.count) cues from \(file.lastPathComponent)")
        } else {
            guard #available(macOS 26.0, *) else { fail("recognising speech needs macOS 26 or later; use --subtitle-file") }
            guard let locale = try Transcriber.locale(for: options.subtitleLang) else {
                fail("\(options.subtitleLang) is not supported; see --list-languages")
            }
            let start = CFAbsoluteTimeGetCurrent()
            let tokens: [SubtitleToken]
            do {
                tokens = try Transcriber.transcribe(options.input, locale: locale)
            } catch {
                fail("speech recognition failed (\(error)); if the model is missing: autograde --download-speech-model \(options.subtitleLang)")
            }
            let frameSeconds = info.duration.seconds / Double(max(analysis.frameCount, 1))
            let made = Subtitles.cues(tokens: tokens, cuts: analysis.shots.dropFirst().map { analysis.frameTimes[$0.first].seconds },
                                      frameSeconds: frameSeconds, script: SubtitleScript(language: locale.identifier),
                                      vertical: options.reframe == .vertical9x16)
            cues = made
            print(String(format: "subtitles: %@, %d tokens -> %d cues in %.2f s", locale.identifier, tokens.count, made.count,
                         CFAbsoluteTimeGetCurrent() - start))
        }
        if mode != "burn", let cues {
            let srt = options.output.deletingPathExtension().appendingPathExtension("srt")
            if FileManager.default.fileExists(atPath: srt.path) { fail("\(srt.path) already exists (refusing to overwrite)") }
            try Subtitles.srt(cues).write(to: srt, atomically: true, encoding: .utf8)
            print("wrote \(srt.path)")
        }
    }
    let outSize = path?.outputSize ?? (info.width, info.height)
    let burn = (options.subtitles == "burn" || options.subtitles == "both") ? cues.map {
        SubtitleBurn(cues: $0, width: outSize.0, height: outSize.1, kernels: engine.kernels)
    } : nil
    var enhance = options.enhance
    if enhance.background != nil {
        let start = Date()
        let coverage = try engine.personCoverage(options.input, analysis: analysis)
        let people = PersonSegmentation.shotsWithPeople(coverage: coverage, shots: analysis.shots)
        enhance.backgroundShots = people
        let skipped = people.indices.filter { !people[$0] }.map { String($0 + 1) }
        print(String(format: "people:  %.2f s, %d of %d shots", Date().timeIntervalSince(start), people.count - skipped.count, people.count)
              + (skipped.isEmpty ? "" : "; no one found in shot \(skipped.joined(separator: ", ")), background left as it is"))
    }
    let result = try engine.render(options.input, analysis: analysis, luts: analysis.luts, to: options.output,
                                   codec: options.codec, audio: options.audio, reframe: path, subtitles: burn,
                                   enhance: enhance.isEmpty ? nil : enhance)
    let r = result.times
    if let e = result.enhance {
        print("enhance: " + [e.denoise.map { String(format: "denoise %.2f", $0) }, e.background.map { "background \($0)" }]
            .compactMap { $0 }.joined(separator: ", "))
    }
    for warning in result.warnings { print("warning: \(warning)") }
    print("render:  decode \(ms(r.decode, r.frames)), yuv→rgb \(ms(r.convert, r.frames)), apply+bgra \(ms(r.apply, r.frames)), "
          + "encode \(ms(r.encode, r.frames))")
    print("wrote \(options.output.path)" + (result.audioPackets.map { " (audio: \($0) packets copied)" } ?? " (no audio)"))
    let report = try engine.checkExport(options.output, source: options.input, analysis: analysis, luts: analysis.luts,
                                        render: result)
    for f in report.frames {
        print(String(format: "check:   shot %02d frame %d: mean %.2f, bias R %+.2f G %+.2f B %+.2f levels",
                     f.shot, f.frame, f.meanAbs, f.bias[0], f.bias[1], f.bias[2]))
    }
    if let d = report.audioMaxDiff, let f = report.audioFrames {
        print(String(format: "check:   audio decoded: max diff %.2e, %d frames vs source %d", d, f.export, f.source))
    }
    print(String(format: "check:   %d video samples, %@, %.2f s — %@", report.videoSamples,
                 report.audioPackets.map { "\($0) audio packets" } ?? "no audio", report.seconds,
                 report.passed ? "passed" : "FAILED"))
    if !report.subtitleBands.isEmpty {
        print("check:   subtitle band, share far off: " + report.subtitleBands.map { String(format: "%.4f", $0) }.joined(separator: " "))
    }
    for failure in report.failures { print("check failed: \(failure)") }
    if let dir = options.cubeDir {
        let prefix = options.input.deletingPathExtension().lastPathComponent
        let cubes = try engine.writeCubes(analysis, luts: analysis.luts, to: dir, prefix: prefix)
        print("wrote \(cubes.count) .cube to \(dir.path)")
    }
    if !report.passed { exit(1) }
} catch {
    fail("\(error)")
}
