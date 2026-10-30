import Foundation
import XCTest
@testable import TapQKernel

/// One directory per workspace, and the hash that names it.
@MainActor
final class KernelPathsTests: XCTestCase {

    // MARK: - SHA-256

    /// The two vectors from FIPS 180-4. The hash is written out by hand here (no CryptoKit
    /// on Linux, no swift-crypto in this package), so it is checked against the standard
    /// rather than against itself.
    func testKnownVectors() async throws {
        XCTAssertEqual(SHA256.hexDigest(of: ""),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hexDigest(of: "abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// A message longer than one 64-byte block, so the padding path with a second block is
    /// exercised too.
    func testAMultiBlockMessage() async throws {
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(SHA256.hexDigest(of: message),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    // MARK: - The directory

    func testDirectoryIsNamedByTheFirstTwelveHexOfTheWorkspaceHash() async throws {
        let workspace = URL(fileURLWithPath: "/Users/someone/code/tapq")
        let expected = String(SHA256.hexDigest(of: "/Users/someone/code/tapq").prefix(12))

        let directory = KernelPaths.directory(
            supportDirectory: URL(fileURLWithPath: "/Users/someone/Library/Application Support/TapQ"),
            workspace: workspace)

        XCTAssertEqual(directory.lastPathComponent, expected)
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "kernel")
        XCTAssertEqual(expected.count, 12)
    }

    func testTwoWorkspacesNeverShareADirectory() async throws {
        let support = URL(fileURLWithPath: "/support")
        let one = KernelPaths.directory(supportDirectory: support,
                                        workspace: URL(fileURLWithPath: "/code/one"))
        let two = KernelPaths.directory(supportDirectory: support,
                                        workspace: URL(fileURLWithPath: "/code/two"))
        XCTAssertNotEqual(one, two)
    }

    /// The same workspace written two ways is one workspace.
    func testThePathIsStandardisedFirst() async throws {
        XCTAssertEqual(KernelPaths.workspaceKey(for: URL(fileURLWithPath: "/code/one")),
                       KernelPaths.workspaceKey(for: URL(fileURLWithPath: "/code/two/../one")))
        XCTAssertEqual(KernelPaths.workspaceKey(for: URL(fileURLWithPath: "/code/one")),
                       KernelPaths.workspaceKey(for: URL(fileURLWithPath: "/code/./one/")))
    }
}
