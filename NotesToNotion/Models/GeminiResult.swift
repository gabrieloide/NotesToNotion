import Foundation

struct GeminiResult: Codable {
    let transcript: String
    /// Short session overview shown at the top of the Notion page.
    let summary: String
    /// Legacy field from the summary+keyPoints era; kept (with a default)
    /// so notes persisted by older builds still decode. No longer generated.
    var keyPoints: [String] = []
    /// Content-based page title from Gemini. Optional so notes persisted by
    /// older builds (which had no title) still decode.
    var title: String? = nil
    /// Detailed study notes in Markdown (### headings, bullets, **bold**).
    /// Optional for the same backward-compatibility reason.
    var notes: String? = nil
}
