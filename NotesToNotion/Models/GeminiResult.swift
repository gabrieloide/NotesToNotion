import Foundation

struct GeminiResult: Decodable {
    let transcript: String
    let summary: String
    let keyPoints: [String]
}
