import Darwin
import Foundation

enum RawLoopbackHTTPClient {
    static func fetch(request: Data, host: String, port: UInt16) throws -> Data {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(socketFD) }

        var noSigPipe: Int32 = 1
        setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.stride)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let conversionResult = host.withCString { cString in
            inet_pton(AF_INET, cString, &address.sin_addr)
        }
        guard conversionResult == 1 else {
            throw POSIXError(.EINVAL)
        }

        try withSockAddrPointer(to: &address) { pointer, length in
            guard connect(socketFD, pointer, length) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        var sent = 0
        while sent < request.count {
            let result = request.withUnsafeBytes { rawBuffer in
                send(socketFD, rawBuffer.baseAddress!.advanced(by: sent), request.count - sent, 0)
            }
            guard result >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            sent += result
        }

        guard shutdown(socketFD, SHUT_WR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = recv(socketFD, &buffer, buffer.count, 0)
            guard received >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if received == 0 {
                break
            }
            response.append(buffer, count: received)
        }

        return response
    }
}
