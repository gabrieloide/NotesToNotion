import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var geminiKey = ""
    @State private var notionToken = ""
    @State private var databaseID = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                SecureField("API key de Gemini", text: $geminiKey)
                SecureField("Token de integración de Notion", text: $notionToken)
                TextField("ID de la base de datos de Notion", text: $databaseID)
            } footer: {
                Text("Crea una integración interna en notion.so/my-integrations, comparte tu base \"Notas de voz\" con ella (••• → Connections) y copia el ID de 32 caracteres de la URL de la base.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Guardar") {
                    KeychainStore.save(.geminiAPIKey, value: geminiKey)
                    KeychainStore.save(.notionToken, value: notionToken)
                    KeychainStore.save(.notionDatabaseID, value: databaseID)
                    appState.refreshCredentials()
                    saved = true
                }
                .keyboardShortcut(.defaultAction)

                if saved {
                    Text("Guardado ✓")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            geminiKey = KeychainStore.read(.geminiAPIKey) ?? ""
            notionToken = KeychainStore.read(.notionToken) ?? ""
            databaseID = KeychainStore.read(.notionDatabaseID) ?? ""
        }
        .onChange(of: geminiKey) { saved = false }
        .onChange(of: notionToken) { saved = false }
        .onChange(of: databaseID) { saved = false }
    }
}
