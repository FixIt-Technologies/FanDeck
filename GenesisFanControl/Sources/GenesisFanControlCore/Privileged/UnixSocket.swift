//
//  UnixSocket.swift
//  GenesisFanControlCore
//
//  Bare-bones Unix domain socket primitives. Used by HelperClient to
//  talk to the privileged daemon and by the daemon itself to listen.
//

import Foundation
import Darwin

public enum UnixSocketError: Error, CustomStringConvertible {
    case socketCreate(errno: Int32)
    case bind(errno: Int32)
    case listen(errno: Int32)
    case connect(errno: Int32)
    case read(errno: Int32)
    case write(errno: Int32)
    case pathTooLong
    case shortRead
    case decode(String)

    public var description: String {
        switch self {
        case .socketCreate(let e): return "socket(): \(String(cString: strerror(e)))"
        case .bind(let e):         return "bind(): \(String(cString: strerror(e)))"
        case .listen(let e):       return "listen(): \(String(cString: strerror(e)))"
        case .connect(let e):      return "connect(): \(String(cString: strerror(e)))"
        case .read(let e):         return "read(): \(String(cString: strerror(e)))"
        case .write(let e):        return "write(): \(String(cString: strerror(e)))"
        case .pathTooLong:         return "socket path too long for sockaddr_un"
        case .shortRead:           return "peer closed before a full line arrived"
        case .decode(let s):       return "decode: \(s)"
        }
    }
}

public enum UnixSocket {
    /// Connect to a Unix domain socket and return the file descriptor.
    public static func connect(toPath path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.socketCreate(errno: errno) }
        var addr = try makeAddr(path: path)
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc < 0 {
            let e = errno
            close(fd)
            throw UnixSocketError.connect(errno: e)
        }
        return fd
    }

    /// Bind + listen — caller invokes accept() in a loop.
    public static func listen(atPath path: String, backlog: Int32 = 8) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.socketCreate(errno: errno) }
        var addr = try makeAddr(path: path)
        let bindRC = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindRC < 0 {
            let e = errno
            close(fd)
            throw UnixSocketError.bind(errno: e)
        }
        // World-writable so any GUI session on this Mac can use it.
        chmod(path, 0o666)
        if Darwin.listen(fd, backlog) < 0 {
            let e = errno
            close(fd)
            throw UnixSocketError.listen(errno: e)
        }
        return fd
    }

    /// Write the bytes followed by '\n'. JSON has no inner newlines so a
    /// linefeed cleanly delimits messages.
    public static func writeLine(_ fd: Int32, payload: Data) throws {
        var buf = payload
        buf.append(0x0A)
        try buf.withUnsafeBytes { raw in
            var ptr = raw.baseAddress!
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.write(errno: errno)
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
    }

    /// Read up to and including '\n' (excluded from the returned Data).
    public static func readLine(_ fd: Int32, maxBytes: Int = 65_536) throws -> Data {
        var out = Data()
        var byte: UInt8 = 0
        while out.count < maxBytes {
            let n = Darwin.read(fd, &byte, 1)
            if n == 0 { throw UnixSocketError.shortRead }
            if n < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.read(errno: errno)
            }
            if byte == 0x0A { return out }
            out.append(byte)
        }
        return out
    }

    // MARK: -

    private static func makeAddr(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        // sockaddr_un.sun_path is a fixed-size C array of CChar.
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw UnixSocketError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for (i, b) in pathBytes.enumerated() { dst[i] = b }
            dst[pathBytes.count] = 0
        }
        return addr
    }
}
