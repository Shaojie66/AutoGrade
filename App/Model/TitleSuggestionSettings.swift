import Foundation
import Observation

/// Whether DeepSeek title candidates are on, and whether a key is saved
/// (CLAUDE.md 封面 / 云端候选 / App). Shared by Settings and the Covers page.
/// The key itself is only read when a request is made, never kept or shown.
@MainActor @Observable
final class TitleSuggestionSettings {
    static let shared = TitleSuggestionSettings(defaults: .standard, secrets: KeychainSecretStore.deepSeek)
    static let enabledKey = "titleSuggestions"

    var enabled: Bool {
        didSet { if enabled != oldValue { defaults.set(enabled, forKey: Self.enabledKey) } }
    }
    private(set) var hasKey: Bool
    private(set) var lastError: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: SecretStore

    /// Injectable so AppTests own their settings and never touch the real Keychain.
    init(defaults: UserDefaults, secrets: SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
        enabled = defaults.bool(forKey: Self.enabledKey)      // off unless turned on
        hasKey = secrets.read().map { !$0.isEmpty } ?? false
    }

    /// Save a key typed in Settings (whitespace trimmed); an empty one is ignored.
    func saveKey(_ typed: String) {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try secrets.write(key)
            hasKey = true
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    func deleteKey() {
        do {
            try secrets.delete()
            hasKey = false
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    /// The key for one request, if on and saved.
    func keyForRequest() -> String? {
        guard enabled else { return nil }
        return secrets.read().flatMap { $0.isEmpty ? nil : $0 }
    }
}
