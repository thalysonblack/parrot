import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    /// Whisper language code, or nil to detect per utterance.
    private let language: String?
    /// Turns on WhisperKit's own logging, including the prefill tokens — the
    /// only way to see which language token actually reached the decoder.
    private let verbose: Bool
    private var pipeline: WhisperKit?

    init(model: TranscriptionModel, language: String? = nil, verbose: Bool = false) {
        self.modelID = model.id
        self.model = model
        self.language = language
        self.verbose = verbose
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(
            model: whisperKitID,
            verbose: verbose,
            logLevel: verbose ? .debug : .none,
            prewarm: true,
            load: true
        )
        pipeline = try await WhisperKit(config)
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)
        if verbose {
            // What the decoder actually ran with — not what we asked for.
            let used = results.map(\.language).joined(separator: ",")
            FileHandle.standardError.write(Data("decoder language: \(used)\n".utf8))
        }
        let raw = results.map(\.text).joined(separator: " ")
        return Self.sanitize(raw)
    }

    /// WhisperKit's defaults leave the decoder primed for English even on a
    /// multilingual checkpoint: `language` nil + `usePrefillPrompt` true makes
    /// `detectLanguage` default to false, and the TextDecoder then falls back to
    /// `Constants.defaultLanguageCode` ("en"). So we always state the intent
    /// explicitly rather than inherit it.
    ///
    /// Don't overestimate this, though — measured 2026-07-29 on large-v3-turbo
    /// with 7s of Portuguese, forcing en/pt/es/ja all returned byte-identical
    /// correct Portuguese (the result reported `language: ja` while writing
    /// Portuguese). The turbo checkpoint largely ignores the language token on
    /// unambiguous audio. What actually breaks Portuguese is picking an `.en`
    /// model, which hallucinates fluent English instead of transcribing.
    private var options: DecodingOptions {
        DecodingOptions(
            verbose: verbose,
            task: .transcribe,          // never .translate — we want pt in, pt out
            language: language,
            detectLanguage: language == nil
        )
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
