import XCTest
import Foundation
import Dispatch
@testable import TapQPOSIXBridgeClient
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class UnixSocketClientTests: XCTestCase {
    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ byte: UInt8) {
            lock.lock()
            storage.append(byte)
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testRejectsOverlongSocketPath() {
        let path = "/tmp/" + String(repeating: "x", count: 200)
        XCTAssertThrowsError(
            try UnixSocketClient.request(Data("request".utf8), socketPath: path)
        ) { error in
            XCTAssertEqual(error as? UnixSocketClient.ClientError, .pathTooLong)
        }
    }

    func testWritesOneLineAndReadsOneLine() throws {
        let path = "/tmp/tapq-client-\(UUID().uuidString.prefix(12)).sock"
        let listenFD = socket(AF_UNIX, streamSocketType, 0)
        XCTAssertGreaterThanOrEqual(listenFD, 0)
        defer {
            close(listenFD)
            unlink(path)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strncpy($0, source, capacity - 1)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) { rawAddress in
            rawAddress.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemBind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listenFD, 1), 0)

        let served = expectation(description: "test server replied")
        let captured = LockedData()
        DispatchQueue.global().async {
            let connection = accept(listenFD, nil, nil)
            guard connection >= 0 else {
                served.fulfill()
                return
            }
            defer { close(connection) }
            var byte: UInt8 = 0
            while read(connection, &byte, 1) == 1, byte != 0x0A {
                captured.append(byte)
            }
            var response = Data("response".utf8)
            response.append(0x0A)
            response.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    _ = write(connection, baseAddress, bytes.count)
                }
            }
            served.fulfill()
        }

        let response = try UnixSocketClient.request(
            Data("request".utf8), socketPath: path, timeout: 2)
        wait(for: [served], timeout: 2)

        let request = captured.value
        XCTAssertEqual(String(decoding: request, as: UTF8.self), "request")
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "response")
    }

    private var streamSocketType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    private func systemBind(_ socket: Int32, _ address: UnsafePointer<sockaddr>,
                            _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.bind(socket, address, length)
        #else
        return Glibc.bind(socket, address, length)
        #endif
    }
}
