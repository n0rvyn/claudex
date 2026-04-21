import CZstd
import Foundation

public enum ZstdCodecError: Error, LocalizedError {
    case compressionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .compressionFailed(let message):
            "zstd compression failed: \(message)"
        }
    }
}

public enum ZstdCodec {
    public static func compress(_ data: Data, level: Int32 = 3) throws -> Data {
        let destinationCapacity = ZSTD_compressBound(data.count)
        var destination = Data(count: destinationCapacity)

        let written: Int = try destination.withUnsafeMutableBytes { destinationBytes in
            try data.withUnsafeBytes { sourceBytes in
                let sourceBase = sourceBytes.bindMemory(to: UInt8.self).baseAddress
                let destinationBase = destinationBytes.bindMemory(to: UInt8.self).baseAddress

                let result = ZSTD_compress(
                    destinationBase,
                    destinationCapacity,
                    sourceBase,
                    data.count,
                    level
                )

                if ZSTD_isError(result) != 0 {
                    let message = String(cString: ZSTD_getErrorName(result))
                    throw ZstdCodecError.compressionFailed(message)
                }

                return Int(result)
            }
        }

        destination.count = written
        return destination
    }
}
