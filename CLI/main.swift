import AutoGradeCore
import CoreML
import Foundation

let usage = """
usage: autograde <input> -o <output.mov> [--cube-dir DIR] [--cut 0.25] [--size 65] [--codec hevc|prores]

  Grades every shot of <input> with AdaInt (FiveK sRGB) and writes <output.mov>.
  --cube-dir   also write one .cube per shot into DIR
  --cut        shot-cut threshold, colour-histogram L1 distance (default 0.25)
  --size       shot LUT lattice size (default 65)
  --codec      output codec (default hevc)
  Input must be 8-bit 4:2:0 BT.709 limited range. Audio is not carried over yet.
"""

struct Options {
    var input: URL
    var output: URL
    var cubeDir: URL?
    var cut = ShotDetector.defaultThreshold
    var size = 65
    var codec = OutputCodec.hevc
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
    var cut = ShotDetector.defaultThreshold, size = 65, codec = OutputCodec.hevc
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
        case "-h", "--help": print(usage); exit(0)
        default:
            if arg.hasPrefix("-") || input != nil { fail("unexpected argument \(arg)\n\n\(usage)") }
            input = URL(fileURLWithPath: arg)
        }
    }
    guard let input, let output else { fail(usage) }
    guard (2...129).contains(size) else { fail("--size must be in 2...129") }
    return Options(input: input, output: output, cubeDir: cubeDir, cut: cut, size: size, codec: codec)
}

func ms(_ seconds: Double, _ frames: Int) -> String { String(format: "%6.2f ms/frame", seconds * 1000 / Double(max(frames, 1))) }

let options = parse(Array(CommandLine.arguments.dropFirst()))
do {
    let engine = try AutoGrader()
    print("autograde \(AutoGrade.version) — \(engine.metal.device.name)")
    let analysis = try engine.analyze(options.input, lutSize: options.size, cutThreshold: options.cut)
    let info = analysis.info
    for warning in analysis.warnings { print("warning: \(warning)") }
    print("\(options.input.lastPathComponent): \(info.width)x\(info.height), \(analysis.frameCount) frames, "
          + "\(analysis.shots.count) shots, LUT \(options.size)^3, cut \(options.cut)")
    for (k, shot) in analysis.shots.enumerated() { print(String(format: "  shot %02d: frames %d-%d", k, shot.first, shot.last)) }
    let a = analysis.times
    print("analyze: decode \(ms(a.decode, a.frames)), yuv→rgb \(ms(a.convert, a.frames)), resize \(ms(a.resize, a.frames)), "
          + "predict \(ms(a.predict, a.frames)), bake \(ms(a.bake, a.frames)), detect+avg \(ms(a.detect, a.frames))")
    let r = try engine.render(options.input, analysis: analysis, luts: analysis.luts, to: options.output, codec: options.codec)
    print("render:  decode \(ms(r.decode, r.frames)), yuv→rgb \(ms(r.convert, r.frames)), apply+bgra \(ms(r.apply, r.frames)), "
          + "encode \(ms(r.encode, r.frames))")
    print("wrote \(options.output.path)")
    if let dir = options.cubeDir {
        let prefix = options.input.deletingPathExtension().lastPathComponent
        let cubes = try engine.writeCubes(analysis, luts: analysis.luts, to: dir, prefix: prefix)
        print("wrote \(cubes.count) .cube to \(dir.path)")
    }
} catch {
    fail("\(error)")
}
