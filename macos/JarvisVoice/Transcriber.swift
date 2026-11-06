import AVFoundation
import CoreMedia
import Foundation
import Speech

/// One piece of recognised speech. Times are on the recogniser's clock
/// (seconds of audio it has been given), not the wall clock.
/// One recognised word (with any spaces or punctuation that follow it) and when it was said.
struct Word: Sendable {
    let text: String
    let start: Double
    let end: Double
}

struct TranscriptEvent: Sendable {
    let text: String
    let words: [Word]
    let isFinal: Bool
    let start: Double
    let end: Double
}

struct TranscriberError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Apple's on-device speech recognition (SpeechAnalyzer), running for as long
/// as the app does. Used both to spot the wake phrase and to transcribe the
/// request that follows it. Audio never leaves the Mac.
final class Transcriber: @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var consumer: Task<Void, Never>?
    private(set) var engineName = "none"

    var onEvent: (@MainActor (TranscriptEvent) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    /// Prepares the model (downloading Apple's speech asset if needed) and
    /// starts the analyzer. Returns the audio format it wants to be fed.
    func start(localeID: String, contextualStrings: [String],
               status: @escaping @MainActor (String) -> Void) async throws -> AVAudioFormat {
        let wanted = Locale(identifier: localeID)

        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            // Time-indexed: every word carries the moment it was spoken, so a request can
            // start exactly after the wake word, or after Jarvis stopped talking.
            let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            if try await ensureAssets(module, status: status) {
                engineName = "Apple SpeechTranscriber, on-device (\(locale.identifier))"
                return try await begin(module, results: module.results,
                                       text: { String($0.text.characters) },
                                       words: { Transcriber.words($0.text) },
                                       contextualStrings: contextualStrings)
            }
        }

        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
            let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            if try await ensureAssets(module, status: status) {
                engineName = "Apple DictationTranscriber, on-device (\(locale.identifier))"
                return try await begin(module, results: module.results,
                                       text: { String($0.text.characters) },
                                       words: { _ in [] },
                                       contextualStrings: contextualStrings)
            }
        }

        throw TranscriberError("no on-device speech model is available for \(localeID)")
    }

    private func ensureAssets(_ module: any SpeechModule,
                              status: @escaping @MainActor (String) -> Void) async throws -> Bool {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return true
        case .unsupported:
            return false
        default:
            await status("Downloading Apple's on-device speech model…")
            log("downloading the on-device speech model")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            return await AssetInventory.status(forModules: [module]) == .installed
        }
    }

    private func begin<Results: AsyncSequence & Sendable>(
        _ module: any SpeechModule,
        results: Results,
        text: @escaping @Sendable (Results.Element) -> String,
        words: @escaping @Sendable (Results.Element) -> [Word],
        contextualStrings: [String]
    ) async throws -> AVAudioFormat where Results.Element: SpeechModuleResult {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError("the speech model reported no usable audio format")
        }
        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        if !contextualStrings.isEmpty {
            // Biases recognition toward the wake word ("Jarvis" is not common vocabulary).
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            do { try await analyzer.setContext(context) } catch { log("contextual strings not applied: \(error)") }
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(2000))
        self.input = continuation
        self.analyzer = analyzer

        let deliver = onEvent
        let failed = onFailure
        consumer = Task {
            do {
                for try await result in results {
                    let event = TranscriptEvent(
                        text: text(result),
                        words: words(result),
                        isFinal: result.isFinal,
                        start: result.range.start.seconds,
                        end: result.range.end.seconds
                    )
                    await MainActor.run { deliver?(event) }
                }
                if !Task.isCancelled {
                    await MainActor.run { failed?("the speech recogniser stopped") }
                }
            } catch {
                if !Task.isCancelled {
                    let message = "the speech recogniser failed: \(error.localizedDescription)"
                    await MainActor.run { failed?(message) }
                }
            }
        }

        try await analyzer.start(inputSequence: stream)
        return format
    }

    /// Words with their times. Untimed runs (spaces, punctuation) stay with the word before them.
    static func words(_ text: AttributedString) -> [Word] {
        var out: [Word] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let range = run.audioTimeRange {
                out.append(Word(text: piece, start: range.start.seconds, end: range.end.seconds))
            } else if let last = out.popLast() {
                out.append(Word(text: last.text + piece, start: last.start, end: last.end))
            }
        }
        return out
    }

    /// Called from the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        input?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Asks the model to commit everything heard so far, so a request is
    /// judged on final rather than provisional text.
    func finalizeNow() async {
        try? await analyzer?.finalize(through: nil)
    }

    func stop() async {
        consumer?.cancel()
        input?.finish()
        input = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }
}
