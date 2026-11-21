import Foundation

/// Why a request to an AI provider did not produce an answer, in words for
/// the person using the app.
public struct AIError: Error, Equatable, LocalizedError {
    public enum Reason: Error, Equatable {
        case missingKey
        case missingModel
        /// `kind` is one of Anthropic's error types, whoever the provider is:
        /// "authentication_error", "rate_limit_error", "overloaded_error", …
        case api(status: Int, kind: String, message: String)
        /// The model, or a safety filter in front of it, declined.
        case refused
        /// The answer hit the output limit before it was complete.
        case truncated
        case empty
        /// The provider cannot do this at all; the text says what.
        case unsupported(String)
    }

    public let reason: Reason
    /// The provider's name, as the user knows it.
    public let provider: String

    public init(_ reason: Reason, provider: String) {
        self.reason = reason
        self.provider = provider
    }

    /// Whether the fix is in the app's settings: a key or a model to enter.
    public var needsSettings: Bool {
        switch reason {
        case .missingKey, .missingModel, .api(_, "authentication_error", _): true
        default: false
        }
    }

    public var errorDescription: String? {
        switch reason {
        case .missingKey:
            "Add an API key for \(provider) in Settings to use AI."
        case .missingModel:
            "Choose a model for \(provider) in Settings."
        case .api(_, "authentication_error", _):
            "\(provider) did not accept the API key. Check it in Settings."
        case .api(_, "permission_error", let message), .api(_, "billing_error", let message):
            "The \(provider) API key cannot be used for this: \(message)"
        case .api(_, "rate_limit_error", _):
            "\(provider) is getting too many requests right now. Try again in a moment."
        case .api(_, "overloaded_error", _):
            "\(provider) is overloaded right now. Try again in a moment."
        case .api(let status, _, let message):
            "The request to \(provider) failed (\(status)): \(message)"
        case .refused:
            "The model declined to answer. Try wording it differently."
        case .truncated:
            "The answer got too long and was cut off. Try asking for less in one go."
        case .empty:
            "The model answered with nothing. Try again, or give it more to go on."
        case .unsupported(let what):
            "\(provider) cannot be used for \(what). Choose another provider for it."
        }
    }
}
