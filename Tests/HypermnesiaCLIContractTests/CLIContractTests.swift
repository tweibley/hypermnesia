import Foundation
import Testing
import HypermnesiaKit
#if canImport(Darwin)
import Darwin
#endif

@Suite("Hypermnesia CLI subprocess contracts")
struct CLIContractTests {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func cliURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["HYPERMNESIA_CLI_CONTRACT_BIN"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        // SwiftPM puts executable products beside the loaded test bundle in the active build
        // directory. Swift Testing itself runs through `swiftpm-testing-helper`, so argv[0] is not
        // useful here; loaded bundles identify the actual custom/architecture-qualified build path.
        var roots = Bundle.allBundles.flatMap { bundle in
            [bundle.bundleURL, bundle.executableURL].compactMap { $0 }
        }
#if canImport(Darwin)
        // Swift Testing loads the test product into `swiftpm-testing-helper` without registering it
        // as a Foundation bundle. dyld's image list still contains the exact test-product path.
        roots += (0..<_dyld_image_count()).compactMap { index in
            _dyld_get_image_name(index).map { URL(fileURLWithPath: String(cString: $0)) }
        }
#endif
        for root in roots {
            var directory = root.resolvingSymlinksInPath()
            while directory.path != "/" {
                let candidate = directory.appendingPathComponent("hypermnesia")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [
            NSFilePathErrorKey: roots.map(\.path).joined(separator: ":"),
            NSLocalizedDescriptionKey: "SwiftPM did not build the hypermnesia executable for CLI contract tests",
        ])
    }

    private func profile(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypermnesia-cli-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(
        _ arguments: [String],
        profile: URL,
        input: Data = Data(),
        workingDirectory: URL? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = try cliURL()
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory ?? packageRoot

        var environment = ProcessInfo.processInfo.environment
        environment["HYPERMNESIA_SUPPORT_DIR"] = profile.path
        environment.removeValue(forKey: "HYPERTHYMESIA_SUPPORT_DIR")
        environment.removeValue(forKey: "HYPERMNESIA_DISABLE")
        environment.removeValue(forKey: "HYPERTHYMESIA_DISABLE")
        environment.removeValue(forKey: "HYPERMNESIA_DEBUG")
        environment.removeValue(forKey: "HYPERTHYMESIA_DEBUG")
        for credential in [
            "GEMINI_API_KEY", "GOOGLE_API_KEY", "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
        ] {
            environment.removeValue(forKey: credential)
        }
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if !input.isEmpty { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func json(_ object: [String: Any], newline: Bool = false) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if newline { data.append(0x0A) }
        return data
    }

    @Test("capture enqueues a final session without invoking a model")
    func captureContract() throws {
        let support = try profile("capture")
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = support.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let transcript = support.appendingPathComponent("session.jsonl")
        try #"{"type":"summary","summary":"valid empty session"}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let input = try json([
            "session_id": "capture-session",
            "cwd": workspace.path,
            "transcript_path": transcript.path,
            "hook_event_name": "SessionEnd",
        ])

        let result = try run(["capture"], profile: support, input: input, workingDirectory: workspace)

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        let store = try MemoryStore(location: .file(support.appendingPathComponent("memory.db")))
        let queued = try #require(try store.pendingCaptures(limit: 10).first)
        #expect(queued.sessionId == "capture-session")
        #expect(queued.isFinal)
        #expect(queued.source == .live)
    }

    @Test("hydrate emits Claude hook JSON from an isolated confirmed store")
    func hydrateContract() throws {
        let support = try profile("hydrate")
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = support.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let projectId = ProjectIdentity.resolve(cwd: workspace.path)
        let store = try MemoryStore(location: .file(support.appendingPathComponent("memory.db")))
        try store.upsert(MemoryNode(
            projectId: projectId, type: .fact, status: .confirmed,
            title: "Runtime", summary: "The runtime is Swift",
            data: .fact(.init(category: "stack", key: "runtime", value: "Swift"))
        ))
        let input = try json([
            "session_id": "hydrate-session",
            "cwd": workspace.path,
            "hook_event_name": "SessionStart",
        ])

        let result = try run(["hydrate"], profile: support, input: input, workingDirectory: workspace)

        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let hook = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(hook["hookEventName"] as? String == "SessionStart")
        #expect((hook["additionalContext"] as? String)?.contains("runtime: Swift") == true)
    }

    @Test("drain exits cleanly on an empty isolated queue")
    func drainContract() throws {
        let support = try profile("drain")
        defer { try? FileManager.default.removeItem(at: support) }

        let result = try run(["drain"], profile: support)

        #expect(result.status == 0)
        #expect(result.stdout.contains("Nothing to do."))
        #expect(result.stderr.isEmpty)
        let store = try MemoryStore(location: .file(support.appendingPathComponent("memory.db")))
        #expect(try store.captureQueueHealth() == .empty)
    }

    @Test("session-event appends the normalized event without protocol noise")
    func sessionEventContract() throws {
        let support = try profile("session-event")
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = support.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let input = try json([
            "session_id": "event-session",
            "cwd": workspace.path,
            "hook_event_name": "Notification",
            "message": "Claude needs permission to run tests",
        ])

        let result = try run(["session-event"], profile: support, input: input, workingDirectory: workspace)

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        let event = try #require(SessionEventLog.recent(in: support).last)
        #expect(event.sessionId == "event-session")
        #expect(event.kind == .attention)
        #expect(event.needsPermission)
    }

    @Test("MCP uses newline-delimited JSON-RPC and suppresses notification responses")
    func mcpFramingContract() throws {
        let support = try profile("mcp")
        defer { try? FileManager.default.removeItem(at: support) }
        var input = Data()
        input.append(try json([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ], newline: true))
        input.append(try json([
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ], newline: true))
        input.append(try json([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list",
        ], newline: true))

        let result = try run(["mcp"], profile: support, input: input)

        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        #expect(lines.count == 2)
        let responses = try lines.map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(responses.compactMap { $0["id"] as? Int } == [1, 2])
        #expect(responses.allSatisfy { ($0["jsonrpc"] as? String) == "2.0" })
        let toolsResult = try #require(responses[1]["result"] as? [String: Any])
        let tools = (toolsResult["tools"] as? [[String: Any]]) ?? []
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["recall", "ask", "remember"])
    }
}
