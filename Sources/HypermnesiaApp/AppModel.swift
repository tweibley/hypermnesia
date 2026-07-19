import SwiftUI
import Observation
import HypermnesiaKit

/// Observable app state backed by the live `MemoryStore`. The CLI/daemon write to the same database,
/// so `reload()` surfaces newly captured memories. (Live file-watching comes in Phase 6.)
@MainActor
@Observable
final class AppModel {
    private static let lastSelectedProjectKey = "Hypermnesia.lastSelectedProjectId"
    private static let lastBrowseModeKey = "Hypermnesia.lastBrowseMode"

    private(set) var store: MemoryStore?
    var storeError: String?

    var projects: [String] = []
    var selectedProject: String? {
        didSet {
            if let selectedProject {
                UserDefaults.standard.set(selectedProject, forKey: Self.lastSelectedProjectKey)
            }
            reloadMemories()
        }
    }

    private(set) var memories: [MemoryNode] = []
    var searchText: String = "" { didSet { runSearch() } }
    private(set) var searchResults: [MemoryNode] = []
    var typeFilter: MemoryType?
    var listShowsDraftsOnly = false
    /// Bumped by the ⌘F "Find" menu command so the list's search field takes focus.
    private(set) var searchFocusRequestID = 0

    /// Switch to the list and ask its search field to focus (⌘F). Filtering already flows through
    /// `searchText` → `filteredMemories`; this just puts the cursor in the box.
    func requestSearchFocus() {
        if browseMode != .list { browseMode = .list }
        searchFocusRequestID &+= 1
    }
    var browseMode: BrowseMode = AppModel.loadLastBrowseMode() {
        didSet {
            UserDefaults.standard.set(browseMode.rawValue, forKey: AppModel.lastBrowseModeKey)
        }
    }
    var graphLayout: GraphLayoutMode = .constellation
    /// Single selection drives the detail inspector; every non-list surface (graph, health, Ask
    /// sources, revision links) assigns it directly. `didSet` keeps the list's multi-selection in
    /// step so the row highlight always matches.
    var selectedMemoryID: MemoryNode.ID? {
        didSet {
            guard oldValue != selectedMemoryID else { return }
            if let id = selectedMemoryID {
                if selectedMemoryIDs != [id] { selectedMemoryIDs = [id] }
            } else if selectedMemoryIDs.count == 1 {
                selectedMemoryIDs = []
            }
        }
    }
    /// The list's (possibly multi-row) selection. More than one row selected → batch actions in
    /// the list header; exactly one → the inspector opens via `selectedMemoryID`.
    var selectedMemoryIDs: Set<MemoryNode.ID> = []

    /// Route the list's selection changes: multi-select suppresses the inspector, single opens it.
    func setListSelection(_ ids: Set<MemoryNode.ID>) {
        selectedMemoryIDs = ids
        let single = ids.count == 1 ? ids.first : nil
        if selectedMemoryID != single { selectedMemoryID = single }
    }

    var isProcessing = false
    var processingStatus: String?
    /// A user-visible failure from the last mutation (write failed, classifier failed) — shown as a
    /// dismissible banner. Mutations that swallow their errors read as false success ("Up to date.")
    /// and cost the user data without them knowing.
    var lastActionError: String?
    private(set) var captureQueueHealth: CaptureQueueHealth = .empty
    private var drainTask: Task<Void, Never>?

    /// One reversible triage action. Undo is snapshot-based: restoring these full row snapshots
    /// reverses the mutation *and* its side-effects (supersede marking, duplicate-draft purge),
    /// which closure-based undo would have to re-derive.
    struct UndoRecord {
        let description: String
        let snapshots: [MemoryNode]
    }
    private(set) var pendingUndo: UndoRecord?
    private var undoExpiryTask: Task<Void, Never>?

