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
                SecureField("Gemini API Key", text: $geminiKey)
                SecureField("Notion Integration Token", text: $notionToken)
                TextField("Notion Database ID", text: $databaseID)
            } footer: {
                Text("Create an internal integration at notion.so/my-integrations, share your \"Voice Notes\" database with it (••• → Connections), and copy the 32-character ID from the database's URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Save") {
                    KeychainStore.save(.geminiAPIKey, value: geminiKey)
                    KeychainStore.save(.notionToken, value: notionToken)
                    KeychainStore.save(.notionDatabaseID, value: databaseID)
                    appState.refreshCredentials()
                    saved = true
                }
                .keyboardShortcut(.defaultAction)

                if saved {
                    Text("Saved ✓")
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
