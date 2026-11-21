import Foundation
@testable import RhinoCore

/// Answers `ai.ask()` from one service, or from one of several by name.
struct TestAI: AIProvider {
    var services: [AIService]
    let session: URLSession

    func answer(_ question: AIQuestion) async throws -> AIAnswer {
        let service = question.provider.flatMap { name in services.first { $0.name.lowercased() == name.lowercased() } } ?? services[0]
        return try await service.answer(question, session: session)
    }

    func picture(_ request: AIPictureRequest) async throws -> AIPicture {
        let service = request.provider.flatMap { name in services.first { $0.name.lowercased() == name.lowercased() } } ?? services[0]
        return try await service.picture(request, session: session)
    }
}

/// The services and the stubbed session the AI tests share.
extension TestAI {
    static let session = stubbedSession()

    static let claude = AIService.anthropic(apiKey: "test-key", baseURL: URL(string: "https://api.test")!)
    static let openAI = AIService(name: "OpenAI", api: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "sk-test", model: "gpt-test")
    static let local = AIService(name: "Local", api: .openAI, baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: "", model: "llama-test", requiresKey: false)
}
