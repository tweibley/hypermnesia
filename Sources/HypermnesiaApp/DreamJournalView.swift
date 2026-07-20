import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HypermnesiaKit

/// The Dream Journal: nights list + evidence-first cards. Not a seventh browse mode — a panel
/// reached from the notch chip, the digest notification, the Feed, and the toolbar moon.
struct DreamJournalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [DreamJournalEntry] = []
    @State private var selectedEntryId: String?
    @State private var statusLine: String?
    /// A proposal awaiting the update-with-diff confirmation (never clobber without it).
    @State private var pendingUpdate: PendingUpdate?
    @State private var editing: EditingProposal?

    struct PendingUpdate: Identifiable {
        let id = UUID()
        let entryId: String
        let proposal: DreamSkillProposal
        let currentMarkdown: String
        /// The scope that produced this update — carried from the install/update call site so the
        /// diff shown and the file rewritten are always the same on disk (never re-derived from config).
        let scope: String
        /// Absolute path of the skill directory about to be rewritten, shown in the diff header.
        let resolvedPath: String?
        var diff: (added: Int, removed: Int) {
            SkillInstaller.diffSummary(old: currentMarkdown, new: proposal.markdown)
        }
    }

    struct EditingProposal: Identifiable {
        let id = UUID()
        let entryId: String
        var proposal: DreamSkillProposal
    }

    private var selectedEntry: DreamJournalEntry? {
        entries.first { $0.id == selectedEntryId } ?? entries.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                nightsList
                    .frame(minWidth: 250, idealWidth: 270, maxWidth: 330)
                detail
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 880, height: 620)
        .onAppear {
            reload()
            model.markDreamsRead()   // opening the journal IS reading it — chip and badge clear
        }
        .sheet(item: $pendingUpdate) { update in
            updateDiffSheet(update)
        }
        .sheet(item: $editing) { editing in
            editSheet(editing)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill").foregroundStyle(Color.brand)
            Text("Dream Journal").font(.title3.bold())
            if let project = selectedEntry?.projectId {
                nightStrip(projectId: project)
            }
            Spacer()
            if let project = model.selectedProject ?? selectedEntry?.projectId {
                Button(model.isProcessing ? "Dreaming…" : "Dream now") {
                    model.dreamNow(project: project)
                    // Results land on the next reload tick.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { reload() }
                }
                .disabled(model.isProcessing)
                .help("Run tonight's dream for \(projectDisplayName(project)) right now (1 classifier call)")
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The last 7 nights, honestly: dreamed (filled), quiet (outline), skipped (no run — dash).
    private func nightStrip(projectId: String) -> some View {
        let byNight = Dictionary(
            entries.filter { $0.projectId == projectId }.map { ($0.night, $0.outcome) },
            uniquingKeysWith: { a, _ in a })
        let calendar = Calendar.current
        let nights = (0..<7).reversed().compactMap { offset -> (night: String, outcome: DreamOutcome?)? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let key = DreamScheduler.nightKey(for: day)
            return (key, byNight[key])
        }
        return HStack(spacing: 4) {
            ForEach(nights, id: \.night) { item in
                Group {
                    switch item.outcome {
                    case .dreamed: Image(systemName: "moon.fill").foregroundStyle(Color.brand)
                    case .quiet: Image(systemName: "moon").foregroundStyle(.secondary)
                    case nil: Image(systemName: "minus").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .help("\(item.night): \(item.outcome.map { $0 == .dreamed ? "dreamed" : "quiet night" } ?? "skipped")")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }

    // MARK: - Nights list

    private var nightsList: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No dreams yet", systemImage: "moon.zzz",
                    description: Text("Enable Dreams in Settings, or run `hypermnesia dream` — after an idle night you'll find the journal here."))
            } else {
                List(selection: Binding(
                    get: { selectedEntryId ?? entries.first?.id },
                    set: { selectedEntryId = $0 }
                )) {
                    ForEach(entries) { entry in
                        nightRow(entry).tag(entry.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func nightRow(_ entry: DreamJournalEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.outcome == .dreamed ? "moon.fill" : "moon")
                .foregroundStyle(entry.outcome == .dreamed ? Color.brand : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.night).font(.callout.weight(.medium)).monospacedDigit()
                Text(projectDisplayName(entry.projectId))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if entry.outcome == .dreamed {
                let n = entry.payload.epiphanies.count
                Text("\(n)")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.brand.opacity(0.18), in: Capsule())
            } else {
                Text("quiet").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if let entry = selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        entryHeader(entry)
                        if entry.outcome == .quiet {
                            quietBody(entry)
                        } else {
                            ForEach(entry.payload.epiphanies) { epiphany in
                                epiphanyCard(epiphany, entry: entry)
                            }
                            draftsSection(entry)
                            skillsSection(entry)
                        }
                        reportBacksSection(entry)
                        statsFooter(entry)
                        if let statusLine {
                            Label(statusLine, systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Select a night", systemImage: "moon.stars")
            }
        }
    }

    private func entryHeader(_ entry: DreamJournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.outcome == .dreamed ? "Dreamed · \(entry.night)" : "Quiet night · \(entry.night)")
                    .font(.title3.bold())
                Spacer()
                if entry.outcome == .dreamed {
                    Button {
                        model.remEntry = entry
                        dismiss()
                    } label: {
                        Label("Replay", systemImage: "sparkles.tv")
                    }
                    .help("Play the 12-second REM replay")
                    Button {
                        saveShareCard(entry)
                    } label: {
                        Label("Share card", systemImage: "square.and.arrow.up")
                    }
                    .help("Save a share image — corpus stats only, never memory content")
                }
            }
            Text(projectDisplayName(entry.projectId)).font(.callout).foregroundStyle(.secondary)
            if let narrative = entry.narrative {
                Text(narrative)
                    .font(.body)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.brand.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func quietBody(_ entry: DreamJournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing cleared the quality gate — no dream is better than a bad dream.")
                .foregroundStyle(.secondary)
            if let note = entry.payload.note {
                Text(note).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Epiphany cards (evidence first)

    private func epiphanyCard(_ epiphany: DreamEpiphany, entry: DreamJournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(kindLabel(epiphany.kind))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(kindColor(epiphany.kind).opacity(0.16), in: Capsule())
                    .foregroundStyle(kindColor(epiphany.kind))
                Text(epiphany.title).font(.headline)
                Spacer()
            }
            Text(epiphany.insight)

            // Receipts: cited memories by title, quoted transcript lines with session ids.
            if epiphany.kind == .contradiction, epiphany.memoryIds.count == 2 {
                contradictionReceipts(epiphany, entry: entry)
            } else if !epiphany.memoryIds.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(epiphany.memoryIds, id: \.self) { id in
                        if let memory = model.memory(id: id) {
                            Button {
                                model.jump(to: memory)
                                dismiss()
                            } label: {
                                Label(memory.title, systemImage: memory.type.sfSymbol)
                                    .font(.caption)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            ForEach(Array(epiphany.quotes.enumerated()), id: \.offset) { _, quote in
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(kindColor(epiphany.kind).opacity(0.5)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("“\(quote.text)”").font(.callout.italic())
                        Text("session \(quote.sessionId.prefix(8))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The two disagreeing memories side by side, each with a one-tap "keep this" that retires
    /// the other (via the same supersede link the conflict sweep writes).
    private func contradictionReceipts(_ epiphany: DreamEpiphany, entry: DreamJournalEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(epiphany.memoryIds, id: \.self) { id in
                if let memory = model.memory(id: id) {
                    let otherId = epiphany.memoryIds.first { $0 != id } ?? id
                    VStack(alignment: .leading, spacing: 6) {
                        Label(memory.title, systemImage: memory.type.sfSymbol)
                            .font(.callout.weight(.medium))
                        Text(memory.summary).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        if memory.isSuperseded {
                            Text("Superseded").font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            Button("Keep this") {
                                supersede(keep: id, retire: otherId)
                            }
                            .controlSize(.small)
                            .disabled(model.memory(id: otherId)?.isSuperseded == true)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                }
            }
        }
    }

    // MARK: - Dream drafts (through the normal triage semantics)

    private func draftsSection(_ entry: DreamJournalEntry) -> some View {
        let nodes = entry.payload.proposedMemoryIds.compactMap { model.memory(id: $0) }
        return Group {
            if !nodes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Proposed memories").font(.headline)
                    ForEach(nodes) { node in
                        HStack(spacing: 8) {
                            Image(systemName: node.type.sfSymbol).foregroundStyle(node.type.color)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.title).font(.callout)
                                Text(node.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if node.isDeleted {
                                Text("Dismissed").font(.caption).foregroundStyle(.tertiary)
                            } else if node.status == .confirmed {
                                Label("Confirmed", systemImage: "checkmark")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Confirm") { model.confirm(node) }.controlSize(.small)
                                Button("Dismiss") { model.delete(node) }
                                    .controlSize(.small).foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - Skill cards (lifecycle, not a click)

    private func skillsSection(_ entry: DreamJournalEntry) -> some View {
        Group {
            if !entry.payload.skillProposals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Proposed skills").font(.headline)
                    ForEach(entry.payload.skillProposals) { proposal in
                        skillCard(proposal, entry: entry)
                    }
                }
            }
        }
    }

    private func skillCard(_ proposal: DreamSkillProposal, entry: DreamJournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(Color.brand)
                Text(proposal.slug).font(.callout.weight(.semibold)).monospaced()
                if proposal.updatesExisting {
                    Text("update").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                }
                Spacer()
                skillActions(proposal, entry: entry)
            }
            if !proposal.description.isEmpty {
                Text(proposal.description).font(.callout)
            }
            if !proposal.rationale.isEmpty {
                Text(proposal.rationale).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(proposal.evidence.prefix(3).enumerated()), id: \.offset) { _, quote in
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(Color.brand.opacity(0.5)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("“\(quote.text)”").font(.caption.italic())
                        Text("session \(quote.sessionId.prefix(8))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brand.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.brand.opacity(0.2)))
    }

    @ViewBuilder
    private func skillActions(_ proposal: DreamSkillProposal, entry: DreamJournalEntry) -> some View {
        switch proposal.state {
        case .proposed:
            Button("Edit…") {
                editing = EditingProposal(entryId: entry.id, proposal: proposal)
            }
            .controlSize(.small)
            if proposal.updatesExisting {
                Button("Update…") {
                    beginUpdate(proposal, entry: entry,
                                scope: AppConfigStore.loadBestEffort().dreamSkillTarget)
                }
                    .controlSize(.small).buttonStyle(.borderedProminent)
            } else {
                Menu("Install") {
                    Button("Into this project (.claude/skills)") {
                        install(proposal, entry: entry, scope: "project")
                    }
                    Button("For every project (~/.claude/skills)") {
                        install(proposal, entry: entry, scope: "user")
                    }
                } primaryAction: {
                    install(proposal, entry: entry,
                            scope: AppConfigStore.loadBestEffort().dreamSkillTarget)
                }
                .controlSize(.small)
                .fixedSize()
            }
            Button("Dismiss") { setSkillState(proposal, entry: entry, state: .dismissed) }
                .controlSize(.small).foregroundStyle(.secondary)
        case .installed:
            Label("Installed", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
            Button("Uninstall") { uninstall(proposal, entry: entry) }
                .controlSize(.small).foregroundStyle(.red)
        case .dismissed:
            Text("Dismissed").font(.caption).foregroundStyle(.tertiary)
        case .uninstalled:
            Text("Uninstalled").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Report-backs & stats

    private func reportBacksSection(_ entry: DreamJournalEntry) -> some View {
        Group {
            if !entry.payload.reportBacks.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Report-backs").font(.headline)
                    ForEach(Array(entry.payload.reportBacks.enumerated()), id: \.offset) { _, back in
                        Label(back.detail, systemImage: back.kind == .skill ? "wand.and.stars" : "brain")
                            .font(.callout)
                    }
                }
            }
        }
    }

    private func statsFooter(_ entry: DreamJournalEntry) -> some View {
        let stats = entry.payload.stats
        let cost = stats.estCostUSD.map { String(format: "~$%.3f", $0) } ?? "—"
        return Text("\(stats.sessionsScanned) session\(stats.sessionsScanned == 1 ? "" : "s") scanned · "
             + "\(stats.memoriesConsidered) memories considered · \(stats.calls) call\(stats.calls == 1 ? "" : "s") "
             + "(\(stats.classifier), \(cost))")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Sheets

    private func updateDiffSheet(_ update: PendingUpdate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update \(update.proposal.slug)?").font(.title3.bold())
            let diff = update.diff
            Text("This rewrites the existing skill: +\(diff.added) line\(diff.added == 1 ? "" : "s"), "
                 + "−\(diff.removed) line\(diff.removed == 1 ? "" : "s"). Nothing is written until you confirm.")
                .font(.callout).foregroundStyle(.secondary)
            if let path = update.resolvedPath {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .top, spacing: 10) {
                markdownPane(title: "Current", text: update.currentMarkdown)
                markdownPane(title: "Proposed", text: update.proposal.markdown)
            }
            HStack {
                Spacer()
                Button("Cancel") { pendingUpdate = nil }
                Button("Update skill") { confirmUpdate(update) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 720, height: 480)
    }

    private func markdownPane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity)
    }

    private func editSheet(_ editing: EditingProposal) -> some View {
        EditSkillSheet(editing: editing) { updated in
            mutateEntry(updated.entryId) { entry in
                entry.payload.skillProposals = entry.payload.skillProposals.map {
                    $0.id == updated.proposal.id ? updated.proposal : $0
                }
            }
            self.editing = nil
        } onCancel: {
            self.editing = nil
        }
    }

    // MARK: - Actions

    private func reload() {
        guard let store = model.store else { return }
        entries = (try? store.dreamEntries(limit: 90)) ?? []
        if selectedEntryId == nil { selectedEntryId = entries.first?.id }
    }

    private func supersede(keep: String, retire: String) {
        guard let store = model.store else { return }
        do {
            _ = try DreamActions.supersede(keep: keep, retire: retire, store: store)
            statusLine = "Kept the newer memory; the other is retired (Restore is in its inspector)."
            model.reloadMemories()
        } catch {
            statusLine = "Couldn't supersede: \(error.localizedDescription)"
        }
    }

    private func projectPath(for entry: DreamJournalEntry) -> String? {
        MemoryAuditor.repoPath(forProjectId: entry.projectId)
    }

    private func install(_ proposal: DreamSkillProposal, entry: DreamJournalEntry, scope: String) {
        let path = projectPath(for: entry)
        if scope == "project", path == nil {
            statusLine = "Couldn't find this project's repo path — install for every project instead."
            return
        }
        do {
            let record = try SkillInstaller.install(
                proposal, scope: scope, projectPath: path, projectId: entry.projectId,
                entryId: entry.id)
            setSkillState(proposal, entry: entry, state: .installed)
            statusLine = "Installed \(record.slug) v\(record.version)"
                + (record.mirrorPaths.isEmpty ? "." : " (+\(record.mirrorPaths.count) mirror\(record.mirrorPaths.count == 1 ? "" : "s")).")
        } catch SkillInstallError.existsUnmanaged {
            // A skill Hypermnesia didn't install already sits there → explicit diff-confirm flow.
            // Carry the SAME scope that blocked the install, so the diff shown and the file
            // rewritten are the foreign skill the user actually chose — never a config default.
            beginUpdate(proposal, entry: entry, scope: scope)
        } catch {
            statusLine = "Install failed: \(error.localizedDescription)"
        }
    }

    private func beginUpdate(_ proposal: DreamSkillProposal, entry: DreamJournalEntry, scope: String) {
        let path = projectPath(for: entry)
        let managed = SkillInstaller.loadManifest().skills.first { $0.slug == proposal.slug }
        // The diff must read the SAME file the update will write. For a Hypermnesia-managed skill
        // that's the manifest's recorded primary path; for a foreign skill it's the primary dir of
        // the caller's scope — never a config default.
        let resolvedPath: String? = managed.map(\.primaryPath)
            ?? SkillInstaller.targets(scope: scope, projectPath: path)?
                .primary.appendingPathComponent(proposal.slug, isDirectory: true).path
        let current = managed
            .flatMap(SkillInstaller.currentMarkdown)
            ?? SkillInstaller.unmanagedMarkdown(slug: proposal.slug, scope: scope, projectPath: path)
            ?? ""
        pendingUpdate = PendingUpdate(
            entryId: entry.id, proposal: proposal, currentMarkdown: current,
            scope: scope, resolvedPath: resolvedPath)
    }

    private func confirmUpdate(_ update: PendingUpdate) {
        guard let entry = entries.first(where: { $0.id == update.entryId }) else { return }
        do {
            let record = try SkillInstaller.update(
                slug: update.proposal.slug, markdown: update.proposal.markdown,
                title: update.proposal.title, scope: update.scope,
                projectPath: projectPath(for: entry), projectId: entry.projectId,
                entryId: entry.id)
            setSkillState(update.proposal, entry: entry, state: .installed)
            statusLine = "Updated \(record.slug) to v\(record.version)."
        } catch {
            statusLine = "Update failed: \(error.localizedDescription)"
        }
        pendingUpdate = nil
    }

    private func uninstall(_ proposal: DreamSkillProposal, entry: DreamJournalEntry) {
        do {
            _ = try SkillInstaller.uninstall(slug: proposal.slug)
            setSkillState(proposal, entry: entry, state: .uninstalled)
            statusLine = "Uninstalled \(proposal.slug) — its directory and mirrors are gone."
        } catch {
            statusLine = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    private func setSkillState(
        _ proposal: DreamSkillProposal, entry: DreamJournalEntry, state: DreamSkillProposalState
    ) {
        mutateEntry(entry.id) { entry in
            entry.payload.skillProposals = entry.payload.skillProposals.map {
                var p = $0
                if p.id == proposal.id { p.state = state }
                return p
            }
        }
    }

    private func mutateEntry(_ id: String, _ transform: (inout DreamJournalEntry) -> Void) {
        guard let store = model.store, var entry = (try? store.dreamEntry(id: id)) ?? nil else { return }
        transform(&entry)
        try? store.upsertDreamEntry(entry)
        reload()
    }

    // MARK: - Share card (stats only, never memory content)

    @MainActor
    private func saveShareCard(_ entry: DreamJournalEntry) {
        let renderer = ImageRenderer(content: DreamShareCardView(entry: entry))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            statusLine = "Couldn't render the share card."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "hypermnesia-dreamed.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            statusLine = "Share card saved — stats only, no memory content."
        } catch {
            statusLine = "Couldn't save the share card: \(error.localizedDescription)"
        }
    }

    // MARK: - Kind styling

    private func kindLabel(_ kind: DreamEpiphanyKind) -> String {
        switch kind {
        case .theme: "Theme"
        case .strengthening: "Strengthening"
        case .openThread: "Open thread"
        case .contradiction: "Contradiction"
        case .friction: "Friction"
        case .gap: "Gap"
        }
    }

    private func kindColor(_ kind: DreamEpiphanyKind) -> Color {
        switch kind {
        case .theme: .blue
        case .strengthening: .green
        case .openThread: .orange
        case .contradiction: .red
        case .friction: .purple
        case .gap: .teal
        }
    }
}

/// Editable staged SKILL.md — nothing touches disk until Install/Update.
private struct EditSkillSheet: View {
    let editing: DreamJournalView.EditingProposal
    let onSave: (DreamJournalView.EditingProposal) -> Void
    let onCancel: () -> Void
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit \(editing.proposal.slug)").font(.title3.bold())
            Text("This is the staged SKILL.md — it installs exactly as shown here.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.caption.monospaced())
                .frame(minHeight: 300)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") {
                    var updated = editing
                    updated.proposal.markdown = text
                    onSave(updated)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 640, height: 460)
        .onAppear { text = editing.proposal.markdown }
    }
}

// MARK: - REM replay

/// The 10–15 s skippable replay: the project's brain in a night palette, cited memories pulsing —
/// the MRI's own layout + pulse machinery, moon-lit. Offered only when a fresh dream has content.
struct DreamRemView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: DreamJournalEntry
    /// `openJournal` — both Skip and natural end land in the journal.
    let onEnd: (Bool) -> Void

    @State private var start = Date()
    @State private var pulses: [BrainPulse] = []
    @State private var memories: [MemoryNode] = []

    private let duration: TimeInterval = 12

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                Canvas { ctx, size in
                    let layout = BrainMRIView.layoutBrain(in: size, memories: memories)
                    BrainMRIView.drawBrain(
                        in: &ctx, size: size, now: timeline.date,
                        nodes: layout.nodes, regions: layout.regions, edges: [],
                        pulses: pulses, reduceMotion: reduceMotion,
                        pulseLifetime: 3.8, highlightedNodeID: nil)
                }
                // Night palette: everything cools toward moonlight blue.
                .colorMultiply(Color(red: 0.66, green: 0.74, blue: 1.0))
            }
            .padding(40)

            VStack {
                HStack {
                    Spacer()
                    Button("Skip") { onEnd(true) }
                        .buttonStyle(.bordered)
                        .padding(14)
                }
                Spacer()
                VStack(spacing: 6) {
                    Label("Hypermnesia dreamed", systemImage: "moon.zzz.fill")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.75, green: 0.8, blue: 1.0))
                    if let narrative = entry.narrative {
                        Text(narrative)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }
                }
                .padding(.bottom, 36)
            }
        }
        .contentShape(Rectangle())
        .onAppear { load() }
        .task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 4 : duration))
            onEnd(true)
        }
    }

    private func load() {
        guard let store = model.store else { return }
        memories = ((try? store.allNodes(projectId: entry.projectId)) ?? [])
            .filter { !$0.isDeleted }
        // Cited memories pulse in sequence, then a soft second wave — receipts, animated.
        let cited = Array(Set(
            entry.payload.epiphanies.flatMap(\.memoryIds) + entry.payload.proposedMemoryIds))
        let ids = cited.isEmpty ? memories.prefix(6).map(\.id) : cited
        let interval = 8.0 / Double(max(1, ids.count))
        start = Date()
        pulses = ids.enumerated().flatMap { index, id -> [BrainPulse] in
            let event = MemoryActivityEvent(
                projectId: entry.projectId, eventType: .dream, memoryIds: [id])
            return [
                BrainPulse(event: event, startedAt: start.addingTimeInterval(1 + Double(index) * interval)),
                BrainPulse(event: event, startedAt: start.addingTimeInterval(6.5 + Double(index) * interval)),
            ]
        }
    }
}

// MARK: - Share card

/// "My agent dreamed last night" — corpus stats and epiphany counts only, never memory content.
struct DreamShareCardView: View {
    let entry: DreamJournalEntry

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.06, blue: 0.14), Color(red: 0.10, green: 0.09, blue: 0.24)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "brain")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 10))
                    Text("Hypermnesia").font(.title2.bold()).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color(red: 0.75, green: 0.8, blue: 1.0))
                }
                Text("My agent dreamed last night.")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                HStack(spacing: 12) {
                    statChip("\(entry.payload.stats.sessionsScanned)", "sessions read")
                    statChip("\(entry.payload.epiphanies.count)", "epiphanies")
                    statChip("\(entry.payload.proposedMemoryIds.count)", "memories proposed")
                    statChip("\(entry.payload.skillProposals.count)", "skills drafted")
                }
                Spacer()
                HStack {
                    Text("Durable, decaying memory for your coding agents")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text("hypermnesia.app")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(red: 0.75, green: 0.8, blue: 1.0))
                }
            }
            .padding(48)
        }
        .frame(width: 1200, height: 630)
    }

    private func statChip(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
            Text(label).font(.callout).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
