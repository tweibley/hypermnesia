import SwiftUI
import HypermnesiaKit

// MARK: - List

struct MemoryListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let draftCount = model.draftCount
        let reviewFilter = Binding<Int>(
            get: { model.listShowsDraftsOnly ? 1 : 0 },
            set: { model.setDraftsOnlyFilter($0 == 1) }
        )
        let items = model.listShowsDraftsOnly
            ? model.filteredMemories.filter { $0.status == .draft }
            : model.filteredMemories

        let listSelection = Binding<Set<MemoryNode.ID>>(
            get: { model.selectedMemoryIDs },
            set: { model.setListSelection($0) }
        )
        // In review mode, drafts are grouped by the session that captured them — knowing where a
        // memory came from is most of judging whether it's true.
        let groups = model.listShowsDraftsOnly ? Self.sessionGroups(items) : []
        let orderedItems = model.listShowsDraftsOnly ? groups.flatMap(\.nodes) : items
        let selectedDraftCount = items.filter {
            model.selectedMemoryIDs.contains($0.id) && $0.status == .draft
        }.count

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Review filter", selection: reviewFilter) {
                    Text("All").tag(0)
                    Text("Drafts \(draftCount)").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                if model.listShowsDraftsOnly {
                    Label("Drafts need confirm/dismiss", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.caution)
                }
                // Review progress: where you are in the draft queue as ⌘↩/⌘⌫ advance through it.
                if model.listShowsDraftsOnly, let id = model.selectedMemoryID,
                   let index = orderedItems.firstIndex(where: { $0.id == id }) {
                    Text("\(index + 1) of \(orderedItems.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Batch actions appear once more than one row is selected (⌘-click / ⇧-click).
                if model.selectedMemoryIDs.count > 1 {
                    Text("\(model.selectedMemoryIDs.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if selectedDraftCount > 0 {
                        Button("Confirm \(selectedDraftCount)") { model.confirmSelected() }
                            .controlSize(.small)
                    }
                    Button("Dismiss \(model.selectedMemoryIDs.count)", role: .destructive) {
                        model.dismissSelected()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(model.listShowsDraftsOnly ? Color.caution.opacity(0.12) : .clear)
            Divider()

            if items.isEmpty {
                ContentUnavailableView {
                    Label(model.listShowsDraftsOnly ? "No drafts to review" : "No memories", systemImage: "brain")
                } description: {
                    Text(model.listShowsDraftsOnly
                         ? "You're all caught up. New drafts will appear here."
                         : "Capture new sessions automatically, or start from your existing history.")
                } actions: {
                    if !model.listShowsDraftsOnly {
                        Button(model.isProcessing ? "Processing…" : "Process previous sessions") {
                            model.processPreviousSessions()
                        }
                        .disabled(model.isProcessing)
                        Button("Load sample data") { model.loadSampleData() }
                    }
                }
            } else {
                List(selection: listSelection) {
                    if model.listShowsDraftsOnly {
                        ForEach(groups, id: \.key) { group in
                            Section {
                                ForEach(group.nodes) { node in listRow(node).tag(node.id) }
                            } header: {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.arrow.circlepath")
                                    Text(group.label)
                                    Spacer()
                                    Text("\(group.nodes.count)").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    } else {
                        ForEach(items) { node in listRow(node).tag(node.id) }
                    }
                }
                .listStyle(.inset)
                // Escape clears the selection, which closes the details inspector.
                .onExitCommand { model.setListSelection([]) }
            }
        }
    }
}

extension MemoryListView {
    private func listRow(_ node: MemoryNode) -> some View {
        MemoryRowView(node: node)
            .listRowSeparator(.visible)
            .contextMenu {
                Button("Copy as Markdown") { MemoryDetailView.copyAsMarkdown(node) }
            }
    }

    /// Drafts grouped by the capture session that produced them, newest session first. The label
    /// leads with the branch when known — "what was I doing?" beats a session id.
    static func sessionGroups(_ drafts: [MemoryNode]) -> [(key: String, label: String, nodes: [MemoryNode])] {
        let grouped = Dictionary(grouping: drafts) { $0.conversationId ?? "no-session" }
        return grouped
            .map { key, nodes in
                let newest = nodes.map(\.createdAt).max() ?? .distantPast
                var parts: [String] = []
                if let branch = nodes.compactMap(\.branch).first { parts.append("⎇ \(branch)") }
                parts.append(newest.formatted(date: .abbreviated, time: .shortened))
                let label = key == "no-session"
                    ? "Earlier · \(newest.formatted(date: .abbreviated, time: .omitted))"
                    : parts.joined(separator: " · ")
                return (key: key, label: label, nodes: nodes.sorted { $0.createdAt < $1.createdAt })
            }
            .sorted { ($0.nodes.map(\.createdAt).max() ?? .distantPast) > ($1.nodes.map(\.createdAt).max() ?? .distantPast) }
    }
}

struct MemoryRowView: View {
    let node: MemoryNode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(node.type.color.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: node.type.sfSymbol)
                    .foregroundStyle(node.type.color)
                    .font(.system(size: 15, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.title).font(.headline).lineLimit(1)
                    if node.status == .draft {
                        Label("Draft", systemImage: "exclamationmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.caution.opacity(0.2)))
                            .foregroundStyle(.caution)
                    }
                }
                Text(node.summary)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)

                HStack(spacing: 8) {
                    if node.status == .draft {
                        Text("Needs review")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.caution)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(node.type.displayName)
                        .font(.caption2).foregroundStyle(node.type.color)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(node.daysSinceValidation())d old")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !node.data.relatedFiles.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Label("\(node.data.relatedFiles.count)", systemImage: "doc")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)
            DecayBadge(node: node)
        }
        .padding(.vertical, 4)
    }
}

struct DecayBadge: View {
    let node: MemoryNode

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(node.decayLevel.color).frame(width: 7, height: 7)
                Text(node.decayLevel.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(node.decayLevel.color)
            }
            Text("\(Int(node.confidence * 100))%")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - Detail (inspector)

struct MemoryDetailView: View {
    @Environment(AppModel.self) private var model
    let node: MemoryNode

    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editSummary = ""
    @State private var editData: MemoryData?
    @State private var repoPath: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if isEditing {
                    TextField("Summary", text: $editSummary, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...6)
                } else if !node.summary.isEmpty {
                    Text(node.summary).font(.body).foregroundStyle(.secondary)
                }
                revisionComparison
                Divider()
                if isEditing {
                    payloadEditor
                } else {
                    payload
                }
                if let quote = node.sourceQuote, !quote.isEmpty {
                    Divider()
                    section("Source") {
                        Text("“\(quote)”").font(.callout).italic().foregroundStyle(.secondary)
                    }
                }
                if node.supersedesId != nil || node.supersededById != nil {
                    Divider()
                    revisions
                }
                Divider()
                ConfidenceCardView(vm: MemoryAnalytics.confidenceBreakdown(for: node))
                if let injectedAt = model.lastInjectedAt(memoryId: node.id, projectId: node.projectId) {
                    Label("Last injected into a session \(injectedAt.formatted(.relative(presentation: .named)))",
                          systemImage: "drop.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                MemoryTimelineView(vm: MemoryAnalytics.timeline(for: node))
                if hasProvenance {
                    Divider()
                    provenance
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .onChange(of: node.id) { _, _ in isEditing = false }
        // Resolving a local repo path can scan many transcripts; do it once per project off-main.
        .task(id: node.projectId) {
            repoPath = await Task.detached(priority: .utility) {
                MemoryAuditor.repoPath(forProjectId: node.projectId)
            }.value
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: node.type.sfSymbol)
                .font(.title2).foregroundStyle(node.type.color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Title", text: $editTitle).textFieldStyle(.roundedBorder).font(.title3)
                } else {
                    Text(node.title).font(.title3).bold()
                }
                HStack(spacing: 6) {
                    Text(node.type.displayName).foregroundStyle(node.type.color)
                    if node.status == .draft {
                        Label("Draft - needs review", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.caution)
                    }
                }
                .font(.caption)
            }
            Spacer()
            DecayBadge(node: node)
            Button { model.selectedMemoryID = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close details (esc)")
        }
    }

    @ViewBuilder private var payload: some View {
        switch node.data {
        case .decision(let d):
            section("Decision") {
                field("Problem", d.problem)
                field("Chosen", d.chosen)
                list("Alternatives", d.alternatives)
                field("Rationale", d.rationale)
                list("Revisit when", d.revisitTriggers)
                files(d.relatedFiles)
            }
        case .convention(let c):
            section("Convention") {
                field("Trigger", c.trigger)
                field("Rule", c.rule)
                ForEach(Array(c.examples.enumerated()), id: \.offset) { _, ex in
                    if let bad = ex.bad { labeled("✗ Bad", bad, .critical) }
                    if let good = ex.good { labeled("✓ Good", good, .positive) }
                }
                files(c.relatedFiles)
            }
        case .intent(let i):
            section("Intent") {
                field("Goal", i.goal)
                ForEach(Array(i.behaviors.enumerated()), id: \.offset) { _, b in
                    let line = [b.given.map { "Given \($0)" }, b.when.map { "when \($0)" }, b.then.map { "then \($0)" }]
                        .compactMap { $0 }.joined(separator: ", ")
                    if !line.isEmpty { labeled("Behavior", line) }
                }
                list("Constraints", i.constraints)
                files(i.relatedFiles)
            }
        case .fact(let f):
            section("Fact") {
                field("Category", f.category)
                field("Key", f.key)
                field("Value", f.value)
            }
        case .concern(let c):
            section("Concern") {
                field("Issue", c.issue)
                field("Severity", c.severity)
                field("Affected area", c.affectedArea)
                files(c.relatedFiles)
            }
        case .backlog(let b):
            section("Backlog") {
                field("Idea", b.idea)
                field("Priority", b.priority)
                field("Trigger", b.trigger)
            }
        case .codeRef(let r):
            section("Code Reference") {
                fileLink(r.filePath, range: r.range)
                field("Symbol", r.symbolName)
                field("Range", r.range)
                if let s = r.snippet { labeled("Snippet", s) }
            }
        }
    }

    /// Confidence, age, and history now live in the ConfidenceCard + Timeline; this section is just
    /// the capture provenance, shown only when at least one field is present.
    private var hasProvenance: Bool {
        node.branch != nil || node.commitSha != nil || node.conversationId != nil
    }

    /// For a draft that revises an existing memory: show exactly what confirming will retire,
    /// side by side, so the scariest triage action is an informed one.
    @ViewBuilder private var revisionComparison: some View {
        if node.status == .draft, let oldId = node.supersedesId,
           let old = model.memory(id: oldId), !old.isSuperseded, !old.isDeleted {
            VStack(alignment: .leading, spacing: 8) {
                Label("Revises an existing memory", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.caution)
                comparisonRow(tag: "NOW", tint: .secondary, title: old.title, detail: old.summary)
                comparisonRow(tag: "NEW", tint: .green, title: node.title, detail: node.summary)
                Text("Confirming retires the current memory — it stops being injected. Dismissing this draft leaves it unchanged.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.caution.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.caution.opacity(0.35)))
        }
    }

    private func comparisonRow(tag: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(tag)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(tint)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }

    /// The supersede chain, navigable in both directions — a revision names what it replaced, an
    /// obsolete memory names what replaced it.
    private var revisions: some View {
        section("Revisions") {
            if let oldId = node.supersedesId {
                revisionLink(node.status == .draft ? "Will supersede (on confirm)" : "Supersedes", id: oldId)
            }
            if let newerId = node.supersededById {
                revisionLink("Superseded by", id: newerId)
            }
        }
    }

    @ViewBuilder private func revisionLink(_ label: String, id: String) -> some View {
        if let target = model.memory(id: id) {
            Button { model.selectedMemoryID = target.id } label: {
                HStack(spacing: 6) {
                    Text(label).foregroundStyle(.secondary)
                    Image(systemName: target.type.sfSymbol).foregroundStyle(target.type.color)
                    Text(target.title).underline()
                }
                .font(.callout)
            }
            .buttonStyle(.plain)
            .help("Show this memory")
        } else {
            meta(label, "\(id.prefix(8))… (no longer present)")
        }
    }

    private var provenance: some View {
        section("Provenance") {
            if let branch = node.branch { meta("Branch", branch) }
            if let sha = node.commitSha {
                if let commitURL = CodeLinks.githubCommitURL(projectId: node.projectId, commitSha: sha) {
                    HStack {
                        Text("Commit").foregroundStyle(.secondary)
                        Spacer()
                        Button(String(sha.prefix(8))) { NSWorkspace.shared.open(commitURL) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.brand)
                            .help("Open this commit on GitHub")
                    }
                    .font(.caption)
                } else {
                    meta("Commit", String(sha.prefix(8)))
                }
            }
            if let convo = node.conversationId { meta("Session", String(convo.prefix(8))) }
        }
    }

    private var actionBar: some View {
        HStack {
            if isEditing {
                Button("Save") {
                    model.updateText(node, title: editTitle, summary: editSummary,
                                     data: editData ?? node.data)
                    isEditing = false
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { isEditing = false }.keyboardShortcut(.cancelAction)
            } else if node.status == .draft {
                Button { model.confirmAndAdvance(node) } label: { Label("Confirm", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .help("Confirm and go to next draft (⌘↩)")
                Button(role: .destructive) { model.dismissAndAdvance(node) } label: { Label("Dismiss", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Dismiss and go to next draft (⌘⌫)")
                Button { beginEdit() } label: { Image(systemName: "pencil") }.help("Edit")
            } else {
                if node.isSuperseded {
                    Button { model.restore(node) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                        .help("Bring this memory back — it stays restored; the sweep won't re-retire it")
                }
                Button { model.revalidate(node) } label: { Label("Revalidate", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                Button { beginEdit() } label: { Image(systemName: "pencil") }.help("Edit")
                Button(role: .destructive) { model.delete(node) } label: { Label("Delete", systemImage: "trash") }
            }
            Spacer()
            if !isEditing {
                Button { Self.copyAsMarkdown(node) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy as Markdown (for a PR, issue, or CLAUDE.md)")
            }
        }
        .padding(12)
        .background(.bar)
    }

    static func copyAsMarkdown(_ node: MemoryNode) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MemoryMarkdown.render(node), forType: .string)
    }

    private func beginEdit() {
        editTitle = node.title
        editSummary = node.summary
        editData = node.data
        isEditing = true
    }

    // MARK: Payload editing

    /// Binding into one String field of the payload under edit. The generic dance exists because
    /// `MemoryData` is an enum — each case's struct is extracted, mutated, and re-embedded.
    private func payloadField<P>(
        _ keyPath: WritableKeyPath<P, String>,
        extract: @escaping (MemoryData) -> P?,
        embed: @escaping (P) -> MemoryData
    ) -> Binding<String> {
        Binding(
            get: { extract(editData ?? node.data)?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var payload = extract(editData ?? node.data) else { return }
                payload[keyPath: keyPath] = newValue
                editData = embed(payload)
            }
        )
    }

    /// Same, for optional String fields — an emptied field stores nil, not "".
    private func payloadField<P>(
        _ keyPath: WritableKeyPath<P, String?>,
        extract: @escaping (MemoryData) -> P?,
        embed: @escaping (P) -> MemoryData
    ) -> Binding<String> {
        Binding(
            get: { extract(editData ?? node.data)?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var payload = extract(editData ?? node.data) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                payload[keyPath: keyPath] = trimmed.isEmpty ? nil : newValue
                editData = embed(payload)
            }
        )
    }

    @ViewBuilder private var payloadEditor: some View {
        section("Details") {
            switch editData ?? node.data {
            case .decision:
                editorField("Chosen", payloadField(\DecisionData.chosen, extract: \.decisionData, embed: MemoryData.decision))
                editorField("Rationale", payloadField(\DecisionData.rationale, extract: \.decisionData, embed: MemoryData.decision))
            case .convention:
                editorField("Rule", payloadField(\ConventionData.rule, extract: \.conventionData, embed: MemoryData.convention))
                editorField("Applies when", payloadField(\ConventionData.appliesWhen, extract: \.conventionData, embed: MemoryData.convention))
                editorField("Does NOT apply to", payloadField(\ConventionData.excludesWhen, extract: \.conventionData, embed: MemoryData.convention))
            case .intent:
                editorField("Goal", payloadField(\IntentData.goal, extract: \.intentData, embed: MemoryData.intent))
            case .fact:
                editorField("Category", payloadField(\FactData.category, extract: \.factData, embed: MemoryData.fact))
                editorField("Key", payloadField(\FactData.key, extract: \.factData, embed: MemoryData.fact))
                editorField("Value", payloadField(\FactData.value, extract: \.factData, embed: MemoryData.fact))
            case .concern:
                editorField("Issue", payloadField(\ConcernData.issue, extract: \.concernData, embed: MemoryData.concern))
                editorField("Severity", payloadField(\ConcernData.severity, extract: \.concernData, embed: MemoryData.concern))
            case .backlog:
                editorField("Idea", payloadField(\BacklogData.idea, extract: \.backlogData, embed: MemoryData.backlog))
                editorField("Priority", payloadField(\BacklogData.priority, extract: \.backlogData, embed: MemoryData.backlog))
            case .codeRef:
                editorField("File path", payloadField(\CodeRefData.filePath, extract: \.codeRefData, embed: MemoryData.codeRef))
                editorField("Symbol", payloadField(\CodeRefData.symbolName, extract: \.codeRefData, embed: MemoryData.codeRef))
            }
        }
    }

    private func editorField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .labelsHidden()
        }
    }

    // MARK: builders

    @ViewBuilder private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2).bold().foregroundStyle(.tertiary)
            content()
        }
    }
    @ViewBuilder private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { labeled(label, value) }
    }
    @ViewBuilder private func labeled(_ label: String, _ value: String, _ tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).foregroundStyle(tint).textSelection(.enabled)
        }
    }
    @ViewBuilder private func list(_ label: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                ForEach(items, id: \.self) { Text("• \($0)").font(.callout) }
            }
        }
    }
    @ViewBuilder private func files(_ paths: [String]) -> some View {
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Files").font(.caption).foregroundStyle(.secondary)
                ForEach(paths, id: \.self) { path in
                    fileLink(path)
                }
            }
        }
    }

    /// A related-file row that goes somewhere: click opens the file locally when the repo is on
    /// this machine; the context menu adds Finder reveal and a GitHub permalink pinned to the
    /// memory's capture commit. Falls back to a plain label when neither destination resolves.
    @ViewBuilder private func fileLink(_ path: String, range: String? = nil) -> some View {
        let localURL = CodeLinks.localFileURL(
            repoPath: repoPath, path: path)
        let githubURL = CodeLinks.githubFileURL(
            projectId: node.projectId, path: path,
            commitSha: node.commitSha, branch: node.branch, range: range)
        if localURL == nil && githubURL == nil {
            Label(path, systemImage: "doc").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } else {
            Button {
                if let localURL { NSWorkspace.shared.open(localURL) }
                else if let githubURL { NSWorkspace.shared.open(githubURL) }
            } label: {
                Label(path, systemImage: localURL != nil ? "doc.badge.arrow.up" : "doc")
                    .font(.caption)
                    .foregroundStyle(Color.brand)
            }
            .buttonStyle(.plain)
            .help(localURL != nil ? "Open in your editor" : "Open on GitHub")
            .contextMenu {
                if let localURL {
                    Button("Open") { NSWorkspace.shared.open(localURL) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([localURL]) }
                }
                if let githubURL {
                    Button("Open on GitHub") { NSWorkspace.shared.open(githubURL) }
                    Button("Copy GitHub Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(githubURL.absoluteString, forType: .string)
                    }
                }
            }
        }
    }
    private func meta(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }
            .font(.caption)
    }
}

