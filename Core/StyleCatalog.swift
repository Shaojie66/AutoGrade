import CoreML
import Foundation

/// One grading style: the built-in FiveK network or an installed fine-tune
/// (CLAUDE.md 风格模型). `id` is the installed file name, `fivek` for the built-in.
public struct Style: Sendable, Equatable, Identifiable {
    public let id: String
    public let nameEN: String
    public let nameZH: String
    /// The model's licence text, as written by research/convert_coreml.py.
    public let license: String
    public var isBuiltin: Bool { id == StyleCatalog.builtinID }

    public init(id: String, nameEN: String, nameZH: String, license: String) {
        self.id = id
        self.nameEN = nameEN
        self.nameZH = nameZH
        self.license = license
    }
}

public enum StyleError: Error, CustomStringConvertible {
    case unknown(String)

    public var description: String {
        switch self {
        case .unknown(let id): "no style \"\(id)\" is installed"
        }
    }
}

/// The styles this machine can grade with: FiveK from the framework, then every
/// `<id>.mlmodelc` in the styles directory, sorted by id. Each model is loaded
/// once, here, so a broken install shows up as a warning at start-up, not
/// halfway through an analysis. Directories that do not load are skipped.
public final class StyleCatalog: @unchecked Sendable {
    public static let builtinID = "fivek"

    /// `~/Library/Application Support/AutoGrade/Styles`, or `AUTOGRADE_STYLES_DIR`
    /// (the same override Tools/install-style.sh reads).
    public static var defaultDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["AUTOGRADE_STYLES_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoGrade/Styles", isDirectory: true)
    }

    public let styles: [Style]
    public let directory: URL?
    public let warnings: [String]
    private let predictors: [String: LUTPredictor]

    /// `directory` nil means FiveK only. `extra` adds styles directly, for tests.
    public init(kernels: GradeKernels, directory: URL?, computeUnits: MLComputeUnits = .cpuAndGPU,
                extra: [(Style, LUTPredictor)] = []) throws {
        let fivek = try Grader(kernels: kernels, computeUnits: computeUnits)
        var styles = [Style(id: Self.builtinID, nameEN: "FiveK", nameZH: "FiveK",
                            license: fivek.model.modelDescription.metadata[.license] as? String ?? "")]
        var predictors: [String: LUTPredictor] = [Self.builtinID: fivek]
        var warnings: [String] = []

        var installed: [URL] = []
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            installed = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "mlmodelc" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for url in installed {
            let id = url.deletingPathExtension().lastPathComponent
            guard id != Self.builtinID else {
                warnings.append("\(url.lastPathComponent): \"\(Self.builtinID)\" is the built-in style; skipped")
                continue
            }
            do {
                let grader = try Grader(kernels: kernels, modelURL: url, computeUnits: computeUnits)
                let meta = grader.model.modelDescription.metadata
                let names = meta[.creatorDefinedKey] as? [String: String] ?? [:]
                styles.append(Style(id: id, nameEN: names["autograde.name.en"] ?? id, nameZH: names["autograde.name.zh"] ?? id,
                                    license: meta[.license] as? String ?? ""))
                predictors[id] = grader
            } catch {
                warnings.append("\(url.lastPathComponent): could not load (\(error)); skipped")
            }
        }
        for (style, predictor) in extra {
            precondition(predictors[style.id] == nil, "duplicate style \(style.id)")
            styles.append(style)
            predictors[style.id] = predictor
        }
        self.styles = styles
        self.directory = directory
        self.warnings = warnings
        self.predictors = predictors
    }

    public func style(_ id: String) -> Style? { styles.first { $0.id == id } }

    public func predictor(_ id: String) throws -> LUTPredictor {
        guard let p = predictors[id] else { throw StyleError.unknown(id) }
        return p
    }
}
