import Foundation
import Synchronization
@testable import RhinoCore

/// Collects everything a run emits and answers prompts from a script.
final class Recorder: Sendable {
    private let state = Mutex<[RunEvent]>([])
    private let answers: @Sendable (PromptRequest) -> PromptRequest.Answer

    init(answers: @escaping @Sendable (PromptRequest) -> PromptRequest.Answer = { _ in .cancelled }) {
        self.answers = answers
    }

    func record(_ event: RunEvent) {
        state.withLock { $0.append(event) }
        if case .prompt(let request) = event {
            request.reply(answers(request))
        }
    }

    var events: [RunEvent] { state.withLock { $0 } }

    var logs: [String] {
        events.compactMap { if case .log(let entry) = $0 { entry.message } else { nil } }
    }

    var runs: [RunInfo] {
        events.compactMap { if case .runStarted(let info) = $0 { info } else { nil } }
    }

    var finishedSpans: [HTTPSpan] {
        events.compactMap { if case .spanFinished(let span) = $0 { span } else { nil } }
    }

    /// Published values in the order they first appeared, each in its latest state.
    var outputs: [OutputValue] {
        var order: [UUID] = []
        var latest: [UUID: OutputValue] = [:]
        for case .output(let value) in events {
            if latest[value.id] == nil { order.append(value.id) }
            latest[value.id] = value
        }
        return order.compactMap { latest[$0] }
    }

    /// Written files in the order they first appeared, each in its latest state.
    var savedFiles: [SavedFile] {
        var order: [UUID] = []
        var latest: [UUID: SavedFile] = [:]
        for case .file(let saved) in events {
            if latest[saved.id] == nil { order.append(saved.id) }
            latest[saved.id] = saved
        }
        return order.compactMap { latest[$0] }
    }

    var writtenFiles: [URL] {
        savedFiles.map(\.url)
    }

    var notifications: [RunNotification] {
        events.compactMap { if case .notification(let notification) = $0 { notification } else { nil } }
    }
}
