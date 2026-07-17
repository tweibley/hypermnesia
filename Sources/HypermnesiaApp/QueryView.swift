import SwiftUI
import HypermnesiaKit

/// Recently asked questions, kept small and deduped (most recent first).
enum QuestionHistory {
    private static let key = "Hypermnesia.askHistory"
    private static let maxCount = 8

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ question: String) -> [String] {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }
        var history = load().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        history.insert(trimmed, at: 0)
        history = Array(history.prefix(maxCount))
        UserDefaults.standard.set(history, forKey: key)
        return history
    }
}

/// Natural-language query over the selected project's memories.
struct MemoryQuerySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var history = QuestionHistory.load()

    private var projectName: String { model.selectedProject.map(projectDisplayName) ?? "this project" }
    private var canAsk: Bool { !question.trimmingCharacters(in: .whitespaces).isEmpty && !model.isAsking }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color.brand)
                Text("Ask your memory").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            HStack {
                TextField("Ask about \(projectName)…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canAsk { ask() } }
                Button("Ask") { ask() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAsk)
            }

            Divider()

            Group {
                if model.isAsking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let answer = model.answer {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                Text(answer.answer)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(answer.answer, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("Copy the answer")
                            }
                            if !answer.sources.isEmpty {
                                Divider()
                                Text("SOURCES").font(.caption2).bold().foregroundStyle(.tertiary)
                                ForEach(answer.sources.prefix(8)) { node in
                                    Button {
                                        model.selectedMemoryID = node.id
                                        dismiss()
                                    } label: {
                                        MemoryRowView(node: node)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 14) {
                        ContentUnavailableView("Ask anything about \(projectName)",
                                               systemImage: "sparkles",
                                               description: Text("I'll answer from this project's captured memories."))
                        if !history.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("RECENT").font(.caption2).bold().foregroundStyle(.tertiary)
                                ForEach(history.prefix(5), id: \.self) { recent in
                                    Button {
                                        question = recent
                                        ask()
                                    } label: {
                                        Label(recent, systemImage: "clock.arrow.circlepath")
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: 420)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 560, height: 500)
    }

    private func ask() {
        guard canAsk else { return }
        history = QuestionHistory.record(question)
        model.ask(question)
    }
}
