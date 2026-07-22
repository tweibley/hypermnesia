import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("CLIToolInstaller")
struct CLIToolInstallerTests {

    /// A sandbox with a fake bin directory plus a fake app-bundle CLI to link against.
    private func sandbox(_ tag: String) throws -> (bin: URL, bundled: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ht-\(tag)-\(UUID().uuidString)")
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        let resources = root.appendingPathComponent("Hypermnesia.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let bundled = resources.appendingPathComponent("hypermnesia")
        try Data("#!/bin/sh\n".utf8).write(to: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        return (bin, bundled, root)
    }

    @Test("install creates the symlink (and the bin directory), and is idempotent")
    func installCreatesLink() throws {
        let (bin, bundled, root) = try sandbox("cli-install")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(CLIToolInstaller.status(bundledPath: bundled.path, binDirectory: bin) == .notInstalled)
        #expect(try CLIToolInstaller.install(bundledPath: bundled.path, binDirectory: bin) == .current)
        #expect(CLIToolInstaller.status(bundledPath: bundled.path, binDirectory: bin) == .current)

        let link = CLIToolInstaller.linkURL(binDirectory: bin)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(dest == bundled.path)

        // Idempotent: a second install stays current.
        #expect(try CLIToolInstaller.install(bundledPath: bundled.path, binDirectory: bin) == .current)
    }

    @Test("a link into an old app bundle is stale and gets re-pointed")
    func staleLinkRefreshed() throws {
        let (bin, bundled, root) = try sandbox("cli-stale")
        defer { try? FileManager.default.removeItem(at: root) }

        // Simulate an update/move: link points into a bundle path that no longer exists.
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = CLIToolInstaller.linkURL(binDirectory: bin)
        let gone = root.appendingPathComponent("Old.app/Contents/Resources/hypermnesia").path
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: gone)

        #expect(CLIToolInstaller.status(bundledPath: bundled.path, binDirectory: bin) == .stale)
        #expect(try CLIToolInstaller.install(bundledPath: bundled.path, binDirectory: bin) == .current)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == bundled.path)
    }

    @Test("a working link to a dev build is user-managed and never clobbered")
    func devLinkPreserved() throws {
        let (bin, bundled, root) = try sandbox("cli-dev")
        defer { try? FileManager.default.removeItem(at: root) }

        // The README's from-source flow: symlink to .build/debug/hypermnesia.
        let devBinary = root.appendingPathComponent(".build/debug/hypermnesia")
        try FileManager.default.createDirectory(at: devBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: devBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devBinary.path)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = CLIToolInstaller.linkURL(binDirectory: bin)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: devBinary.path)

        #expect(CLIToolInstaller.status(bundledPath: bundled.path, binDirectory: bin) == .userManaged)
        #expect(try CLIToolInstaller.install(bundledPath: bundled.path, binDirectory: bin) == .userManaged)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == devBinary.path)

        // Uninstall also refuses to touch it.
        try CLIToolInstaller.uninstall(binDirectory: bin)
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test("a regular file at the link path is user-managed")
    func regularFilePreserved() throws {
        let (bin, bundled, root) = try sandbox("cli-file")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = CLIToolInstaller.linkURL(binDirectory: bin)
        try Data("real binary".utf8).write(to: link)

        #expect(CLIToolInstaller.status(bundledPath: bundled.path, binDirectory: bin) == .userManaged)
        #expect(try CLIToolInstaller.install(bundledPath: bundled.path, binDirectory: bin) == .userManaged)
        #expect(try Data(contentsOf: link) == Data("real binary".utf8))
    }

    @Test("system-wide install command targets /usr/local/bin, chains via the user link, and quotes paths")
    func systemWideCommand() {
        let bin = URL(fileURLWithPath: "/Users/first last/.local/bin", isDirectory: true)
        let cmd = CLIToolInstaller.systemWideInstallCommand(binDirectory: bin)
        #expect(cmd == "mkdir -p /usr/local/bin && ln -sf '/Users/first last/.local/bin/hypermnesia' '/usr/local/bin/hypermnesia'")
    }

    @Test("uninstall removes our app-bundle link")
    func uninstallRemovesOurLink() throws {
        let (bin, bundled, root) = try sandbox("cli-uninstall")
        defer { try? FileManager.default.removeItem(at: root) }

        try CLIToolInstaller.install(bundledPath: bundled.path, binDirectory: bin)
        try CLIToolInstaller.uninstall(binDirectory: bin)
        let link = CLIToolInstaller.linkURL(binDirectory: bin)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }
}
