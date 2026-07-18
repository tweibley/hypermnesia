import Foundation
import Darwin

/// Shared hook command construction and bounded background-drain diagnostics.
public enum HookDrainDiagnostics {
    public static let maxLogBytes: UInt64 = 512 * 1024

    public static var logDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Hypermnesia", isDirectory: true)
    }

    public static var logURL: URL {
        logDirectory.appendingPathComponent("drain.log")
    }

    /// Capture synchronously, then launch the existing one-shot drainer in the background.
    /// Shell-level redirect covers stale CLIs that lack `--hook-background`; modern builds also
    /// `dup2` into the same log after startup. Hook stdout stays reserved for protocol output.
    public static func captureCommand(binaryPath: String, client: String? = nil) -> String {
        let binary = ConfigFile.shellQuote(binaryPath)
        let clientArgument = client.map { " --client \($0)" } ?? ""
        let logDir = ConfigFile.shellQuote(logDirectory.path)
        let log = ConfigFile.shellQuote(logURL.path)
        return "\(binary) capture\(clientArgument); "
            + "(mkdir -p \(logDir) && nohup \(binary) drain --hook-background >>\(log) 2>&1 &)"
    }

    /// Rotate `drain.log` to `drain.log.1` once it reaches the cap, then open the active log for
    /// append. Rotation is serialized across concurrent hooks and every created path is user-only.
    static func prepareLogFile(
        in directory: URL = logDirectory, maxBytes: UInt64 = maxLogBytes
    ) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let lockURL = directory.appendingPathComponent(".drain-log.lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(lockFD, LOCK_UN) }

        let active = directory.appendingPathComponent("drain.log")
        let rotated = directory.appendingPathComponent("drain.log.1")
        let attributes = try? FileManager.default.attributesOfItem(atPath: active.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if size >= maxBytes {
            try? FileManager.default.removeItem(at: rotated)
            if FileManager.default.fileExists(atPath: active.path) {
                try FileManager.default.moveItem(at: active, to: rotated)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotated.path)
            }
        }

        let fd = open(active.path, O_CREAT | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }

    /// Redirect this process's stdout/stderr to the bounded private drain log.
    public static func redirectStandardStreams() throws {
        let fd = try prepareLogFile()
        defer { close(fd) }
        guard dup2(fd, STDOUT_FILENO) >= 0, dup2(fd, STDERR_FILENO) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
