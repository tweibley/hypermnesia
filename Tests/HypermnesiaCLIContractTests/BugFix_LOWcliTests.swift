import Foundation
import Testing
import HypermnesiaKit
#if canImport(Darwin)
import Darwin
#endif

/// Regression coverage for the LOW-cli bug cluster:
///  1. `backfill --project <path> --all` must be rejected instead of silently ignoring --project
///     and running the (expensive, machine-wide) `--all` backfill.
///  2. The MCP stdio server must handle requests concurrently — a slow in-flight call must not
///     block other requests — while keeping newline-delimited JSON-RPC framing intact and still
///     answering every id. Concurrency means responses may legally come back out of order, so
///     these assertions index responses by id rather than by position.
@Suite("Hypermnesia LOW-cli bug fixes")
struct BugFixLOWcliTests {
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
        var roots = Bundle.allBundles.flatMap { bundle in
            [bundle.bundleURL, bundle.executableURL].compactMap { $0 }
        }
#if canImport(Darwin)
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
            .appendingPathComponent("hypermnesia-lowcli-\(label)-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Bug 1: backfill mutual exclusion

    @Test("backfill rejects --project and --all together instead of silently running machine-wide")
    func backfillRejectsProjectPlusAll() throws {
        let support = try profile("backfill-both")
        defer { try? FileManager.default.removeItem(at: support) }
        let repo = support.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        let result = try run(["backfill", "--project", repo.path, "--all", "--dry-run"], profile: support)

        // Must fail loudly (ArgumentParser validation exit) rather than proceed to a machine-wide run.
        #expect(result.status != 0)
        let combined = result.stdout + result.stderr
        #expect(combined.contains("not both"))
        // It must NOT have started the machine-wide path.
        #expect(!combined.contains("across all projects"))
    }

    @Test("backfill still accepts --project on its own")
    func backfillAcceptsProjectAlone() throws {
        let support = try profile("backfill-project")
        defer { try? FileManager.default.removeItem(at: support) }
        let repo = support.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        // Dry-run against an empty temp repo: no transcripts, so this is deterministic and cheap.
        let result = try run(["backfill", "--project", repo.path, "--dry-run"], profile: support,
                             workingDirectory: repo)

        #expect(result.status == 0)
        #expect(result.stdout.contains("Project:"))
        #expect(result.stdout.contains("dry run"))
    }

    // MARK: - Bug 2: MCP concurrent request handling preserves framing and answers every id

    @Test("MCP answers every concurrent request with intact framing, indexed by id")
    func mcpConcurrentFramingById() throws {
        let support = try profile("mcp-concurrent")
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = support.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var input = Data()
        input.append(try json([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ], newline: true))
        // A notification: no id, must not produce a response even under concurrency.
        input.append(try json([
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ], newline: true))
        input.append(try json([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list",
        ], newline: true))
        input.append(try json([
            "jsonrpc": "2.0", "id": 3, "method": "ping",
        ], newline: true))
        input.append(try json([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "recall", "arguments": ["query": "storage conventions"]],
        ], newline: true))

        let result = try run(["mcp"], profile: support, input: input, workingDirectory: workspace)

        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)

        // Each output line must be a complete, independently-parseable JSON-RPC object (framing intact).
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        let responses = try lines.map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        // Exactly the four requests that carry an id get a response; the notification is suppressed.
        var byId: [Int: [String: Any]] = [:]
        for response in responses {
            #expect((response["jsonrpc"] as? String) == "2.0")
            if let id = response["id"] as? Int { byId[id] = response }
        }
        #expect(Set(byId.keys) == [1, 2, 3, 4])

        // Order-independent correctness checks, keyed by id (responses may arrive in any order).
        let initResult = try #require(byId[1]?["result"] as? [String: Any])
        #expect(initResult["serverInfo"] != nil)

        let toolsResult = try #require(byId[2]?["result"] as? [String: Any])
        let tools = (toolsResult["tools"] as? [[String: Any]]) ?? []
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["recall", "ask", "remember"])

        #expect(byId[3]?["result"] != nil)

        let recallResult = try #require(byId[4]?["result"] as? [String: Any])
        #expect(recallResult["content"] != nil)
    }
}
