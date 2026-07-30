import AppKit
import ArgumentParser
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Install.self, Transcribe.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Option(
        name: .long,
        help: "Dictation language code (pt, en, es…). Defaults to auto-detect on multilingual models."
    )
    var language: String?

    func run() throws {
        if !skipDoctor {
            let checks = DoctorReport.run()
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let chosenModel = try Resolve.model(flag: model)
        let chosenLanguage = try Resolve.language(flag: language, for: chosenModel)

        let transcriber = WhisperKitTranscriber(model: chosenModel, language: chosenLanguage)
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(debug: debugHotkey)
        let capture = AudioCapture()
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let menuBar = MainActor.assumeIsolated { MenuBarController(modelID: chosenModel.id) }

        do {
            try monitor.start { event in
                switch event {
                case .pressed:
                    do {
                        try capture.start()
                        FileHandle.standardError.write(Data("● recording\n".utf8))
                        MainActor.assumeIsolated {
                            overlay?.show(.recording)
                            menuBar.setRecording(true)
                        }
                    } catch {
                        FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                    }
                case .released:
                    let samples = capture.stop()
                    MainActor.assumeIsolated {
                        overlay?.show(.transcribing)
                        menuBar.setTranscribing()
                    }
                    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                    let rms = computeRMS(samples)
                    FileHandle.standardError.write(Data(
                        String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
                    ))
                    if dumpWav, !samples.isEmpty {
                        let path = "/tmp/parrot-last.wav"
                        do {
                            try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                            FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                        } catch {
                            FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                        }
                    }
                    guard !samples.isEmpty else {
                        MainActor.assumeIsolated {
                            overlay?.hide()
                            menuBar.setRecording(false)
                        }
                        return
                    }
                    Task {
                        let started = Date()
                        do {
                            let text = try await transcriber.transcribe(samples)
                            let elapsed = Date().timeIntervalSince(started)
                            FileHandle.standardError.write(Data(
                                String(format: "→ %.2fs · %@\n", elapsed, text).utf8
                            ))
                            await MainActor.run {
                                TextInjector.inject(text)
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        } catch {
                            FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                            await MainActor.run {
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            throw ExitCode(1)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        let lang = chosenLanguage ?? "auto"
        FileHandle.standardError.write(Data(
            "listening on fn hold · model: \(chosenModel.id) · lang: \(lang) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

/// Model + language resolution shared by `run` and `transcribe`: CLI flag >
/// config file > default.
enum Resolve {
    static func model(flag: String?) throws -> TranscriptionModel {
        if let id = flag ?? Config.model() {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                throw ExitCode(1)
            }
            return m
        }
        guard let m = ModelRegistry.recommended() else {
            FileHandle.standardError.write(Data("no models registered\n".utf8))
            throw ExitCode(1)
        }
        return m
    }

    /// Validates against WhisperKit's own supported set, and refuses a
    /// non-English language on an English-only model — the .en checkpoints have
    /// no language tokens at all, so asking for pt there silently yields
    /// English, which is the exact failure this flag exists to prevent.
    static func language(flag: String?, for model: TranscriptionModel) throws -> String? {
        guard let code = (flag ?? Config.language())?.lowercased(), !code.isEmpty else { return nil }
        // "auto" is how you ask for detection from the command line when the
        // config file already names a language — otherwise the config wins and
        // there's no way back to detection without editing the file.
        if code == "auto" { return nil }
        guard Constants.languageCodes.contains(code) else {
            FileHandle.standardError.write(Data("unsupported language code: \(code)\n".utf8))
            throw ExitCode(1)
        }
        if !model.languages.contains("multi"), code != "en" {
            FileHandle.standardError.write(Data(
                "model \(model.id) is English-only — \(code) needs a multilingual model.\n".utf8
            ))
            FileHandle.standardError.write(Data(
                "try: parrot run --model whisper-large-v3-turbo --language \(code)\n".utf8
            ))
            throw ExitCode(1)
        }
        return code
    }
}

/// Transcribe an audio file instead of the microphone. Not part of the
/// dictation loop — it exists so the model/language path can be exercised and
/// diffed without holding down fn (and to check a bad transcript against the
/// same audio afterwards).
struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe an audio file and print the text (debug/verification)."
    )

    @Argument(help: "Audio file to transcribe (wav, caf, m4a…).")
    var file: String

    @Option(name: .long, help: "Model id to use.")
    var model: String?

    @Option(name: .long, help: "Language code (pt, en, es…). Default: auto-detect.")
    var language: String?

    @Flag(name: .long, help: "Print WhisperKit's own decoding log (prefill tokens, detected language).")
    var verbose: Bool = false

    func run() throws {
        let chosenModel = try Resolve.model(flag: model)
        let chosenLanguage = try Resolve.language(flag: language, for: chosenModel)
        let path = (file as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            FileHandle.standardError.write(Data("no such file: \(path)\n".utf8))
            throw ExitCode(1)
        }

        let transcriber = WhisperKitTranscriber(
            model: chosenModel,
            language: chosenLanguage,
            verbose: verbose
        )
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        Task.detached {
            do {
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
                let started = Date()
                let text = try await transcriber.transcribe(samples)
                let elapsed = Date().timeIntervalSince(started)
                let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                FileHandle.standardError.write(Data(String(
                    format: "%.1fs audio · %.1fs transcribe · model %@ · lang %@\n",
                    seconds, elapsed, chosenModel.id, chosenLanguage ?? "auto"
                ).utf8))
                print(text)
            } catch {
                failure = error
            }
            sem.signal()
        }
        sem.wait()
        if let failure {
            FileHandle.standardError.write(Data("transcription failed: \(failure)\n".utf8))
            throw ExitCode(1)
        }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = WhisperKitTranscriber(model: m)

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}
