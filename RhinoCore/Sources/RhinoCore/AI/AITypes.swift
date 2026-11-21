import Foundation

// AI in Rhino: the writer that produces scripts, and `ai.ask()` inside them.
// Both go through an `AIService`, which is one provider set up with a key and
// a model. Two wire formats cover the providers there are: Anthropic's
// Messages API, and the chat-completions format OpenAI introduced and Google,
// xAI, OpenRouter, Ollama and most others also speak.

/// What a script asked with `ai.ask()`.
public struct AIQuestion: Sendable, Equatable {
    public var prompt: String
    /// Standing instructions for the answer: a role, a tone, rules.
    public var system: String?
    /// The name of a provider set up in the app. Nil means the default one.
    public var provider: String?
    /// Nil means the model chosen for the provider.
    public var model: String?
    /// Nil means the provider's default limit.
    public var maxTokens: Int?
    /// "low", "medium" or "high". Nil means the model's default.
    public var effort: String?
    /// A JSON Schema, as JSON text, the answer has to match. Nil means plain text.
    public var schema: String?
    /// Files for the model to look at along with the prompt.
    public var attachments: [AIAttachment]

    public init(
        prompt: String, system: String? = nil, provider: String? = nil, model: String? = nil,
        maxTokens: Int? = nil, effort: String? = nil, schema: String? = nil, attachments: [AIAttachment] = []
    ) {
        self.attachments = attachments
        self.prompt = prompt
        self.system = system
        self.provider = provider
        self.model = model
        self.maxTokens = maxTokens
        self.effort = effort
        self.schema = schema
    }
}

/// A file handed to the model with a question: a picture, a PDF, or text.
public struct AIAttachment: Sendable, Equatable {
    public enum Kind: Sendable {
        case image, pdf, text
    }

    public struct Unreadable: LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    /// The largest file sent along. Providers refuse requests much beyond this.
    public static let maxSize = 20 * 1024 * 1024

    public var name: String
    public var kind: Kind
    /// "image/png", "application/pdf", "text/plain".
    public var mediaType: String
    public var data: Data

    public init(name: String, kind: Kind, mediaType: String, data: Data) {
        self.name = name
        self.kind = kind
        self.mediaType = mediaType
        self.data = data
    }

    /// Reads a file to send. Pictures and PDFs go as they are; anything else
    /// has to be text.
    public init(url: URL) throws {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            throw Unreadable(message: "ai.ask() cannot read the file \(url.path(percentEncoded: false)).")
        }
        guard data.count <= Self.maxSize else {
            throw Unreadable(message: "\(name) is too large to send to an AI model (the limit is 20 MB).")
        }
        let images = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        let ext = url.pathExtension.lowercased()
        if let type = images[ext] {
            self.init(name: name, kind: .image, mediaType: type, data: data)
        } else if ext == "pdf" {
            self.init(name: name, kind: .pdf, mediaType: "application/pdf", data: data)
        } else if String(data: data, encoding: .utf8) != nil {
            self.init(name: name, kind: .text, mediaType: "text/plain", data: data)
        } else {
            throw Unreadable(message: "ai.ask() cannot send \(name): only pictures (PNG, JPEG, GIF, WebP), PDFs and text files can go to an AI model.")
        }
    }

    var base64: String { data.base64EncodedString() }
    var dataURL: String { "data:\(mediaType);base64,\(base64)" }
    /// A text file as it is shown to the model, with its name around it.
    var quoted: String { "<file name=\"\(name)\">\n\(String(decoding: data, as: UTF8.self))\n</file>" }
}

public struct AIAnswer: Sendable, Equatable {
    /// The answer. With a schema, JSON text that matches it.
    public var text: String
    /// Who answered, as the user named the provider.
    public var provider: String
    /// The model that answered.
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int

    public init(text: String, provider: String = "", model: String = "", inputTokens: Int = 0, outputTokens: Int = 0) {
        self.text = text
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// What a script asked for with `ai.image()`.
public struct AIPictureRequest: Sendable, Equatable {
    public var prompt: String
    /// The name of a provider set up in the app. Nil means the default one.
    public var provider: String?
    /// Nil lets the provider's best picture model be found.
    public var model: String?
    /// "1024x1024", "1536x1024", "1024x1536". Nil means square.
    public var size: String?
    /// Nothing behind the subject, for models that can do that.
    public var transparent: Bool

    public init(prompt: String, provider: String? = nil, model: String? = nil, size: String? = nil, transparent: Bool = false) {
        self.prompt = prompt
        self.provider = provider
        self.model = model
        self.size = size
        self.transparent = transparent
    }
}

/// A picture a model made.
public struct AIPicture: Sendable, Equatable {
    /// The image file's bytes, usually a PNG.
    public var data: Data
    public var provider: String
    public var model: String

    public init(data: Data, provider: String = "", model: String = "") {
        self.data = data
        self.provider = provider
        self.model = model
    }
}

/// Answers `ai.ask()` and `ai.image()` for the engine. Errors it throws reach
/// the script with their `localizedDescription` as the message.
public protocol AIProvider: Sendable {
    func answer(_ question: AIQuestion) async throws -> AIAnswer
    func picture(_ request: AIPictureRequest) async throws -> AIPicture
}

extension AIProvider {
    /// Making pictures is optional; a provider that cannot says so.
    public func picture(_ request: AIPictureRequest) async throws -> AIPicture {
        throw AIError(.unsupported("making pictures"), provider: "This AI provider")
    }
}
