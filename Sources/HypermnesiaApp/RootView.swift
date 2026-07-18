import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HypermnesiaKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 820, minHeight: 520)
        .sheet(isPresented: $model.quickOpenShown) {
            QuickOpenView()
        }
    }
}

/// Projects + per-type filters.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var deleteTarget: DeleteTarget?

    private enum DeleteTarget: Identifiable {
        case project(String)
        case all

        var id: String {
            switch self {
            case .project(let project): "project:\(project)"
            case .all: "all"
            }
        }
    }

    var body: some View {
        @Bindable var model = model

        List {
            Section("Projects") {
                if model.projects.isEmpty {
                    Text("No memories yet").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(model.projects, id: \.self) { project in
                    projectRow(project)
                }
            }

            Section("Types") {
                typeRow(nil, label: "All", symbol: "square.grid.2x2", count: model.memories.count)
                ForEach(MemoryType.allCases, id: \.self) { type in
                    typeRow(type, label: type.displayName, symbol: type.sfSymbol,
                            count: model.counts[type] ?? 0, tint: type.color)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload from the store")
            }
            ToolbarItem {
                Menu {
                    if let project = model.selectedProject {
                        Button("Remove \(projectDisplayName(project)) memories…", role: .destructive) {
                            deleteTarget = .project(project)
                        }
                    }
                    Button("Remove all memories…", role: .destructive) {
                        deleteTarget = .all
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete memories")
                .disabled(model.projects.isEmpty)
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch deleteTarget {
            case .project(let project):
                Button("Remove \(projectDisplayName(project)) memories", role: .destructive) {
                    model.deleteProjectMemories(project)
                    deleteTarget = nil
                }
            case .all:
                Button("Remove all memories", role: .destructive) {
                    model.deleteAllMemories()
                    deleteTarget = nil
                }
            case .none:
                EmptyView()
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    @ViewBuilder
    private func projectRow(_ project: String) -> some View {
        @Bindable var model = model
        let selected = model.selectedProject == project
        Button { model.selectedProject = project } label: {
            Label(projectDisplayName(project), systemImage: "folder")
                .padding(.vertical, 6).padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .foregroundStyle(selected ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.brand : .clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowBackground(Color.clear)
        .contextMenu {
            Button("Import CLAUDE.md conventions…") { model.importClaudeMd(projectId: project) }
            Button("Export memory digest…") { exportDigest(project) }
            Divider()
            Button("Remove this project's memories…", role: .destructive) {
                deleteTarget = .project(project)
            }
        }
    }

    @ViewBuilder
    private func typeRow(_ type: MemoryType?, label: String, symbol: String, count: Int, tint: Color = .secondary) -> some View {
        @Bindable var model = model
        let isSelected = model.typeFilter == type
        Button {
            model.typeFilter = isSelected ? nil : type   // click the active one again to clear
            model.reloadMemories()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(tint == .secondary ? Color.primary : tint)
                    .frame(width: 18)
                Text(label)
                Spacer(minLength: 8)
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())   // whole row is the hit target
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.brand.opacity(0.22) : .clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowBackground(Color.clear)
    }

    /// Save this project's confirmed memory as a committable MEMORY.md — the shareable team
    /// artifact (decisions, conventions, gotchas; no internal ids).
    private func exportDigest(_ projectId: String) {
        guard let store = model.store else { return }
        let nodes = (try? store.nodes(projectId: projectId, limit: 100_000)) ?? []
        let digest = MemoryMarkdown.projectDigest(projectId: projectId, nodes: nodes)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "MEMORY.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(digest.utf8).write(to: url)
        } catch {
            model.lastActionError = "Couldn't export the digest: \(error.localizedDescription)"
        }
    }

    private var deleteConfirmationTitle: String {
        switch deleteTarget {
        case .project(let project):
            return "Remove all memories for \(projectDisplayName(project))?"
        case .all:
            return "Remove all memories?"
        case .none:
            return "Remove memories?"
        }
    }

    private var deleteConfirmationMessage: String {
        switch deleteTarget {
        case .project:
            return "This permanently removes this repo's memories, graph edges, and capture history."
        case .all:
            return "This permanently removes every memory, project, graph edge, and capture history."
        case .none:
            return ""
        }
    }
}

/// The detail pane: switches between List / Graph / Health.
/// The zero-memories first run: every path into the product, as a button — not a CLI incantation.
struct GetStartedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var hooksInstalled = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "brain")
                .font(.system(size: 44))
                .foregroundStyle(Color.brand)
            Text("Build a memory of your codebase")
                .font(.title2.bold())
            Text("Hypermnesia captures what your coding sessions decide and learns, then reminds your agent next time.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 12) {
                if hooksInstalled {
                    getStartedRow(
                        symbol: "bolt.badge.checkmark",
                        title: "Capture is on — waiting for your first session",
                        caption: "Finish an agent session and its memories will appear here on their own."
                    ) {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    getStartedRow(
                        symbol: "bolt.badge.checkmark",
                        title: "Set up automatic capture",
                        caption: "Install the capture hooks — new sessions build memory on their own."
                    ) {
                        Button("Open Settings…") { openSettings() }
                    }
                }
                getStartedRow(
                    symbol: "clock.arrow.circlepath",
                    title: "Start from your history",
                    caption: "Classify your existing Claude Code, Cursor, and Antigravity sessions into memories now."
                ) {
                    Button(model.isProcessing ? "Processing…" : "Process previous sessions") {
                        model.processPreviousSessions()
                    }
                    .disabled(model.isProcessing)
                }
                getStartedRow(
                    symbol: "sparkles",
                    title: "Just looking?",
                    caption: "Load sample memories to explore the views — delete them any time."
                ) {
                    Button("Load sample data") { model.loadSampleData() }
                }
            }
            .frame(maxWidth: 460)

            if let status = model.processingStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { hooksInstalled = HookInstaller.isInstalled() }
        // Settings may have just installed the hooks — re-check whenever the model reloads.
        .onChange(of: model.projects) { _, _ in hooksInstalled = HookInstaller.isInstalled() }
    }

    private func getStartedRow(
        symbol: String, title: String, caption: String, @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.brand)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @State private var showAsk = false

    var body: some View {
        @Bindable var model = model

        Group {
            if let error = model.storeError {
                ContentUnavailableView("Store unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(error))
            } else if model.projects.isEmpty {
                GetStartedView()
            } else {
                switch model.browseMode {
                case .list: MemoryListView()
                case .graph: GraphView()
                case .health: HealthView()
                case .trends: TrendsView()
                case .mri: BrainMRIView()
                case .feed: ActivityFeedView()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if model.showFirstCaptureCelebration {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.brand)
                        Text("Your agent learned its first memories from a real session!")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button("Review drafts") { model.dismissFirstCaptureCelebration(review: true) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Later") { model.dismissFirstCaptureCelebration(review: false) }
                            .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.brand.opacity(0.4)))
                    .padding(.horizontal, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let undo = model.pendingUndo {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(undo.description)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Button("Undo") { model.undoLastAction() }
                            .buttonStyle(.borderless)
                            .keyboardShortcut("z", modifiers: .command)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if model.captureQueueHealth.hasActivity || model.captureQueueHealth.hasErrors {
                    let health = model.captureQueueHealth
                    HStack(spacing: 8) {
                        Image(systemName: health.hasErrors
                              ? "exclamationmark.triangle.fill" : "tray.and.arrow.down.fill")
                            .foregroundStyle(health.hasErrors ? Color.red : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Capture queue: \(health.pending) pending, \(health.processing) processing, "
                                 + "\(health.retrying) retrying, \(health.terminalErrors) failed")
                                .font(.callout)
                            if let failure = health.lastError {
                                Text("\(failure.sessionId.prefix(8)): \(failure.message)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if health.terminalErrors > 0 {
                            Button("Clear failed", role: .destructive) {
                                model.clearFailedCaptures()
                            }
                            .buttonStyle(.borderless)
                            .help("Remove failed queue entries; memories and source transcripts are unchanged")
                        }
                        Button { model.refreshQueueHealth() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh capture queue health")
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 10)
                }
                if let actionError = model.lastActionError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(actionError)
                            .font(.callout)
                            .lineLimit(2)
                        Spacer()
                        Button("Dismiss") { model.lastActionError = nil }
                            .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 10)
                }
            }
            .padding(.bottom, 10)
            .animation(.snappy, value: model.pendingUndo?.description)
        }
        .navigationTitle(model.selectedProject.map(projectDisplayName) ?? "Hypermnesia")
        .navigationSubtitle(model.browseMode.label)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.browseMode) {
                    ForEach(BrowseMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            if model.browseMode == .graph {
                ToolbarItem {
                    Picker("Layout", selection: $model.graphLayout) {
                        ForEach(GraphLayoutMode.allCases) { Text($0.label).tag($0) }
                    }
                    .help("Graph layout mode")
                }
            }
            if !model.draftMemories.isEmpty {
                ToolbarItem {
                    Menu {
                        Button("Confirm all \(model.draftMemories.count) drafts") { model.confirmAllDrafts() }
                        Button("Dismiss all drafts", role: .destructive) { model.dismissAllDrafts() }
                    } label: {
                        Label("\(model.draftMemories.count)", systemImage: "tray.full")
                    }
                    .help("Review drafts in bulk")
                }
            }
            ToolbarItem {
                Button { showAsk = true } label: { Image(systemName: "sparkles") }
                    .help("Ask a question about this project")
            }
            ToolbarItem {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $showAsk) {
            MemoryQuerySheet().environment(model)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search memories")
        .onChange(of: model.searchFocusRequestID) { _, _ in
            // Defer a tick so the search field exists after any browse-mode switch, then focus it.
            DispatchQueue.main.async { WindowSupport.focusSearchField() }
        }
        .onChange(of: model.browseMode) { _, mode in
            if mode == .mri {
                model.selectedMemoryID = nil
            }
            if mode != .list {
                model.listShowsDraftsOnly = false
            }
        }
        .confirmationDialog(
            "Classify \(model.backfillProposal?.count ?? 0) past session\((model.backfillProposal?.count ?? 0) == 1 ? "" : "s")?",
            isPresented: Binding(
                get: { model.backfillProposal != nil },
                set: { if !$0, model.backfillProposal != nil { model.cancelBackfill() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Classify \(model.backfillProposal?.count ?? 0) session\((model.backfillProposal?.count ?? 0) == 1 ? "" : "s")") {
                model.confirmBackfill()
            }
            Button("Cancel", role: .cancel) { model.cancelBackfill() }
        } message: {
            Text("Each session is classified with your configured model — roughly one API call per session on your key. You can watch progress and keep using the app while it runs.")
        }
        .inspector(isPresented: Binding(
            get: { model.selectedMemoryID != nil },
            set: { if !$0 { model.selectedMemoryID = nil } }
        )) {
            if let node = model.selectedMemory {
                MemoryDetailView(node: node)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
            } else {
                ContentUnavailableView("No memory selected", systemImage: "hand.tap")
            }
        }
    }
}
