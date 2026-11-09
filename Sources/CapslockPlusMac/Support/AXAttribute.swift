import Foundation
import AppKit
import ApplicationServices
import Carbon

/// AX 属性读取：整个模块唯一直接调用 AXUIElementCopyAttributeValue 的地方。
///
/// App 的读取路径和 DebugCLI 的探针都走这里，避免"探针另写一套读取器 → 结论和出货行为不一致"。
extension AX {
    static func childrenAttribute(_ element: AXUIElement) -> [AXUIElement]? {
        elementArrayAttribute(element, kAXChildrenAttribute as CFString)
    }

    static func elementArrayAttribute(_ element: AXUIElement, _ name: CFString) -> [AXUIElement]? {
        guard let raw = copyAttribute(element, name).value, CFGetTypeID(raw) == CFArrayGetTypeID() else {
            return nil
        }
        return (raw as? [AXUIElement]) ?? []
    }

    static func pointAttribute(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
        guard let raw = copyAttribute(element, name).value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func sizeAttribute(_ element: AXUIElement, _ name: CFString) -> CGSize? {
        guard let raw = copyAttribute(element, name).value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: - 原始读取原语
    //
    // 整个模块只有这里直接调 AXUIElementCopyAttributeValue；
    // 探针（DebugCLI）也走这里，避免"探针自己写一套读取器"导致结论和 App 行为不一致。

    static func copyAttribute(_ element: AXUIElement, _ name: CFString) -> (status: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        return (status, value)
    }

    static func copyParameterized(_ element: AXUIElement,
                                  _ name: CFString,
                                  _ parameter: CFTypeRef) -> (status: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, name, parameter, &value)
        return (status, value)
    }

    /// 元素支持的属性名列表（探针用）
    static func attributeNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        guard let raw = copyAttribute(element, name).value, CFGetTypeID(raw) == CFStringGetTypeID() else {
            return nil
        }
        return (raw as! String)
    }

    static func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let raw = copyAttribute(element, name).value, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return (raw as! AXUIElement) as AXUIElement
    }
}
