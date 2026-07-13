import Foundation

struct GeminiResult: Codable {
    let transcript: String
    let summary: String
    let keyPoints: [String]
}
