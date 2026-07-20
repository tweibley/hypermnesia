import Foundation
import Testing
@testable import HypermnesiaKit

/// Regression cover for the "moved app / translocated bundle" silent-failure bug: hooks recorded in
/// settings.json point at an absolute CLI path inside the app bundle, and every install-state check
/// was a substring match on the command string that never verified the binary still exists. A moved
/// app left capture + hydration silently dead while `isInstalled` / doctor / Settings all reported
/// "installed ✓".
@Suite("BugFix H1 install health")
struct BugFixH1InstallHealthTests {

    private func makeProjectDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-h1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        return dir
    }

    @Test("recordedBinaryPath unwraps the shell-quoted leading token")
    func recordedBinaryPathParsing() {
        #expect(HookInstaller.recordedBinaryPath(inCommand: "'/usr/local/bin/hypermnesia' hydrate")
                == "/usr/local/bin/hypermnesia")
        // The capture command has a trailing pipeline; only the leading binary is recovered.
        #expect(HookInstaller.recordedBinaryPath(
            inCommand: "'/Applications/Hypermnesia.app/Contents/Resources/hypermnesia' capture; (echo hi &)")
                == "/Applications/Hypermnesia.app/Contents/Resources/hypermnesia")
        // An embedded single quote survives the `'\''` escape round-trip.
        let quoted = ConfigFile.shellQuote("/Users/o'brien/hypermnesia")
        #expect(HookInstaller.recordedBinaryPath(inCommand: "\(quoted) hydrate")
                == "/Users/o'brien/hypermnesia")
        // Not one of our commands.
        #expect(HookInstaller.recordedBinaryPath(inCommand: "echo hello") == nil)
    }

    @Test("hasMissingBinary detects a dangling recorded CLI path (moved app)")
    func missingBinaryDetected() throws {
        let dir = try makeProjectDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Stand in for the app-bundled CLI: a real executable whose name carries the marker.
        let binDir = dir.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binary = binDir.appendingPathComponent("hypermnesia")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        try HookInstaller.install(binaryPath: binary.path, projectPath: dir.path)
        #expect(HookInstaller.isInstalled(projectPath: dir.path))
        // Every hook records the same binary; the distinct set is exactly that one path.
        #expect(HookInstaller.installedBinaryPaths(projectPath: dir.path) == [binary.path])
        // Healthy while the binary exists.
        #expect(!HookInstaller.hasMissingBinary(projectPath: dir.path))
        #expect(HookInstaller.missingBinaryPaths(projectPath: dir.path).isEmpty)

        // Simulate moving/removing the app: the recorded path is now dangling, but the hooks are
        // still present in settings.json — the exact false-positive the bug produced.
        try FileManager.default.removeItem(at: binary)
        #expect(HookInstaller.isInstalled(projectPath: dir.path))
        #expect(HookInstaller.hasMissingBinary(projectPath: dir.path))
        #expect(HookInstaller.missingBinaryPaths(projectPath: dir.path) == [binary.path])
    }

    @Test("no false positive when hooks are absent")
    func noHooksNoMissing() throws {
        let dir = try makeProjectDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!HookInstaller.isInstalled(projectPath: dir.path))
        #expect(HookInstaller.installedBinaryPaths(projectPath: dir.path).isEmpty)
        #expect(!HookInstaller.hasMissingBinary(projectPath: dir.path))
    }
}
