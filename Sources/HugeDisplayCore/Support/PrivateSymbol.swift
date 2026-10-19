import Darwin
import Foundation

/// Lazily resolves a C symbol from a (private) framework via dlopen/dlsym.
/// Private APIs are never linked directly so a missing symbol degrades a feature instead of crashing launch.
public enum PrivateSymbol {
    private static var handles: [String: UnsafeMutableRawPointer] = [:]
    private static let lock = NSLock()

    public static func load<T>(_ name: String, from frameworkPath: String, as _: T.Type) -> T? {
        lock.lock()
        defer { lock.unlock() }
        let handle: UnsafeMutableRawPointer
        if let cached = handles[frameworkPath] {
            handle = cached
        } else {
            guard let opened = dlopen(frameworkPath, RTLD_LAZY) else { return nil }
            handles[frameworkPath] = opened
            handle = opened
        }
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    public static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    public static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    public static let coreDisplay = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
    public static let ioKit = "/System/Library/Frameworks/IOKit.framework/IOKit"
}
