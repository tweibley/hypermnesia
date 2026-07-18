import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Walks a process's parent chain — how a hook, at event time, records which app hosts the session
/// (the terminal or IDE the agent client runs inside). The app later activates the nearest ancestor
/// that resolves to a GUI application.
public enum ProcessAncestry {
    public struct Ancestor: Sendable, Equatable {
        public let pid: Int32
        /// Full executable path when the kernel will give it up, else the (16-char) command name.
        public let path: String
        public init(pid: Int32, path: String) {
            self.pid = pid
            self.path = path
        }
    }

    /// Ancestors of `pid` up to (excluding) launchd, nearest-first. Defaults to the parent of the
    /// calling process — for a hook that's the shell that spawned it, then the agent client, then
    /// the hosting terminal/IDE.
    public static func chain(from pid: Int32 = getppid(), maxDepth: Int = 15) -> [Ancestor] {
        var result: [Ancestor] = []
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1, let info = kinfo(for: current) else { break }
            result.append(Ancestor(pid: current, path: executablePath(of: current) ?? commandName(info)))
            let parent = info.kp_eproc.e_ppid
            guard parent != current else { break }
            current = parent
        }
        return result
    }

    /// The controlling terminal's device name (e.g. "ttys004"), or nil for GUI-spawned processes.
    /// Hook processes inherit the agent client's controlling terminal, so this identifies the exact
    /// iTerm2 / Terminal tab a CLI session runs in.
    public static func controllingTerminal(of pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String? {
        guard let info = kinfo(for: pid) else { return nil }
        let tdev = info.kp_eproc.e_tdev
        guard tdev != ~dev_t(0) else { return nil }   // NODEV — no controlling terminal
        guard let name = devname(tdev, mode_t(S_IFCHR)) else { return nil }
        return String(cString: name)
    }

    private static func kinfo(for pid: Int32) -> kinfo_proc? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    private static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)   // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private static func commandName(_ info: kinfo_proc) -> String {
        withUnsafePointer(to: info.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.kp_proc.p_comm)) {
                String(cString: $0)
            }
        }
    }
}
