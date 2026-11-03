import AutoGradeCore
import CoreML
import Foundation

let usage = """
usage: autograde <input> -o <output.mov> [--style fivek] [--cube-dir DIR] [--cut 0.25] [--size 65] [--codec hevc|prores] [--no-audio]
       autograde --list-styles

  Grades every shot of <input> with AdaInt and writes <output.mov>.
  --style      style id (default fivek, the built-in FiveK sRGB weights); others are
               installed by Tools/install-style.sh, see --list-styles
  --list-styles  print the installed styles and exit
  --cube-dir   also write one .cube per shot into DIR
  --cut        shot-cut threshold, colour-histogram L1 distance (default 0.25)
  --size       shot LUT lattice size (default 65)
  --codec      output codec (default hevc)
  --no-audio   do not copy the source's audio track (copied as it is by default)
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
        case "--list-styles": listStyles(); exit(0)
        case "-h", "--help": print(usage); exit(0)
        default:
            if arg.hasPrefix("-") || input != nil { fail("unexpected argument \(arg)\n\n\(usage)") }
            input = URL(fileURLWithPath: arg)
        }
    }
    guard let input, let output else { fail(usage) }
    guard (2...129).contains(size) else { fail("--size must be in 2...129") }
    return Options(input: input, output: output, cubeDir: cubeDir, cut: cut, size: size, codec: codec, style: style, audio: audio)
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
    let result = try engine.render(options.input, analysis: analysis, luts: analysis.luts, to: options.output,
                                   codec: options.codec, audio: options.audio)
    let r = result.times
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
