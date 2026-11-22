import Foundation
import AppKit
import Darwin

/// 单个进程的详情。字段做成 (标签, 值) 列表，界面只负责摆出来，
/// 想加什么就加一行，不用改布局代码。
struct ProcessDetail: Codable {
    struct Field: Codable {
        let label: String
        let value: String
    }

    let pid: Int32
    var fields: [Field]
    var executablePath: String?
    /// 请求序号：root 代理用它回填，主进程据此判断这份数据是不是自己那次的答案
    var seq: Double = 0
}

enum ProcessInspector {
    /// 进程状态码（sys/proc.h 的 S*）
    private static let statusNames: [Int32: String] = [
        1: "空闲", 2: "运行中", 3: "睡眠", 4: "已停止", 5: "僵尸",
    ]

    static func inspect(pid: pid_t) -> ProcessDetail {
        var fields: [ProcessDetail.Field] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append(.init(label: label, value: value))
        }

        let path = executablePath(pid)
        var name = URL(fileURLWithPath: path ?? "").lastPathComponent

        // PROC_PIDTBSDINFO：父进程、属主、状态、启动时间、打开的文件数
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bsdOK = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize

        if bsdOK {
            let comm = withUnsafeBytes(of: bsd.pbi_comm) {
                String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) ?? ""
            }
            if !comm.isEmpty { name = comm }
        }
        add("名称", name)

        let startDate: Date? = bsdOK && bsd.pbi_start_tvsec > 0
            ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000)
            : nil
        if let startDate {
            let uptime = Date().timeIntervalSince(startDate)
            add("启动时间", "\(Self.timestampFormatter.string(from: startDate))（已运行 \(duration(uptime))）")
        } else if pid == 1 {
            add("启动时间", "系统启动时（需要 root 权限才能读精确值）")
        }

        if bsdOK {
            let parentPID = pid_t(bitPattern: bsd.pbi_ppid)
            var parentName = ""
            if parentPID > 0 {
                var parentBSD = proc_bsdinfo()
                if proc_pidinfo(parentPID, PROC_PIDTBSDINFO, 0, &parentBSD, bsdSize) == bsdSize {
                    parentName = withUnsafeBytes(of: parentBSD.pbi_comm) {
                        String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) ?? ""
                    }
                }
                if let path = executablePath(parentPID), parentName.isEmpty {
                    parentName = URL(fileURLWithPath: path).lastPathComponent
                }
            }
            add("父进程", parentName.isEmpty ? "\(parentPID)" : "\(parentName)（\(parentPID)）")
            add("用户", userName(uid: bsd.pbi_uid) + "（uid \(bsd.pbi_uid)）")
            add("状态", statusNames[Int32(bitPattern: bsd.pbi_status)] ?? "未知（\(bsd.pbi_status)）")
            add("打开的文件", "\(bsd.pbi_nfiles)")
        } else {
            add("父进程 / 用户 / 状态", "无权读取（root 拥有的进程，点「显示系统进程…」后可用 root 读）")
        }

        if let path { add("可执行文件", path) }
        add("工作目录", workingDirectory(pid))
        add("启动参数", arguments(pid))

        // PROC_PIDTASKINFO：线程数、常驻内存、累计 CPU
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
            add("线程数", "\(task.pti_threadnum)")
            add("常驻内存", "\(SystemFormat.bytes(task.pti_resident_size))")
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let ticks = task.pti_total_user &+ task.pti_total_system
            let seconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
            add("累计 CPU", String(format: "%.1f 秒", seconds))
        }

        var usage = rusage_info_v4()
        let usageOK = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, 4, rebound)
            }
        } == 0
        if usageOK {
            add("物理内存占用", "\(SystemFormat.bytes(usage.ri_phys_footprint))（footprint，活动监视器口径）")
        }

        add("监听端口", listeningPorts(pid))
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            add("Bundle ID", bundle)
        }

        return ProcessDetail(pid: pid, fields: fields, executablePath: path)
    }

    // MARK: - 各字段

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) {
            String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8)
        }
        return path?.isEmpty == true ? nil : path
    }

    /// KERN_PROCARGS2：argc + 可执行路径 + NUL 分隔的参数
    private static func arguments(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }      // 跳过 exec path
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var start = index
        while index < size, arguments.count < Int(argc) {
            if buffer[index] == 0 {
                if let text = String(bytes: buffer[start..<index], encoding: .utf8), !text.isEmpty {
                    arguments.append(text)
                }
                start = index + 1
            }
            index += 1
        }
        return arguments.isEmpty ? nil : arguments.joined(separator: " ")
    }

    private static func listeningPorts(_ pid: pid_t) -> String? {
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                                Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        var ports = Set<UInt16>()
        for index in 0..<count {
            let fd = fds[index]
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
            if port > 0 { ports.insert(port) }
        }
        guard !ports.isEmpty else { return nil }
        return ports.sorted().map { "\($0)" }.joined(separator: ", ")
    }

    private static func userName(uid: uid_t) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return "\(uid)" }
        return String(cString: name)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分 \(total % 60) 秒" }
        if total < 86_400 { return "\(total / 3600) 小时 \((total % 3600) / 60) 分" }
        return "\(total / 86_400) 天 \((total % 86_400) / 3600) 小时"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
