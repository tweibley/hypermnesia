import SwiftUI
import HypermnesiaKit

/// ⌘K palette: fuzzy-find any memory across every project and jump straight to it.
struct QuickOpenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [MemoryNode] = []
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a memory in any project…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(openHighlighted)
            }
            .padding(12)

            Divider()

            if results.isEmpty {
                Text(query.isEmpty ? "Type to search every project's memories." : "No matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, node in
                                resultRow(node, isHighlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture { model.jump(to: node); dismiss() }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(minHeight: 120, maxHeight: 320)
                    .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
                }
            }
        }
        .frame(width: 520)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, newValue in
            results = model.quickOpenSearch(newValue)
            highlighted = 0
        }
        .onMoveCommand { direction in
            switch direction {
            case .down: highlighted = min(highlighted + 1, max(results.count - 1, 0))
            case .up: highlighted = max(highlighted - 1, 0)
            default: break
            }
        }
        .onExitCommand { dismiss() }
    }

    private func openHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        model.jump(to: results[highlighted])
        dismiss()
    }

    private func resultRow(_ node: MemoryNode, isHighlighted: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: node.type.sfSymbol)
                .foregroundStyle(node.type.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(.callout).lineLimit(1)
                Text(projectDisplayName(node.projectId))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if node.status == .draft {
                Text("draft").font(.caption2).foregroundStyle(.caution)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? Color.brand.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }
}