    private func recordUndo(_ description: String, restoring snapshots: [MemoryNode]) {
        guard !snapshots.isEmpty else { return }
        pendingUndo = UndoRecord(description: description, snapshots: snapshots)
        undoExpiryTask?.cancel()
        undoExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation { self?.pendingUndo = nil }
        }
    }

    func dismissUndo() {
        undoExpiryTask?.cancel()
        withAnimation { pendingUndo = nil }
    }

    func undoLastAction() {
        guard let store, let undo = pendingUndo else { return }
        undoExpiryTask?.cancel()
        pendingUndo = nil
        do {
            try store.upsert(undo.snapshots)
            lastActionError = nil
        } catch {
            lastActionError = "Couldn't undo: \(error.localizedDescription)"
        }
        reloadMemories()
    }

    var isAsking = false
    var answer: MemoryAnswer?

    // MARK: - Memory Dreams state

    /// The Dream Journal sheet (reached from the notch chip, the digest notification, the Feed,
    /// and the toolbar moon).
    var dreamJournalShown = false
    /// Unread dreamed nights across all projects — drives the notch chip and the toolbar badge.
    /// Written only by `refreshUnreadDreams()` (DreamCoordinator extension).
    var unreadDreamCount = 0
    /// Non-nil ⇒ the REM replay overlay is playing this entry (skippable).
    var remEntry: DreamJournalEntry?
    /// Re-entrancy guard for the nightly pass (the drain loop ticks every 20 s).
    var dreamPassRunning = false

    init() { open() }

    private static func loadLastBrowseMode() -> BrowseMode {
        guard let raw = UserDefaults.standard.string(forKey: lastBrowseModeKey),
              let mode = BrowseMode(rawValue: raw) else {
            return .list
        }
        return mode
    }

    func open() {
        ensureClassifierEnv()
        do {
            store = try MemoryStore()
            storeError = nil
            reloadProjects()
            startAutoDrain()
        } catch {
            storeError = error.localizedDescription
        }
    }

    // MARK: - First-capture moment

    private static let hasSeenFirstCaptureKey = "Hypermnesia.hasSeenFirstCapture"
    var showFirstCaptureCelebration = false
    private var completedInitialLoad = false
    private var suppressCelebrationOnce = false

    func dismissFirstCaptureCelebration(review: Bool) {
        UserDefaults.standard.set(true, forKey: Self.hasSeenFirstCaptureKey)
        withAnimation { showFirstCaptureCelebration = false }
        if review {
            browseMode = .list
            setDraftsOnlyFilter(true)
        }
    }

    func reloadProjects() {
        guard let store else { return }
        let wasEmpty = projects.isEmpty
        projects = (try? store.projects()) ?? []
        // The magic moment made explicit: the store just went 0 → some while the app was running.
        // Suppressed for sample data (that's not a capture) and for the initial load of an
        // already-populated store.
        if completedInitialLoad, wasEmpty, !projects.isEmpty {
            if suppressCelebrationOnce {
                suppressCelebrationOnce = false
            } else if !UserDefaults.standard.bool(forKey: Self.hasSeenFirstCaptureKey) {
                withAnimation { showFirstCaptureCelebration = true }
            }
        }
        completedInitialLoad = true
        refreshTotalDraftCount()
        refreshQueueHealth()
        refreshUnreadDreams()
        let remembered = UserDefaults.standard.string(forKey: Self.lastSelectedProjectKey)
        if let remembered, projects.contains(remembered), selectedProject != remembered {
            selectedProject = remembered
        } else if selectedProject == nil || !(projects.contains(selectedProject ?? "")) {
            selectedProject = projects.first
        } else {
            reloadMemories()
        }
    }

    func reloadMemories() {
        guard let store, let project = selectedProject else { memories = []; return }
        // Animate the diff so memories landed by the background drain visibly arrive in the list
        // (and triaged rows visibly leave) instead of appearing on the next full redraw.
        withAnimation(.snappy) {
            memories = (try? store.nodes(projectId: project, type: typeFilter, status: nil)) ?? []
        }
        runSearch()
        refreshTotalDraftCount()
    }

    /// Drafts across ALL projects — drives the menu-bar badge, which must not depend on which
    /// project happens to be selected in the window. Stored (not computed) so the menu-bar label
    /// re-renders via observation whenever a reload changes it.
    private(set) var totalDraftCount = 0

    private func refreshTotalDraftCount() {
        guard let store else { totalDraftCount = 0; return }
        let all = (try? store.projects()) ?? []
        totalDraftCount = all.reduce(0) { sum, project in
            sum + ((try? store.counts(projectId: project, status: .draft)) ?? [:]).values.reduce(0, +)
        }
    }

    func refreshQueueHealth() {
        guard let store else {
            captureQueueHealth = .empty
            return
        }
        captureQueueHealth = (try? store.captureQueueHealth()) ?? .empty
    }

    func clearFailedCaptures() {
        guard let store else { return }
        do {
            _ = try store.clearFailedCaptures()
            lastActionError = nil
            refreshQueueHealth()
        } catch {
            lastActionError = "Could not clear failed captures: \(error.localizedDescription)"
        }
    }

    func refresh() {
        reloadProjects()
    }

    /// Full-text search via the store's FTS5 index (recomputed when the query or project changes).
    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, let project = selectedProject, !query.isEmpty else { searchResults = []; return }
        searchResults = (try? store.search(projectId: project, query: query, limit: 200)) ?? []
    }

    var filteredMemories: [MemoryNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [MemoryNode]
        if query.isEmpty {
            base = memories                      // already type-filtered by reloadMemories
        } else {
            // Find-as-you-type: live substring match over the loaded memories (title/summary),
            // preserving their order — so "store" matches "MemoryStore.search", not just the FTS
            // token "store". Then append FTS hits that matched in the payload/body (whole-token
            // matches the substring pass can't see), de-duped by id.
            let q = query.lowercased()
            var result = memories.filter { $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
            var seen = Set(result.map(\.id))
            for hit in searchResults where seen.insert(hit.id).inserted {
                result.append(hit)
            }
            base = result
        }
        return typeFilter == nil ? base : base.filter { $0.type == typeFilter }
    }

    var counts: [MemoryType: Int] {
        guard let store, let project = selectedProject else { return [:] }
        return (try? store.counts(projectId: project)) ?? [:]
    }

    var draftCount: Int { draftMemories.count }

    /// Memories needing review, grouped by decay band (for the Health view).
    var healthGroups: [(level: DecayLevel, nodes: [MemoryNode])] {
        let confirmed = memories.filter { $0.status == .confirmed }
        return DecayLevel.allCases.compactMap { level in
            let nodes = confirmed.filter { $0.decayLevel == level }
            return nodes.isEmpty ? nil : (level, nodes)
        }
    }

    // MARK: - Trends

    var trendsWindow: TrendWindow = .days7

    /// Project-wide trends (all types, all statuses) for the Trends dashboard. Recomputed from the
    /// store on access — the node set is small and this matches `counts`/`draftMemories` above.
    var projectTrends: ProjectTrendsVM {
        guard let store, let project = selectedProject else {
            return MemoryAnalytics.projectTrends(nodes: [], window: trendsWindow, now: Date())
        }
        let all = (try? store.nodes(projectId: project, type: nil, status: nil, limit: 5000)) ?? []
        return MemoryAnalytics.projectTrends(nodes: all, window: trendsWindow, now: Date())
    }

    /// The currently selected memory (for the detail inspector). Falls back to the store so a
    /// selection from Ask sources or the graph resolves even when it isn't in the filtered list.
    var selectedMemory: MemoryNode? {
        guard let id = selectedMemoryID else { return nil }
        if let inList = memories.first(where: { $0.id == id }) { return inList }
        guard let store else { return nil }
        return (try? store.node(id: id)) ?? nil
    }

    /// Fetch one memory by id (used by the inspector's supersede-chain links, which may point at
    /// nodes filtered out of the current list).
    func memory(id: String) -> MemoryNode? {
        guard let store else { return nil }
        return (try? store.node(id: id)) ?? nil
    }

    // MARK: - Quick open (⌘K)

    var quickOpenShown = false

    /// Search every project's memories (title/summary substring first, then FTS hits) — the ⌘K
    /// palette is the only surface that crosses project boundaries.
    func quickOpenSearch(_ query: String, limit: Int = 15) -> [MemoryNode] {
        guard let store else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var results: [MemoryNode] = []
        var seen = Set<String>()
        for project in (try? store.projects()) ?? [] {
            let nodes = (try? store.nodes(projectId: project, limit: 2000)) ?? []
            for node in nodes where node.title.lowercased().contains(q) || node.summary.lowercased().contains(q) {
                if seen.insert(node.id).inserted { results.append(node) }
            }
            for hit in (try? store.search(projectId: project, query: q, limit: 20)) ?? [] {
                if seen.insert(hit.id).inserted { results.append(hit) }
            }
            if results.count >= limit * 3 { break }
        }
        return Array(results.prefix(limit))
    }

    /// Jump to a memory anywhere: switch project if needed, land in the list, open the inspector.
    func jump(to node: MemoryNode) {
        if selectedProject != node.projectId { selectedProject = node.projectId }
        if browseMode == .mri { browseMode = .list }
        listShowsDraftsOnly = false
        selectedMemoryID = node.id
        quickOpenShown = false
    }

    // MARK: - Injection visibility

    struct InjectionSummary: Equatable {
        let date: Date
        let count: Int
        let projectId: String
        let viaRecall: Bool
    }

    /// The most recent time memories actually went INTO a session (hydrate or MCP recall), across
    /// all projects — the menu bar's proof-it's-working line. Cheap: the activity log's decoded
    /// tail is cached by file signature.
    var lastInjection: InjectionSummary? {
        let events = MemoryActivityLog.recent(limit: 400)
        guard let event = events.last(where: {
            ($0.eventType == .hydrate || $0.eventType == .recall) && ($0.count ?? $0.memoryIds.count) > 0
        }) else { return nil }
        return InjectionSummary(
            date: event.timestamp,
            count: event.count ?? event.memoryIds.count,
            projectId: event.projectId,
            viaRecall: event.eventType == .recall
        )
    }

    /// When this specific memory last went into a session, if the activity log still remembers.
    func lastInjectedAt(memoryId: String, projectId: String) -> Date? {
        MemoryActivityLog.recent(projectId: projectId, limit: 600)
            .last { ($0.eventType == .hydrate || $0.eventType == .recall) && $0.memoryIds.contains(memoryId) }?
            .timestamp
    }

    // MARK: - Actions

    func confirm(_ node: MemoryNode) {
        guard let store else { return }
        do {
            let result = try MemoryTriageService.confirm(nodeIDs: [node.id], store: store)
            if result.confirmed > 0 {
                recordUndo("Confirmed “\(node.title)”", restoring: result.snapshots)
            }
            lastActionError = nil
        } catch {
            lastActionError = "Couldn't confirm the memory: \(error.localizedDescription)"
        }
        reloadMemories()
    }

    /// Mark a memory as still-true: reset confidence to full and validation time to now (works for
    /// all types, including non-decaying ones, so an audit penalty is genuinely cleared).
    func revalidate(_ node: MemoryNode) {
        guard let store else { return }
        var updated = (try? store.node(id: node.id)) ?? node   // fresh row, not the stale UI snapshot
        let previousLevel = updated.decayLevel
        updated.confidence = 1.0
        updated.lastValidatedAt = Date()
        updated.updatedAt = Date()
        // "Still true" is an explicit assertion of correctness, so clear the drift evidence — otherwise
        // the belief model re-applies the override penalty on recompute and the memory can never be
        // restored above ~0.5 × belief.
        updated.timesOverridden = 0
        updated.lastAuditOutcome = nil
        updated = DecayEngine.decayed(updated)
        do {
            try store.upsert(updated)
            lastActionError = nil
        } catch {
            lastActionError = "Couldn't revalidate the memory: \(error.localizedDescription)"
            return
        }
        MemoryActivityLog.append(.init(
            projectId: updated.projectId,
            eventType: .revalidate,
            memoryIds: [updated.id],
            count: 1
        ))
        if updated.decayLevel != previousLevel {
            MemoryActivityLog.append(.init(
                projectId: updated.projectId,
                eventType: .decayTransition,
                memoryIds: [updated.id],
                count: 1,
                metadata: ["from": previousLevel.rawValue, "to": updated.decayLevel.rawValue]
            ))
        }
        reloadMemories()
    }

    /// Un-supersede: bring a retired memory back into circulation. The reviser keeps its
    /// `supersedesId` link as a tombstone, which is what stops the automatic conflict sweep from
    /// simply re-retiring this pair on its next pass.
    func restore(_ node: MemoryNode) {
        guard let store, node.isSuperseded else { return }
        let snapshot = (try? store.node(id: node.id)) ?? nil
        update(node) {
            $0.supersededById = nil
            $0.updatedAt = Date()
        }
        if let snapshot { recordUndo("Restored “\(node.title)”", restoring: [snapshot]) }
    }

    func delete(_ node: MemoryNode) {
        guard let store else { return }
        let snapshot = (try? store.node(id: node.id)) ?? nil
        do {
            try store.softDeleteNode(id: node.id)
            lastActionError = nil
            if let snapshot {
                recordUndo(snapshot.status == .draft ? "Dismissed “\(node.title)”" : "Deleted “\(node.title)”",
                           restoring: [snapshot])
            }
        } catch {
            lastActionError = "Couldn't delete the memory: \(error.localizedDescription)"
        }
        if selectedMemoryID == node.id { selectedMemoryID = nil }
        reloadMemories()
    }

    @discardableResult
    func deleteProjectMemories(_ projectId: String) -> Int {
        guard let store else { return 0 }
        let deleted = (try? store.hardDeleteProject(projectId: projectId)) ?? 0
        if selectedProject == projectId {
            selectedMemoryID = nil
            searchText = ""
        }
        reloadProjects()
        processingStatus = deleted == 1
            ? "Removed 1 memory from \(projectDisplayName(projectId))."
            : "Removed \(deleted) memories from \(projectDisplayName(projectId))."
        return deleted
    }

    @discardableResult
    func deleteAllMemories() -> Int {
        guard let store else { return 0 }
        let deleted = (try? store.hardDeleteAllMemories()) ?? 0
        selectedMemoryID = nil
        searchText = ""
        listShowsDraftsOnly = false
        reloadProjects()
        processingStatus = deleted == 1 ? "Removed 1 memory." : "Removed \(deleted) memories."
        return deleted
    }

    func openDraftReview() {
        browseMode = .list
        typeFilter = nil
        searchText = ""
        reloadMemories()
        setDraftsOnlyFilter(true)
    }

    func setDraftsOnlyFilter(_ draftsOnly: Bool) {
        listShowsDraftsOnly = draftsOnly
        guard draftsOnly else { return }
        if selectedMemory?.status != .draft {
            selectedMemoryID = draftMemories.first?.id
        }
    }

    private func update(_ node: MemoryNode, _ change: (inout MemoryNode) -> Void) {
        guard let store else { return }
        // Re-read the current row first: a background drain's reconcile may have bumped this node's
        // counters/status/lastValidatedAt since the UI snapshot was taken, and writing the whole
        // stale row back would silently erase that. Apply the edit to the fresh row instead.
        var updated = (try? store.node(id: node.id)) ?? node
        change(&updated)
        do {
            try store.upsert(updated)
            lastActionError = nil
        } catch {
            lastActionError = "Couldn't save the change: \(error.localizedDescription)"
        }
        reloadMemories()
    }

    // MARK: - Natural-language query

    func ask(_ question: String) {
        guard let store, let project = selectedProject else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isAsking = true
        answer = nil
        Task { [weak self] in
            // Keep the actual failure: "Couldn't get an answer." with no reason sends the user
            // hunting; a missing API key or a network error names its own fix.
            let result: Result<MemoryAnswer, Error> = await Task.detached {
                do {
                    return .success(try await MemoryQA.ask(q, store: store, projectId: project,
                                                           completer: Completers.makeFromConfig(), embedder: AppleEmbedder()))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let answer):
                self?.answer = answer
            case .failure(let error):
                self?.answer = MemoryAnswer(
                    question: q,
                    answer: "Couldn't get an answer: \(error.localizedDescription)\nCheck Settings → Classifier.",
                    sources: [])
            }
            self?.isAsking = false
        }
    }

    // MARK: - Triage

    /// All of the project's drafts (ignores the type filter, so bulk actions and the badge mean "all").
    var draftMemories: [MemoryNode] {
        guard let store, let project = selectedProject else { return [] }
        return (try? store.nodes(projectId: project, status: .draft, limit: 1000)) ?? []
    }

    func confirmAllDrafts() {
        guard let store else { return }
        do {
            let result = try MemoryTriageService.confirm(nodeIDs: draftMemories.map(\.id), store: store)
            if result.confirmed > 0 {
                recordUndo("Confirmed \(result.confirmed) draft\(result.confirmed == 1 ? "" : "s")",
                           restoring: result.snapshots)
            }
            lastActionError = nil
        } catch {
            lastActionError = "Couldn't confirm every draft: \(error.localizedDescription)"
        }
        reloadMemories()
        if draftMemories.isEmpty {
            listShowsDraftsOnly = false
            selectedMemoryID = nil
        }
    }

    /// Confirm every selected draft (already-confirmed rows in the selection are left alone).
    func confirmSelected() {
        guard let store else { return }
        let orderedIDs = draftMemories.map(\.id).filter { selectedMemoryIDs.contains($0) }
        do {
            let result = try MemoryTriageService.confirm(nodeIDs: orderedIDs, store: store)
            if result.confirmed > 0 {
                recordUndo("Confirmed \(result.confirmed) draft\(result.confirmed == 1 ? "" : "s")",
                           restoring: result.snapshots)
            }
            lastActionError = nil
        } catch {
            lastActionError = "Couldn't confirm every selected draft: \(error.localizedDescription)"
        }
        setListSelection([])
        reloadMemories()
    }

    /// Dismiss (soft-delete) every selected memory.
    func dismissSelected() {
        guard let store else { return }
        var snapshots: [MemoryNode] = []
        var dismissed = 0
        for id in selectedMemoryIDs {
            guard let node = (try? store.node(id: id)) ?? nil, !node.isDeleted else { continue }
            do {
                try store.softDeleteNode(id: id)
                snapshots.append(node)
                dismissed += 1
            } catch {
                lastActionError = "Couldn't dismiss every selected memory: \(error.localizedDescription)"
            }
        }
        if dismissed > 0 {
            recordUndo("Dismissed \(dismissed) \(dismissed == 1 ? "memory" : "memories")", restoring: snapshots)
        }
        setListSelection([])
        reloadMemories()
    }

    func dismissAllDrafts() {
        guard let store else { return }
        let drafts = draftMemories
        let ids = Set(drafts.map(\.id))
        var dismissed = 0
        for id in ids {
            do { try store.softDeleteNode(id: id); dismissed += 1 }
            catch { lastActionError = "Couldn't dismiss every draft: \(error.localizedDescription)" }
        }
        if dismissed > 0 {
            recordUndo("Dismissed \(dismissed) draft\(dismissed == 1 ? "" : "s")",
                       restoring: drafts.filter { ids.contains($0.id) })
        }
        if let selected = selectedMemoryID, ids.contains(selected) { selectedMemoryID = nil }
        reloadMemories()
        if draftMemories.isEmpty {
            listShowsDraftsOnly = false
        }
    }

    /// Confirm a draft and jump to the next one — for rapid keyboard review. Next is computed AFTER
    /// the mutation + reload, so it can't land on a just-purged duplicate.
    func confirmAndAdvance(_ node: MemoryNode) {
        confirm(node)
        selectedMemoryID = nextDraftID(after: node.id)
    }

    func dismissAndAdvance(_ node: MemoryNode) {
        delete(node)
        selectedMemoryID = nextDraftID(after: node.id)
    }

    private func nextDraftID(after id: String) -> String? {
        let drafts = filteredMemories.filter { $0.status == .draft }
        if let i = drafts.firstIndex(where: { $0.id == id }), i + 1 < drafts.count {
            return drafts[i + 1].id
        }
        return drafts.first(where: { $0.id != id })?.id
    }

    /// Edit a memory's title/summary; invalidates its embedding so it re-indexes semantically.
    func updateText(_ node: MemoryNode, title: String, summary: String, data: MemoryData? = nil) {
        guard let store else { return }
        let snapshot = (try? store.node(id: node.id)) ?? nil
        update(node) {
            $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only accept a payload of the node's own type — the editor can't change a memory's kind.
            if let data, data.type == $0.type { $0.data = data }
            $0.updatedAt = Date()
        }
        try? store.clearEmbedding(nodeId: node.id)
        if let snapshot { recordUndo("Edited “\(snapshot.title)”", restoring: [snapshot]) }
    }

    /// Bootstrap draft memories from the project's hand-written CLAUDE.md / .claude/rules — the
    /// conventions a team already maintains become reviewable drafts on day zero.
    func importClaudeMd(projectId: String) {
        guard let store else { return }
        guard let repoPath = MemoryAuditor.repoPath(forProjectId: projectId) else {
            lastActionError = "Couldn't find this project's local repo path."
            return
        }
        do {
            let outcome = try ClaudeMdImporter.importProject(
                projectPath: repoPath, projectId: projectId, store: store)
            processingStatus = outcome.created.isEmpty
                ? "Nothing new to import (\(outcome.duplicatesSkipped) already known)."
                : "Imported \(outcome.created.count) draft\(outcome.created.count == 1 ? "" : "s") from CLAUDE.md — review them in the inbox."
            lastActionError = nil
        } catch {
            lastActionError = "CLAUDE.md import failed: \(error.localizedDescription)"
        }
        reloadProjects()
    }

    /// Load the demo memories so a brand-new user can explore every view before their first capture.
    func loadSampleData() {
        guard let store else { return }
        suppressCelebrationOnce = true   // sample data is not a first capture
        let project = "github.com/acme/widgets"
        do {
            try store.upsert(SampleMemories.make(projectId: project))
            lastActionError = nil
        } catch {
            lastActionError = "Couldn't load sample data: \(error.localizedDescription)"
            return
        }
        reloadProjects()
        selectedProject = project
    }

    // MARK: - Capture draining

    /// Finder-launched apps don't inherit the shell environment, so pull `GEMINI_API_KEY` from the
    /// login shell if it isn't already set — otherwise the in-app classifier can't reach Gemini.
    private func ensureClassifierEnv() {
        guard (ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? "").isEmpty else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let key = Shell.run(shell, ["-lc", "printf %s \"$GEMINI_API_KEY\""])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { setenv("GEMINI_API_KEY", key, 1) }
    }

    /// While the app runs, periodically classify any sessions the hooks have queued.
    private func startAutoDrain() {
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drainOnce()
                await self?.runMaintenanceIfDue()
                // Idle-after-wake dreams ride the same tick: sleep pauses this loop, so the first
                // iterations after wake are exactly when "due tonight + idle long enough" can fire —
                // no separate wake observer needed.
                await self?.runDreamsIfDue()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func drainOnce() async {
        guard let store else { return }
        let report = await SessionIngestor.drainQueue(store: store, classifier: Classifiers.makeFromConfig())
        refreshQueueHealth()
        if report.added > 0 {
            reloadProjects()
            if AppConfigStore.loadBestEffort().notifyOnNewDrafts {
                Notifier.notifyNewDrafts(report.added)
            }
        }
        if report.failures > 0 {
            // Failed rows retry on later drains (bounded by maxAttempts), so this resolves itself
            // when transient — but a misconfigured classifier would otherwise fail silently forever.
            lastActionError = "\(report.failures) queued session(s) failed to classify — check Settings → Classifier."
        }
    }

    /// Once per day per project, without being asked: the deterministic reality-check audit
    /// (corroborates memories whose files still check out, feeds drift into the belief model) plus
    /// a conflict sweep. Staleness maintains itself; only genuinely drifted memories surface in
    /// Health for a human call.
    private func runMaintenanceIfDue() async {
        guard let store else { return }
        let defaults = UserDefaults.standard
        for project in (try? store.projects()) ?? [] {
            let key = "Hypermnesia.lastMaintenance.\(project)"
            let last = defaults.object(forKey: key) as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) > 86_400 else { continue }
            defaults.set(Date(), forKey: key)
            let changed = await Task.detached { () -> Bool in
                var didWork = false
                if let repoPath = MemoryAuditor.repoPath(forProjectId: project) {
                    let findings = MemoryAuditor.audit(store: store, projectId: project, repoPath: repoPath)
                    didWork = MemoryAuditor.apply(findings, store: store) > 0 || didWork
                    let outcomes = MemoryAuditor.recordOutcomes(findings, store: store, projectId: project)
                    didWork = outcomes.corroborated > 0 || outcomes.drifted > 0 || didWork
                }
                didWork = ConflictEngine.sweep(store: store, projectId: project) > 0 || didWork
                return didWork
            }.value
            if changed, project == selectedProject { reloadMemories() }
        }
    }

    /// Funnel every not-yet-processed historical session through the capture queue, then drain —
    /// the "Process previous sessions…" action.
    /// Sessions the next backfill would classify. Non-nil ⇒ the consent dialog is showing.
    var backfillProposal: BackfillProposal?

    /// Phase 1 of "Process previous sessions": read-only discovery, then ask —
    /// the run costs one classifier call per session on the user's key, so the count and the cost
    /// are shown before anything burns.
    func processPreviousSessions() {
        guard !isProcessing, let store else { return }
        isProcessing = true
        processingStatus = "Scanning sessions…"
        Task { [weak self] in
            guard let self else { return }
            let proposal = await Task.detached { () -> BackfillProposal in
                var candidates: [BackfillCandidate] = []
                // Shared per-session gate, mirroring the CLI's `backfill --all`: already-processed
                // and in-flight sessions are skipped (a live session isn't sealed mid-work — its
                // own hooks finish it), as are sessions whose workspace can't be recovered or is
                // a throwaway temp dir.
                func propose(sessionId: String, url: URL, modifiedAt: Date, cwd: String?) {
                    guard let cwd else { return }
                    candidates.append(.init(
                        sessionId: sessionId, transcript: url, modifiedAt: modifiedAt, cwd: cwd))
                }

                for t in ClaudeCodeSessions.allTranscripts() {
                    propose(sessionId: t.sessionId, url: t.url, modifiedAt: t.modifiedAt,
                            cwd: ClaudeCodeSessions.firstCwd(of: t.url))
                }
                // Cursor transcripts carry no cwd — recover it from the (lossy) encoded project
                // directory name, once per directory; unrecoverable dirs are skipped by the gate.
                var decodedDirs: [String: String?] = [:]
                for (encodedDir, t) in CursorSessions.allTranscriptsByProjectDir() {
                    let cwd = decodedDirs[encodedDir] ?? {
                        let value = CursorSessions.decode(encodedDir: encodedDir)
                        decodedDirs[encodedDir] = value
                        return value
                    }()
                    propose(sessionId: t.sessionId, url: t.url, modifiedAt: t.modifiedAt, cwd: cwd)
                }
                // Antigravity transcripts carry no cwd either — the workspace comes from each
                // transcript's own tool-call args.
                for t in AntigravitySessions.allTranscripts() {
                    propose(sessionId: t.sessionId, url: t.url, modifiedAt: t.modifiedAt,
                            cwd: AntigravitySessions.firstCwd(of: t.url))
                }
                return BackfillProposalService.discover(candidates, store: store)
            }.value

            self.isProcessing = false
            if proposal.count == 0 {
                self.processingStatus = "No new sessions found."
            } else {
                self.processingStatus = nil
                self.backfillProposal = proposal   // the UI shows the consent dialog
            }
        }
    }

    func cancelBackfill() {
        backfillProposal = nil
        processingStatus = "Backfill cancelled — no sessions were queued."
    }

    /// Phase 2: the user said yes — classify everything queued, narrating per-session progress,
    /// and land a first-ever backfill on the MRI so they watch their history light up.
    /// Snapshot+enqueue copies can take seconds on large histories; keep that off the MainActor.
    func confirmBackfill() {
        guard let store, let proposal = backfillProposal else { return }
        backfillProposal = nil
        guard !isProcessing else { return }
        // The first dream runs over the project the backfill enriched most — decided now, priced
        // into the consent dialog the user just accepted ("+ 1 dream pass").
        let firstDreamProject = willRunFirstDream ? Self.dominantProject(in: proposal) : nil
        isProcessing = true
        let wasEmpty = projects.isEmpty
        let count = proposal.count
        processingStatus = "Queuing \(count) session\(count == 1 ? "" : "s")…"
        Task { [weak self] in
            guard let self else { return }
            let enqueued = await Task.detached {
                BackfillProposalService.enqueue(proposal, store: store)
            }.value
            guard enqueued > 0 else {
                self.isProcessing = false
                self.processingStatus = "No new sessions found."
                return
            }
            self.processingStatus = "Classifying \(enqueued) session\(enqueued == 1 ? "" : "s")…"
            let report = await Task.detached {
                await SessionIngestor.drainQueue(
                    store: store, classifier: Classifiers.makeFromConfig(),
                    progress: { processed, totalPending, added in
                        Task { @MainActor [weak self] in
                            self?.processingStatus =
                                "Classifying session \(min(processed + 1, totalPending)) of \(totalPending) · \(added) memories so far"
                        }
                    }
                )
            }.value

            self.reloadProjects()
            self.isProcessing = false
            if report.failures > 0 {
                // Truthful over tidy: "Up to date." after a classifier failure reads as success.
                self.processingStatus = "Added \(report.added) memories; \(report.failures) session(s) failed to classify."
                self.lastActionError = "\(report.failures) session(s) failed to classify — check Settings → Classifier."
            } else {
                self.processingStatus = report.added > 0 ? "Added \(report.added) memories." : "Done."
            }
            // The payoff moment: a first-ever backfill ends on the MRI with the history visible…
            if wasEmpty, report.added > 0 {
                self.browseMode = .mri
            }
            // …and the corpus is at its richest, so the first-ever dream runs right now (one extra
            // call, already shown in the consent dialog). A quiet first dream stays silent.
            if report.added > 0, let firstDreamProject {
                await self.runFirstDream(project: firstDreamProject)
            }
        }
    }

    /// The project a backfill proposal touches most — where the first dream will look.
    static func dominantProject(in proposal: BackfillProposal) -> String? {
        let grouped = Dictionary(grouping: proposal.candidates) { ProjectIdentity.resolve(cwd: $0.cwd) }
        return grouped.max { $0.value.count < $1.value.count }?.key
    }

    /// Reality-check the selected project's memories against its current code, flagging stale ones.
    /// `deep` additionally asks the configured model whether each memory still holds (the CLI's
    /// `audit --deep`) — slower and costs classifier calls, so it's a separate button.
    func runAudit(deep: Bool = false) {
        guard !isProcessing, let store, let project = selectedProject else { return }
        isProcessing = true
        processingStatus = "Locating project…"
        Task { [weak self] in
            guard let self else { return }
            if deep { self.processingStatus = "Deep check: asking the model about each memory…" }
            let result = await Task.detached { () -> (issues: Int, flagged: Int)? in
                guard let repoPath = MemoryAuditor.repoPath(forProjectId: project) else { return nil }
                var findings = MemoryAuditor.audit(store: store, projectId: project, repoPath: repoPath)
                if deep {
                    findings += await MemoryAuditor.verify(
                        store: store, projectId: project, repoPath: repoPath,
                        completer: Completers.makeFromConfig())
                }
                let flagged = MemoryAuditor.apply(findings, store: store)
                // Fold the reality-check into the belief model: corroborate memories whose files are
                // present/unchanged, flag drift on the rest (idempotent — no compounding on re-run).
                _ = MemoryAuditor.recordOutcomes(findings, store: store, projectId: project)
                return (findings.count, flagged)
            }.value

            self.reloadMemories()
            self.isProcessing = false
            if let result {
                self.processingStatus = result.issues == 0
                    ? "Reality check: no issues."
                    : "Reality check: flagged \(result.flagged) memories (\(result.issues) issues)."
            } else {
                self.processingStatus = "Couldn't find this project's local repo path."
            }
        }
    }
}
