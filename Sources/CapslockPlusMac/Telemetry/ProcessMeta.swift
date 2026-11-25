import Foundation
import Darwin

/// argv 缓存：键是 pid。同一个 argv 出现在不同进程里互不影响。
struct ArgvCache {
    private struct Entry {
        let argv: [String]
        let fetchedAt: Date
    }

    private var entries: [pid_t: Entry] = [:]

    mutating func argv(for pid: pid_t, now: Date,
                       maxAge: TimeInterval = 600,
                       fetch: () -> [String]) -> [String] {
        if let hit = entries[pid], now.timeIntervalSince(hit.fetchedAt) < maxAge {
            return hit.argv
        }
        let fresh = fetch()
        entries[pid] = Entry(argv: fresh, fetchedAt: now)
        return fresh
    }
}

/// 补齐 ProcessSampler 没有的字段。libproc 对 root 进程的 argv/exe 会 EPERM，
/// 这里一律降级成空值，不抛错也不退出。
final class ProcessMeta {
    struct Info {
        let pid: pid_t
        let ppid: pid_t
        let uid: uid_t
        let user: String?
        let startedAt: Date?
        let exe: String?
        let argv: [String]
        let threads: Int
        let openFiles: Int
        let residentBytes: UInt64
    }

    private struct Identity {
        let ppid: pid_t
        let uid: uid_t
        let user: String?
        let startedAt: Date?
        let exe: String?
    }

    /// 启动时间 / exe / ppid / user 基本不变，按 pid 缓存，只在首次见到时读。
    private var identities: [pid_t: Identity] = [:]
    private var argvCache = ArgvCache()

    func info(for pid: pid_t, now: Date = Date()) -> Info {
        let identity: Identity
        if let cached = identities[pid] {
            identity = cached
        } else {
            identity = Self.loadIdentity(pid)
            identities[pid] = identity
        }

        let argv = argvCache.argv(for: pid, now: now) {
            Self.readArguments(pid)
        }
        let task = Self.loadTask(pid)
        return Info(pid: pid,
                    ppid: identity.ppid,
                    uid: identity.uid,
                    user: identity.user,
                    startedAt: identity.startedAt,
                    exe: identity.exe,
                    argv: argv,
                    threads: task.threads,
                    openFiles: Self.countOpenFiles(pid),
                    residentBytes: task.residentBytes)
    }

    /// 进程消失后清掉缓存的身份。不清的话 pid 被复用时会一直拿旧进程的 started_at，
    /// 服务端按 (pid, started_at) 认实例，新进程的样本会被算到已退出的那个实例头上。
    func forget(pid: pid_t) {
        identities.removeValue(forKey: pid)
    }

    private static func loadIdentity(_ pid: pid_t) -> Identity {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else {
            return Identity(ppid: 0, uid: 0, user: nil, startedAt: nil, exe: executablePath(pid))
        }

        let ppid = pid_t(bitPattern: bsd.pbi_ppid)
        let uid = bsd.pbi_uid
        let startedAt = bsd.pbi_start_tvsec > 0
            ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)
                   + Double(bsd.pbi_start_tvusec) / 1_000_000)
            : nil
        return Identity(ppid: ppid,
                        uid: uid,
                        user: userName(uid: uid),
                        startedAt: startedAt,
                        exe: executablePath(pid))
    }

    private static func userName(uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func loadTask(_ pid: pid_t) -> (threads: Int, residentBytes: UInt64) {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else {
            return (0, 0)
        }
        return (max(Int(task.pti_threadnum), 0), task.pti_resident_size)
    }

    /// PROC_PIDLISTFDS 返回的是"填了多少字节"，不是总 fd 数；缓冲区满了就翻倍重试。
    private static func countOpenFiles(_ pid: pid_t) -> Int {
        var capacity = 256
        while capacity <= 8192 {
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                                     Int32(capacity * MemoryLayout<proc_fdinfo>.size))
            guard bytes > 0 else { return 0 }
            let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
            if count < capacity { return count }
            capacity *= 2
        }
        return 8192
    }

    /// KERN_PROCARGS2 布局：int32 argc + exec path + NUL 填充 + argc 个 NUL 分隔字符串。
    static func readArguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let length = min(size, buffer.count)
        guard length >= 4 else { return [] }

        let rawArgc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let argc = max(0, min(Int(rawArgc), 4096))
        guard argc > 0 else { return [] }

        var index = 4
        while index < length, buffer[index] != 0 { index += 1 }
        while index < length, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var start = index
        while index < length, arguments.count < argc {
            if buffer[index] == 0 {
                // 空字符串也是合法 argv，跳过会导致后面的参数错位。
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        if arguments.count < argc, start < length {
            arguments.append(String(decoding: buffer[start..<length], as: UTF8.self))
        }
        return arguments
    }
}
