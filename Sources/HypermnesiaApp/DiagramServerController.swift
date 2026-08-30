import Foundation
import HypermnesiaKit

/// Owns the diagram-gallery web server's lifecycle in the app process: starts it at launch when
/// enabled, and restarts/stops it whenever Settings changes the config. The server itself lives
/// in the kit (`DiagramServer`); this maps `AppConfig` onto a running instance and exposes
/// observable state for the Settings section.
@MainActor
@Observable
final class DiagramServerController {
    static let shared = DiagramServerController()

    enum Status: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private var server: DiagramServer?
    /// The config the running server was started with, so a save that didn't touch the server
    /// fields (most saves) doesn't bounce open connections.
    private var applied: (bind: String, port: Int)?

    /// Call once at launch; re-applies on every config change thereafter.
    func bootstrap() {
        NotificationCenter.default.addObserver(
            forName: .hypermnesiaConfigChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in DiagramServerController.shared.apply() }
        }
        apply()
    }

    /// The browsable URL while running. Always localhost — that works for every bind address.
    var localURL: URL? {
        guard case .running(let port) = status else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/")
    }

    func apply() {
        let config = AppConfigStore.loadBestEffort()
        guard config.diagramServerEnabled, DiagramServer.indexExists() else {
            stopServer()
            return
        }
        let desired = (bind: config.diagramServerBind, port: config.diagramServerPort)
        if server != nil, applied?.bind == desired.bind, applied?.port == desired.port,
           status != .stopped, !isFailed {
            return
        }
        stopServer()
        guard let port = UInt16(exactly: desired.port), port > 0 else {
            status = .failed("Invalid port \(desired.port) — use 1–65535.")
            return
        }
        status = .starting
        let server = DiagramServer(
            configuration: .init(bindAddress: desired.bind, port: port)
        ) { state in
            Task { @MainActor in
                // Ignore stale callbacks from a server we already replaced or stopped.
                guard DiagramServerController.shared.server != nil else { return }
                switch state {
                case .running(let port): DiagramServerController.shared.status = .running(port: port)
                case .failed(let reason): DiagramServerController.shared.status = .failed(reason)
                case .stopped: DiagramServerController.shared.status = .stopped
                case .idle: break
                }
            }
        }
        do {
            try server.start()
            self.server = server
            self.applied = desired
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func stopServer() {
        server?.stop()
        server = nil
        applied = nil
        status = .stopped
    }
}
