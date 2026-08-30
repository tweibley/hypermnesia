import Foundation
import Network

/// A deliberately tiny read-only static-file HTTP server for the visual-explainer diagram
/// gallery (`~/.agent/diagrams`). This is the "easter egg" behind Settings → Diagrams: the
/// section only appears once the gallery's `index.html` exists, and the server never runs
/// unless the user flips it on.
///
/// Scope is intentionally narrow: GET/HEAD only, no directory listings, no writes, files must
/// resolve inside the root after symlink resolution (so a symlink planted in the gallery can't
/// leak files outside it). Binds to loopback by default; binding beyond loopback is an explicit
/// user choice in Settings.
public final class DiagramServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var root: URL
        /// Local address to bind ("127.0.0.1" = this Mac only, "0.0.0.0" = all interfaces).
        public var bindAddress: String
        /// TCP port; 0 asks the kernel for an ephemeral port (used by tests).
        public var port: UInt16

        public init(root: URL = DiagramServer.defaultRoot, bindAddress: String = "127.0.0.1", port: UInt16 = 3742) {
            self.root = root
            self.bindAddress = bindAddress
            self.port = port
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case running(port: UInt16)
        case failed(String)
        case stopped
    }

    /// Where the visual-explainer skill writes its pages and auto-generated `index.html`.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent/diagrams", isDirectory: true)
    }

    /// The easter-egg trigger: the gallery index the skill maintains.
    public static func indexExists(root: URL = defaultRoot) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path)
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "hypermnesia.diagram-server")
    private var listener: NWListener?
    /// Root with symlinks resolved once at start; every served path must stay under it.
    private let resolvedRootPath: String
    private let stateHandler: @Sendable (State) -> Void

    public init(configuration: Configuration, onStateChange: @escaping @Sendable (State) -> Void = { _ in }) {
        self.configuration = configuration
        self.resolvedRootPath = configuration.root.resolvingSymlinksInPath().path
        self.stateHandler = onStateChange
    }

    /// Bind and start accepting connections. Failures after this point (port in use, permission)
    /// surface asynchronously through `onStateChange`.
    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw DiagramServerError.invalidPort(Int(configuration.port))
        }
        // requiredLocalEndpoint is what scopes the bind: loopback-only unless the user chose
        // otherwise. "0.0.0.0" means INADDR_ANY, which NWListener handles natively.
        if configuration.bindAddress != "0.0.0.0" {
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(configuration.bindAddress), port: port)
        }
        let listener: NWListener
        do {
            listener = configuration.bindAddress == "0.0.0.0"
                ? try NWListener(using: parameters, on: port)
                : try NWListener(using: parameters)
        } catch {
            throw DiagramServerError.bindFailed(error.localizedDescription)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateHandler(.running(port: listener.port?.rawValue ?? self.configuration.port))
            case .failed(let error):
                self.stateHandler(.failed(error.localizedDescription))
                listener.cancel()
            case .cancelled:
                self.stateHandler(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// The bound port once the listener is ready (resolves ephemeral port 0).
    public var boundPort: UInt16? {
        queue.sync { listener?.port?.rawValue }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }

    deinit {
        listener?.cancel()
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffered: Data())
    }

    /// Accumulate until the end of the request head. Bodies are irrelevant (GET/HEAD only) and
    /// a runaway header block is cut off at 16 KB.
    private func receiveRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if error != nil || buffer.count > 16 * 1024 {
                connection.cancel()
                return
            }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, requestHead: buffer)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receiveRequest(connection, buffered: buffer)
        }
    }

    private func respond(_ connection: NWConnection, requestHead: Data) {
        guard let head = String(data: requestHead, encoding: .utf8),
              let requestLine = head.components(separatedBy: "\r\n").first else {
            send(connection, response: Self.response(status: "400 Bad Request", body: Self.errorPage("Bad request")))
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(connection, response: Self.response(status: "400 Bad Request", body: Self.errorPage("Bad request")))
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])
        guard method == "GET" || method == "HEAD" else {
            send(connection, response: Self.response(
                status: "405 Method Not Allowed", body: Self.errorPage("Method not allowed"),
                extraHeaders: ["Allow": "GET, HEAD"]))
            return
        }
        let response: Data
        switch Self.resolve(target: target, resolvedRootPath: resolvedRootPath) {
        case .file(let url, let contentType):
            if let bytes = try? Data(contentsOf: url) {
                response = Self.response(status: "200 OK", body: bytes, contentType: contentType, headOnly: method == "HEAD")
            } else {
                response = Self.response(status: "404 Not Found", body: Self.errorPage("Not found"), headOnly: method == "HEAD")
            }
        case .notFound:
            response = Self.response(status: "404 Not Found", body: Self.errorPage("Not found"), headOnly: method == "HEAD")
        case .forbidden:
            response = Self.response(status: "403 Forbidden", body: Self.errorPage("Forbidden"), headOnly: method == "HEAD")
        }
        send(connection, response: response)
    }

    private func send(_ connection: NWConnection, response: Data) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Request → file resolution (pure; unit-tested)

    enum Resolution: Equatable {
        case file(URL, contentType: String)
        case notFound
        case forbidden
    }

    /// Map a request target onto a file inside the root, or refuse. Every candidate is symlink-
    /// resolved and must stay under the resolved root — this rejects both `..` traversal and
    /// symlinks that point outside the gallery.
    static func resolve(target: String, resolvedRootPath: String) -> Resolution {
        // Strip query/fragment, then percent-decode the path (the index links to file names
        // with spaces and such).
        let rawPath = target.prefix { $0 != "?" && $0 != "#" }
        guard let decoded = String(rawPath).removingPercentEncoding, !decoded.contains("\0") else {
            return .forbidden
        }
        guard decoded.hasPrefix("/") else { return .forbidden }

        let root = URL(fileURLWithPath: resolvedRootPath, isDirectory: true)
        var candidate = root.appendingPathComponent(String(decoded.dropFirst())).standardizedFileURL

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            candidate = candidate.appendingPathComponent("index.html")
        }

        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path == resolvedRootPath || resolved.path.hasPrefix(resolvedRootPath + "/") else {
            return .forbidden
        }
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .notFound
        }
        return .file(resolved, contentType: contentType(for: resolved.pathExtension))
    }

    static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "ico": "image/x-icon"
        case "txt", "md": "text/plain; charset=utf-8"
        case "woff2": "font/woff2"
        case "pdf": "application/pdf"
        case "mp4": "video/mp4"
        default: "application/octet-stream"
        }
    }

    private static func errorPage(_ message: String) -> Data {
        Data("<!doctype html><meta charset=\"utf-8\"><title>\(message)</title><p style=\"font: 15px -apple-system, sans-serif; margin: 3em\">\(message)</p>".utf8)
    }

    private static func response(
        status: String,
        body: Data,
        contentType: String = "text/html; charset=utf-8",
        extraHeaders: [String: String] = [:],
        headOnly: Bool = false
    ) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // The gallery index is regenerated in place by the skill — never let a browser cache
        // hide a fresh diagram behind a stale copy.
        head += "Cache-Control: no-cache\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        if !headOnly { response.append(body) }
        return response
    }
}

public enum DiagramServerError: Error, Sendable, Equatable, LocalizedError {
    case invalidPort(Int)
    case bindFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port): "Invalid port \(port) — use 1–65535."
        case .bindFailed(let reason): "Could not start the diagram server: \(reason)"
        }
    }
}
