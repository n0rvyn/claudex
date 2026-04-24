import Darwin
import Foundation

func reserveLoopbackPort() throws -> UInt16 {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(socketFD) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    try withSockAddrPointer(to: &address) { pointer, length in
        guard bind(socketFD, pointer, length) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    var boundAddress = sockaddr_in()
    boundAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
    var boundLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
    try withSockAddrMutablePointer(to: &boundAddress) { pointer, _ in
        guard getsockname(socketFD, pointer, &boundLength) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    return UInt16(bigEndian: boundAddress.sin_port)
}

func withSockAddrPointer<Result>(
    to address: inout sockaddr_in,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
) rethrows -> Result {
    try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
            try body(sockAddr, socklen_t(MemoryLayout<sockaddr_in>.stride))
        }
    }
}

func withSockAddrMutablePointer<Result>(
    to address: inout sockaddr_in,
    _ body: (UnsafeMutablePointer<sockaddr>, socklen_t) throws -> Result
) rethrows -> Result {
    try withUnsafeMutablePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
            try body(sockAddr, socklen_t(MemoryLayout<sockaddr_in>.stride))
        }
    }
}
