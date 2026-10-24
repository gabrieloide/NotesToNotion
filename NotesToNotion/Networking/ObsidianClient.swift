import Foundation

struct ObsidianClient {
    let token: String

    private static let repoOwner = "gabrieloide"
    private static let repoName = "perfil-obsidian"
    private static let filePath = "11_Plan_Japones.md"
    private static let apiBaseURL = "https://api.github.com"

    enum ObsidianError: LocalizedError {
        case invalidURL
        case requestFailed(String)
        case decodingFailed
        case fileNotFound

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "La URL de GitHub no es válida."
            case .requestFailed(let detail):
                return "Error al conectar con GitHub: \(detail)"
            case .decodingFailed:
                return "No se pudo decodificar el archivo de Obsidian desde GitHub."
            case .fileNotFound:
                return "El archivo 11_Plan_Japones.md no existe en el repositorio."
            }
        }
    }

    private struct GitHubContentResponse: Codable {
        let sha: String
        let content: String
        let encoding: String?
    }

    func recordClassSession(
        title: String? = nil,
        overview: String,
        notesMarkdown: String? = nil,
        notionURL: URL? = nil
    ) async throws {
        let (currentSha, currentContent) = try await fetchFile()
        let updatedContent = updatePlanContent(
            originalContent: currentContent,
            title: title,
            overview: overview,
            notesMarkdown: notesMarkdown,
            notionURL: notionURL
        )
        try await commitFile(sha: currentSha, newContent: updatedContent)
    }

    private func fetchFile() async throws -> (sha: String, content: String) {
        guard let url = URL(string: "\(Self.apiBaseURL)/repos/\(Self.repoOwner)/\(Self.repoName)/contents/\(Self.filePath)") else {
            throw ObsidianError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NotesToNotion", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ObsidianError.requestFailed("Respuesta inválida del servidor.")
        }

        if httpResponse.statusCode == 404 {
            throw ObsidianError.fileNotFound
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Código \(httpResponse.statusCode)"
            throw ObsidianError.requestFailed(errorBody)
        }

        let decodedResponse = try JSONDecoder().decode(GitHubContentResponse.self, from: data)
        let cleanBase64 = decodedResponse.content
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        guard let contentData = Data(base64Encoded: cleanBase64, options: .ignoreUnknownCharacters),
              let stringContent = String(data: contentData, encoding: .utf8) else {
            throw ObsidianError.decodingFailed
        }

        return (decodedResponse.sha, stringContent)
    }

    private func commitFile(sha: String, newContent: String) async throws {
        guard let url = URL(string: "\(Self.apiBaseURL)/repos/\(Self.repoOwner)/\(Self.repoName)/contents/\(Self.filePath)") else {
            throw ObsidianError.invalidURL
        }

        let base64Content = Data(newContent.utf8).base64EncodedString()
        let payload: [String: Any] = [
            "message": "docs(japones): registrar clase particular en 11_Plan_Japones",
            "content": base64Content,
            "sha": sha
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NotesToNotion", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ObsidianError.requestFailed("Respuesta inválida del servidor al guardar.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Código \(httpResponse.statusCode)"
            throw ObsidianError.requestFailed(errorBody)
        }
    }

    func updatePlanContent(
        originalContent: String,
        title: String?,
        overview: String,
        notesMarkdown: String?,
        notionURL: URL?
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let today = dateFormatter.string(from: Date())

        let updatedYamlContent: String
        let yamlPattern = #"(?m)^actualizado:\s*.*$"#
        if let regex = try? NSRegularExpression(pattern: yamlPattern) {
            let range = NSRange(originalContent.startIndex..., in: originalContent)
            updatedYamlContent = regex.stringByReplacingMatches(
                in: originalContent,
                options: [],
                range: range,
                withTemplate: "actualizado: \(today)"
            )
        } else {
            updatedYamlContent = originalContent
        }

        let cleanTema: String
        if let t = title, !t.isEmpty {
            let sanitized = Self.sanitizeCell(t)
            cleanTema = sanitized.isEmpty ? "Clase particular de japones" : sanitized
        } else {
            cleanTema = "Clase particular de japones"
        }

        let cleanCorrections: String
        let extracted = Self.extractCorrectionsSummary(from: notesMarkdown ?? "")
        if !extracted.isEmpty {
            cleanCorrections = extracted
        } else {
            let cleanOverview = Self.sanitizeCell(overview)
            if !cleanOverview.isEmpty {
                if let dotIndex = cleanOverview.firstIndex(of: ".") {
                    let sentence = String(cleanOverview[...dotIndex])
                    cleanCorrections = sentence.count > 120 ? String(sentence.prefix(115)) : sentence
                } else {
                    cleanCorrections = cleanOverview.count > 120 ? String(cleanOverview.prefix(115)) : cleanOverview
                }
            } else {
                cleanCorrections = "Sesión completada y revisada"
            }
        }

        let notionCell: String
        if let url = notionURL {
            notionCell = "[Apunte en Notion](\(url.absoluteString))"
        } else {
            notionCell = "Resumen guardado en Notion"
        }

        let newRow = "| \(today) | Clase particular | \(cleanTema) | Práctica oral | \(cleanCorrections) | \(notionCell) |"

        return Self.insertSessionRow(into: updatedYamlContent, newRow: newRow)
    }

    internal static func insertSessionRow(into markdown: String, newRow: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var outputLines: [String] = []
        var inSection6 = false
        var inserted = false
        var lastTableRowIndex = -1

        for line in lines {
            if line.starts(with: "## 6. Registro de Sesiones") {
                inSection6 = true
            } else if inSection6 && line.starts(with: "## ") {
                if !inserted {
                    if lastTableRowIndex >= 0 {
                        outputLines.insert(newRow, at: lastTableRowIndex + 1)
                    } else {
                        outputLines.append(newRow)
                    }
                    inserted = true
                }
                inSection6 = false
            }

            if inSection6 && !inserted {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().starts(with: "| pendiente") {
                    outputLines.append(newRow)
                    inserted = true
                } else if trimmed.starts(with: "|") {
                    lastTableRowIndex = outputLines.count
                }
            }

            outputLines.append(line)
        }

        if !inserted {
            if lastTableRowIndex >= 0 {
                outputLines.insert(newRow, at: lastTableRowIndex + 1)
            } else {
                outputLines.append(newRow)
            }
        }

        return outputLines.joined(separator: "\n")
    }

    internal static func extractCorrectionsSummary(from notesMarkdown: String) -> String {
        guard !notesMarkdown.isEmpty else { return "" }
        guard let correctionsRange = notesMarkdown.range(of: "### Corrections & Natural Phrasing") else {
            return ""
        }

        let substring = notesMarkdown[correctionsRange.upperBound...]
        let sectionText: Substring
        if let nextHeading = substring.range(of: "### ") {
            sectionText = substring[..<nextHeading.lowerBound]
        } else {
            sectionText = substring
        }

        let lines = sectionText.components(separatedBy: .newlines)
        var items: [(bullet: String, example: String?)] = []
        var currentBullet: String?
        var currentExample: String?

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let isIndented = rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t")
            if !isIndented && trimmed.hasPrefix("- ") && !trimmed.contains("Example:") {
                if let b = currentBullet {
                    items.append((bullet: b, example: currentExample))
                    if items.count >= 2 { break }
                }
                currentBullet = trimmed
                currentExample = nil
            } else if trimmed.contains("Example:") {
                if currentExample == nil {
                    currentExample = trimmed
                }
            }
        }
        if let b = currentBullet, items.count < 2 {
            items.append((bullet: b, example: currentExample))
        }

        var extracted: [String] = []
        if !items.isEmpty {
            for item in items.prefix(2) {
                let source = item.bullet
                let cleaned = source
                    .replacingOccurrences(of: "- Example:", with: "")
                    .replacingOccurrences(of: "Example:", with: "")
                    .replacingOccurrences(of: "- **", with: "")
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "->", with: ", ")
                    .replacingOccurrences(of: "**", with: "")
                let sanitized = sanitizeCell(cleaned)
                if !sanitized.isEmpty {
                    extracted.append(sanitized)
                }
            }
        } else {
            for rawLine in lines {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let cleaned = trimmed
                    .replacingOccurrences(of: "- Example:", with: "")
                    .replacingOccurrences(of: "Example:", with: "")
                    .replacingOccurrences(of: "- **", with: "")
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "->", with: ", ")
                    .replacingOccurrences(of: "**", with: "")
                let sanitized = sanitizeCell(cleaned)
                if !sanitized.isEmpty {
                    extracted.append(sanitized)
                    if extracted.count >= 2 { break }
                }
            }
        }

        guard !extracted.isEmpty else { return "" }
        let joined = extracted.joined(separator: ", ")
        let sanitized = sanitizeCell(joined)
        if sanitized.count > 120 {
            let prefix = String(sanitized.prefix(115))
            if let lastSpace = prefix.lastIndex(of: " ") {
                return sanitizeCell(String(prefix[..<lastSpace]))
            }
            return sanitizeCell(prefix)
        }
        return sanitized
    }

    func sanitizeCell(_ text: String) -> String {
        Self.sanitizeCell(text)
    }

    func sanitizeForTableCell(_ text: String) -> String {
        Self.sanitizeCell(text)
    }

    func extractConciseCorrections(from notesMarkdown: String?, overview: String) -> String {
        let extracted = Self.extractCorrectionsSummary(from: notesMarkdown ?? "")
        if !extracted.isEmpty {
            return extracted
        }
        let cleanOverview = Self.sanitizeCell(overview)
        if !cleanOverview.isEmpty {
            if let dotIndex = cleanOverview.firstIndex(of: ".") {
                let sentence = String(cleanOverview[...dotIndex])
                return sentence.count > 120 ? String(sentence.prefix(115)) : sentence
            }
            return cleanOverview.count > 120 ? String(cleanOverview.prefix(115)) : cleanOverview
        }
        return "Sesión completada y revisada"
    }

    internal static func sanitizeCell(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let isRealEmoji = scalar.value > 0x7F && (scalar.properties.isEmojiPresentation || scalar.value >= 0x1F300 || (scalar.properties.isEmoji && scalar.value > 0x2000))
            if !isRealEmoji {
                result.unicodeScalars.append(scalar)
            }
        }

        result = result.replacingOccurrences(of: "|", with: ", ")
        result = result.replacingOccurrences(of: "->", with: ", ")

        result = result.replacingOccurrences(of: " — ", with: ": ")
        result = result.replacingOccurrences(of: " – ", with: ": ")
        result = result.replacingOccurrences(of: #"\s+-\s+"#, with: ": ", options: .regularExpression)
        result = result.replacingOccurrences(of: "—", with: ": ")
        result = result.replacingOccurrences(of: "–", with: ": ")

        result = result.replacingOccurrences(of: "\r\n", with: " ")
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: "\r", with: " ")

        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
