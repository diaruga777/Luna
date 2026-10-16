import SwiftUI
import LunaVaultBEP

@MainActor final class CompanionPresentation: ObservableObject {
    struct Snapshot: Equatable {
        var code: String?
        var status = "Starting…"
        var paired = false
        var clients: [LunaMacClient] = []
        var folder = ""
        var accessIssue: String?
    }
    @Published var snapshot = Snapshot()
}

struct CompanionView: View {
    @ObservedObject var model: CompanionPresentation
    var copyCode: () -> Void
    var chooseFolder: () -> Void
    var revealFolder: () -> Void
    var forgetConnection: () -> Void
    var openPrivacy: () -> Void
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var state: CompanionPresentation.Snapshot { model.snapshot }
    private var sharesFolder: Bool { state.clients.contains(.vault) || state.clients.contains(.music) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(Host.current().localizedName ?? "This Mac")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(state.accessIssue == nil ? state.status : "Folder Access Needed")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 8)

            Form {
                if !state.paired {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Paste the connection code in Luna on your iPhone or iPad.")
                                .foregroundStyle(.secondary)
                            copyButton
                        }
                        .padding(.vertical, 4)
                    } header: { Text("Connect to Luna") }
                }
                if let issue = state.accessIssue {
                    Section("Folder Access") {
                        Text(issue).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Open Privacy & Security…", action: openPrivacy)
                    }
                }
                if !state.clients.isEmpty {
                    Section("Apps") {
                        ForEach(state.clients, id: \.rawValue) { client in
                            Label(name(client), systemImage: symbol(client))
                                .padding(.vertical, 2)
                        }
                    }
                }
                if sharesFolder {
                    Section("Shared Folder") {
                        LabeledContent {
                            Button(action: revealFolder) {
                                Text((state.folder as NSString).lastPathComponent)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .buttonStyle(.link)
                            .help(state.folder)
                            .accessibilityLabel("Open shared folder in Finder")
                        } label: { Label("Folder", systemImage: "folder") }
                        Button("Choose Folder…", action: chooseFolder)
                    }
                }
                if state.paired {
                    Section("Connection") {
                        DisclosureGroup("Connection Code") {
                            copyButton.padding(.vertical, 4)
                        }
                        Button("Forget Connection…", role: .destructive, action: forgetConnection)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var copyButton: some View {
        Button {
            copyCode()
            withAnimation(reduceMotion ? nil : .smooth) { copied = true }
        } label: {
            Label(copied ? "Copied" : "Copy Connection Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(state.code == nil)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .smooth) { copied = false }
        }
    }

    private func name(_ client: LunaMacClient) -> String {
        switch client { case .vault: "Luna Vault"; case .music: "Luna Music"; case .code: "Luna Code" }
    }
    private func symbol(_ client: LunaMacClient) -> String {
        switch client { case .vault: "externaldrive"; case .music: "music.note"; case .code: "curlybraces" }
    }
}
