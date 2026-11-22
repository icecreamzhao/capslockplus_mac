import Foundation
import IOKit

/// 读 AppleSMC：温度、风扇转速。只读不写 —— 写风扇曲线要有 root 特权 helper，本项目不做。
///
/// 这里是私有 ABI，踩过的两个坑都写进代码里了：
///   1. `SMCKeyData_t` 是内核按原生布局写的结构，Swift 结构体的字段顺序**不能**直接照抄
///      （编译器会重排以获得更好对齐，stride 变成 76 而不是 80，调用直接 kIOReturnBadArgument）。
///      所以全部按字节偏移手写，长度固定 80。
///   2. key 和 type 在内存里是"字符反序"的（"#KEY" 存成 59 45 4B 23，"ui32" 存成 "23iu"），
///      而 dataSize 是小端；值里整数类型（ui8/ui16/ui32）按大端解释，浮点（flt）是小端。
///      这些结论是对着真实机器逐字段打出来的，不是猜的。
enum SMC {
    private static let kernelIndex: UInt32 = 2   // KERNEL_INDEX_SMC
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadKeyInfo: UInt8 = 9

    // SMCKeyData_t 的字段偏移（总长 80）
    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let data8 = 42
        static let data32 = 44
        static let bytes = 48
        static let total = 80
    }

    // MARK: - 字节工具

    private static func putKey(_ buffer: inout [UInt8], _ name: String) {
        let chars = Array(name.utf8.prefix(4))
        for (index, char) in chars.enumerated() { buffer[Offset.key + 3 - index] = char }
    }

    private static func keyString(_ buffer: [UInt8]) -> String {
        String(bytes: [buffer[3], buffer[2], buffer[1], buffer[0]], encoding: .ascii) ?? "????"
    }

    private static func putUInt32LE(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8(value >> 24)
    }

    private static func putUInt32BE(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8(value >> 24)
        buffer[offset + 1] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 3] = UInt8(value & 0xFF)
    }

    private static func uint32LE(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buffer[offset]) | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16) | (UInt32(buffer[offset + 3]) << 24)
    }

    private static func uint32BE(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(buffer[offset]) << 24) | (UInt32(buffer[offset + 1]) << 16)
            | (UInt32(buffer[offset + 2]) << 8) | UInt32(buffer[offset + 3])
    }

    /// dataType 在内存里是反序的，读出来要倒一下才是 "ui32" / "flt " 这种
    private static func typeString(_ buffer: [UInt8]) -> String {
        String(bytes: [buffer[Offset.dataType + 3], buffer[Offset.dataType + 2],
                       buffer[Offset.dataType + 1], buffer[Offset.dataType]], encoding: .ascii) ?? "????"
    }

    // MARK: - 与 AppleSMC 通讯

    /// 每次读都重开连接：句柄在睡眠/唤醒后会失效，缓存下来只会读到旧值。
    private static func call(_ input: [UInt8]) -> (kern: kern_return_t, output: [UInt8]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS else {
            return (KERN_FAILURE, [])
        }
        defer { IOObjectRelease(iterator) }
        let device = IOIteratorNext(iterator)
        guard device != 0 else { return (KERN_FAILURE, []) }
        defer { IOObjectRelease(device) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(device, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return (KERN_FAILURE, [])
        }
        defer { IOServiceClose(connection) }

        var output = [UInt8](repeating: 0, count: Offset.total)
        var outputSize = Offset.total
        let kern = input.withUnsafeBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                IOConnectCallStructMethod(connection, kernelIndex,
                                          inputPointer.baseAddress, Offset.total,
                                          outputPointer.baseAddress, &outputSize)
            }
        }
        return (kern, output)
    }

    /// 读一个 key 的原始字节
    static func readRaw(_ name: String) -> (bytes: [UInt8], type: String)? {
        var info = [UInt8](repeating: 0, count: Offset.total)
        putKey(&info, name)
        info[Offset.data8] = cmdReadKeyInfo
        let (kern, output) = call(info)
        guard kern == KERN_SUCCESS, output.indices.contains(Offset.result),
              output[Offset.result] == 0 else { return nil }

        let size = Int(uint32LE(output, Offset.dataSize))       // dataSize 是小端
        guard size > 0, size <= 32 else { return nil }
        let type = typeString(output)

        var read = [UInt8](repeating: 0, count: Offset.total)
        putKey(&read, name)
        // 结构体字段是原生小端（dataSize 也一样），只有"值"里的整数是大端
        putUInt32LE(&read, Offset.dataSize, UInt32(size))
        read[Offset.data8] = cmdReadBytes
        let (kern2, output2) = call(read)
        guard kern2 == KERN_SUCCESS, output2[Offset.result] == 0 else { return nil }

        let start = Offset.bytes
        return (Array(output2[start..<(start + size)]), type)
    }

    /// 整数类型大端、浮点小端 —— 这是实测结果，不是教科书假设
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(uint32BE(bytes, 0))
        default:
            return nil
        }
    }

    static func value(_ name: String) -> Double? {
        guard let (bytes, type) = readRaw(name) else { return nil }
        return decode(bytes, type: type)
    }

    // MARK: - 对外

    /// 不同芯片 / 机型的温度 key 不一样，按候选列表挨个试，取落在合理区间的最大值
    private static let temperatureKeys = [
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0b", "Tp0D",
        "Te05", "Te0L", "TB0T", "Tb0T", "Tc0P", "TC0P", "Tg0f", "Tg0j",
    ]

    static func cpuTemperature() -> Double? {
        let found = temperatureKeys.compactMap { key -> Double? in
            guard let celsius = value(key), celsius > 5, celsius < 110 else { return nil }
            return celsius
        }
        return found.max()
    }

    static func fanCount() -> Int {
        guard let count = value("FNum"), count >= 0 else { return 0 }
        return min(Int(count), 4)
    }

    /// 多风扇时取最大值（散热压力看最热的那个）
    static func fanRPM() -> Int? {
        let count = fanCount()
        guard count > 0 else { return nil }
        let rpms = (0..<count).compactMap { index -> Double? in
            guard let rpm = value("F\(index)Ac"), rpm >= 0, rpm < 12000 else { return nil }
            return rpm
        }
        return rpms.isEmpty ? nil : Int(rpms.max()!.rounded())
    }

    /// 诊断：换机型时用它确认真实 key 名与字节布局
    static func report() -> String {
        var lines: [String] = []
        if let keys = value("#KEY") { lines.append("#KEY=\(Int(keys))") }
        lines.append("FNum=\(fanCount())")
        for index in 0..<fanCount() {
            if let (bytes, type) = readRaw("F\(index)Ac"), let rpm = decode(bytes, type: type) {
                lines.append("F\(index)Ac=\(Int(rpm))rpm type=\(type)")
            }
        }
        for key in temperatureKeys {
            if let (bytes, type) = readRaw(key), let celsius = decode(bytes, type: type) {
                lines.append("\(key)=\(String(format: "%.2f", celsius))°C type=\(type)")
            }
        }
        return lines.isEmpty ? "(no SMC data)" : lines.joined(separator: "\n")
    }
}
