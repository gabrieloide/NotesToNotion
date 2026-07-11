import Foundation

enum AppError: LocalizedError {
    case missingCredentials
    case microphonePermissionDenied
    case recordingFailed(String)
    case geminiRequestFailed(String)
    case geminiMalformedResponse
    case notionDatabaseNotShared
    case notionUnauthorized
    case notionRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Faltan credenciales. Abre Configuración y agrega tu API key de Gemini, el token de Notion y el ID de la base de datos."
        case .microphonePermissionDenied:
            "Acceso al micrófono denegado. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono."
        case .recordingFailed(let detail):
            "Falló la grabación: \(detail)"
        case .geminiRequestFailed(let detail):
            "Gemini falló: \(detail)"
        case .geminiMalformedResponse:
            "Gemini devolvió una respuesta que no se pudo interpretar."
        case .notionDatabaseNotShared:
            "Notion no encontró la base de datos. Verifica el ID y que la base esté compartida con tu integración (••• → Connections)."
        case .notionUnauthorized:
            "El token de Notion es inválido o fue revocado. Revísalo en Configuración."
        case .notionRequestFailed(let detail):
            "Notion rechazó la solicitud: \(detail)"
        }
    }
}
