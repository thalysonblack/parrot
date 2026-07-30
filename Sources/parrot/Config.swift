import Foundation

/// Optional user config at ~/.config/parrot/config.json:
///
///     {
///       "model": "whisper-large-v3-turbo",
///       "language": "pt"
///     }
///
/// Resolution order for both keys: CLI flag > config file > default. The file
/// exists because the LaunchAgent runs `parrot run --skip-doctor` with no other
/// arguments — without a config, a daemonized parrot is stuck on the default
/// English model no matter what you passed the first time you ran it by hand.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/parrot/config.json")

    /// Configured model id, or nil for the registry's recommended model.
    static func model() -> String? {
        guard let id = load()?["model"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Configured Whisper language code ("pt", "en", "es", …), or nil to let
    /// the model detect it. See `Language.isSupported` for the accepted set.
    static func language() -> String? {
        guard let code = load()?["language"] as? String, !code.isEmpty else { return nil }
        return code.lowercased()
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — dictating into the wrong language for a week
    /// because of a stray comma is worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }
}