// MARK: - Health

struct HealthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let groups = model.healthGroups
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.runAudit() } label: { Label("Reality check", systemImage: "checkmark.shield") }
                    .help("Fast, local: flag memories whose related files are missing or changed")
                Button { model.runAudit(deep: true) } label: { Label("Deep check", systemImage: "brain") }
                    .help("Also ask the model whether each memory still holds (slower; uses classifier calls)")
                    .disabled(model.isProcessing)
                    .help("Flag memories whose related files are missing or changed since capture")
                if model.isProcessing { ProgressView().controlSize(.small) }
                if let status = model.processingStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            Divider()
            content(groups, selection: $model.selectedMemoryID)
        }
    }

    @ViewBuilder
    private func content(_ groups: [(level: DecayLevel, nodes: [MemoryNode])],
                         selection: Binding<MemoryNode.ID?>) -> some View {
        if groups.isEmpty {
            ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal",
                                   description: Text("Confirmed memories grouped by freshness will appear here."))
        } else {
            List(selection: selection) {
                ForEach(groups, id: \.level) { group in
                    Section {
                        ForEach(group.nodes) { node in
                            HStack {
                                MemoryRowView(node: node)
                                if node.needsRevalidation {
                                    Button("Revalidate") { model.revalidate(node) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                            .tag(node.id)
                        }
                    } header: {
                        HStack {
                            Image(systemName: group.level.sfSymbol).foregroundStyle(group.level.color)
                            Text(group.level.displayName)
                            Spacer()
                            Text("\(group.nodes.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            // Escape clears the selection, which closes the details inspector.
            .onExitCommand { model.selectedMemoryID = nil }
        }
    }
}
