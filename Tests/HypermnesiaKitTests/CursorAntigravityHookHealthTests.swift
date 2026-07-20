import Foundation
import Testing
@testable import HypermnesiaKit

/// Regression cover for the "moved app / translocated bundle" silent-failure bug extended to the
/// Cursor and Antigravity installers: like Claude Code's HookInstaller, their hooks record an
/// absolute CLI path inside the app bundle, and `isInstalled` was a mere presence check that never
/// verified the binary still exists. A moved app left Cursor / Antigravity capture silently dead
/// while `isInstalled` / doctor reported "installed ✓".
@Suite("Cursor + Antigravity hook health")
struct CursorAntigravityHookHealthTests {

    /// A temp project dir plus a real executable standing in for the app-bundled CLI.
    private func makeFixture(prefix: String) throws -> (dir: URL, binary: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binDir = dir.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binary = binDir.appendingPathComponent("hypermnesia")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (dir, binary)
    }

    @Test("Cursor: hasMissingBinary detects a dangling recorded CLI path (moved app)")
    func cursorMissingBinaryDetected() throws {
        let (dir, binary) = try makeFixture(prefix: "cursor-health")
        defer { try? FileManager.default.removeItem(at: dir) }

        try CursorHookInstaller.install(binaryPath: binary.path, projectPath: dir.path)
        #expect(CursorHookInstaller.isInstalled(projectPath: dir.path))
        // Every hook records the same binary; the distinct set is exactly that one path.
        #expect(CursorHookInstaller.installedBinaryPaths(projectPath: dir.path) == [binary.path])
        #expect(!CursorHookInstaller.hasMissingBinary(projectPath: dir.path))
        #expect(CursorHookInstaller.missingBinaryPaths(projectPath: dir.path).isEmpty)

        // Simulate moving/removing the app: the recorded path dangles, but hooks stay in hooks.json.
        try FileManager.default.removeItem(at: binary)
        #expect(CursorHookInstaller.isInstalled(projectPath: dir.path))
        #expect(CursorHookInstaller.hasMissingBinary(projectPath: dir.path))
        #expect(CursorHookInstaller.missingBinaryPaths(projectPath: dir.path) == [binary.path])
    }

    @Test("Cursor: no false positive when hooks are absent")
    func cursorNoHooksNoMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-cursor-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!CursorHookInstaller.isInstalled(projectPath: dir.path))
        #expect(CursorHookInstaller.installedBinaryPaths(projectPath: dir.path).isEmpty)
        #expect(!CursorHookInstaller.hasMissingBinary(projectPath: dir.path))
    }

    @Test("Antigravity: hasMissingBinary detects a dangling recorded CLI path (moved app)")
    func antigravityMissingBinaryDetected() throws {
        let (dir, binary) = try makeFixture(prefix: "agy-health")
        defer { try? FileManager.default.removeItem(at: dir) }

        try AntigravityHookInstaller.install(binaryPath: binary.path, projectPath: dir.path)
        #expect(AntigravityHookInstaller.isInstalled(projectPath: dir.path))
        #expect(AntigravityHookInstaller.installedBinaryPaths(projectPath: dir.path) == [binary.path])
        #expect(!AntigravityHookInstaller.hasMissingBinary(projectPath: dir.path))
        #expect(AntigravityHookInstaller.missingBinaryPaths(projectPath: dir.path).isEmpty)

        try FileManager.default.removeItem(at: binary)
        #expect(AntigravityHookInstaller.isInstalled(projectPath: dir.path))
        #expect(AntigravityHookInstaller.hasMissingBinary(projectPath: dir.path))
        #expect(AntigravityHookInstaller.missingBinaryPaths(projectPath: dir.path) == [binary.path])
    }

    @Test("Antigravity: no false positive when hooks are absent")
    func antigravityNoHooksNoMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ht-agy-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!AntigravityHookInstaller.isInstalled(projectPath: dir.path))
        #expect(AntigravityHookInstaller.installedBinaryPaths(projectPath: dir.path).isEmpty)
        #expect(!AntigravityHookInstaller.hasMissingBinary(projectPath: dir.path))
    }
}
