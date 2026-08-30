import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("DiagramServer")
struct DiagramServerTests {

    private func makeGallery(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-diagrams-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<html><title>Gallery</title></html>".utf8)
            .write(to: dir.appendingPathComponent("index.html"))
        try Data("body { color: red }".utf8).write(to: dir.appendingPathComponent("style.css"))
        return dir
    }

    // MARK: - Resolution (pure)

    @Test("root and explicit paths resolve to files with the right content type")
    func resolvesFiles() throws {
        let dir = try makeGallery("resolve")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.resolvingSymlinksInPath().path

        guard case .file(let index, let indexType) = DiagramServer.resolve(target: "/", resolvedRootPath: root) else {
            Issue.record("root did not resolve"); return
        }
        #expect(index.lastPathComponent == "index.html")
        #expect(indexType.hasPrefix("text/html"))

        guard case .file(_, let cssType) = DiagramServer.resolve(target: "/style.css?v=2", resolvedRootPath: root) else {
            Issue.record("css did not resolve"); return
        }
        #expect(cssType.hasPrefix("text/css"))

        // Percent-encoded names decode before hitting the filesystem.
        try Data("hi".utf8).write(to: dir.appendingPathComponent("my diagram.html"))
        #expect(DiagramServer.resolve(target: "/my%20diagram.html", resolvedRootPath: root) != .notFound)
    }

    @Test("missing files 404 without leaking whether parents exist")
    func missingIsNotFound() throws {
        let dir = try makeGallery("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.resolvingSymlinksInPath().path
        #expect(DiagramServer.resolve(target: "/nope.html", resolvedRootPath: root) == .notFound)
        #expect(DiagramServer.resolve(target: "/deep/nope.html", resolvedRootPath: root) == .notFound)
    }

    @Test("path traversal and symlink escapes are refused")
    func traversalRefused() throws {
        let dir = try makeGallery("traversal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.resolvingSymlinksInPath().path

        // A real file outside the root that traversal would otherwise reach.
        let secret = dir.deletingLastPathComponent().appendingPathComponent("ht-secret-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }

        let escape = "/../\(secret.lastPathComponent)"
        #expect(DiagramServer.resolve(target: escape, resolvedRootPath: root) == .forbidden)
        let encoded = "/%2e%2e/\(secret.lastPathComponent)"
        #expect(DiagramServer.resolve(target: encoded, resolvedRootPath: root) == .forbidden)

        // A symlink planted inside the gallery pointing out of it.
        let link = dir.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(DiagramServer.resolve(target: "/escape.txt", resolvedRootPath: root) == .forbidden)

        // Relative targets and NUL bytes never reach the filesystem.
        #expect(DiagramServer.resolve(target: "index.html", resolvedRootPath: root) == .forbidden)
        #expect(DiagramServer.resolve(target: "/a%00b", resolvedRootPath: root) == .forbidden)
    }

    @Test("indexExists reflects the gallery index file")
    func indexDetection() throws {
        let dir = try makeGallery("index")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DiagramServer.indexExists(root: dir))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("index.html"))
        #expect(!DiagramServer.indexExists(root: dir))
    }

    @Test("config fields default off and self-heal bad values")
    func configDefaults() throws {
        let empty = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(!empty.diagramServerEnabled)
        #expect(empty.diagramServerBind == "127.0.0.1")
        #expect(empty.diagramServerPort == 3742)

        let mangled = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"diagramServerBind": "  ", "diagramServerPort": 99999}"#.utf8))
        #expect(mangled.diagramServerBind == "127.0.0.1")
        #expect(mangled.diagramServerPort == 3742)
    }

    // MARK: - Live round trip

    @Test("serves the gallery over loopback: 200 index, 404 missing, 405 POST")
    func liveRoundTrip() async throws {
        let dir = try makeGallery("live")
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = DiagramServer(configuration: .init(root: dir, bindAddress: "127.0.0.1", port: 0))
        defer { server.stop() }
        try server.start()

        // Wait for the listener to bind and report its ephemeral port.
        var port: UInt16?
        for _ in 0..<100 {
            if let bound = server.boundPort, bound != 0 { port = bound; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let boundPort = try #require(port, "listener never became ready")
        let base = URL(string: "http://127.0.0.1:\(boundPort)")!

        let (body, response) = try await URLSession.shared.data(from: base)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(data: body, encoding: .utf8)?.contains("Gallery") == true)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)

        let (_, missing) = try await URLSession.shared.data(from: base.appendingPathComponent("nope.html"))
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)

        var post = URLRequest(url: base)
        post.httpMethod = "POST"
        let (_, postResponse) = try await URLSession.shared.data(for: post)
        #expect((postResponse as? HTTPURLResponse)?.statusCode == 405)
    }
}
