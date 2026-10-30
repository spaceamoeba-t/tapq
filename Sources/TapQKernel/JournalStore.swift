import Foundation
import TapQContracts

public enum JournalStoreError: Error, Equatable, CustomStringConvertible {
    case olderTranscript
    case unreadable(path: String, detail: String)
    case unwritable(path: String, detail: String)
    case corrupt(line: Int, detail: String)

    public var description: String {
        switch self {
        case .olderTranscript:
            return "this workspace has a transcript from an older TapQ; clear it"
        case .unreadable(let path, let detail):
            return "cannot read \(path): \(detail)"
        case .unwritable(let path, let detail):
            return "cannot write \(path): \(detail)"
        case .corrupt(let line, let detail):
            return "journal line \(line) is corrupt: \(detail)"
        }
    }
}

/// `journal.jsonl` in the workspace's kernel directory: one record per line, written and
/// fsynced, newline included, before `append` returns.
///
/// Torn tail (§4.8): a final fragment without its newline is an append that never returned,
/// so the action it describes never happened. It is dropped and the file truncated to the
/// last newline. Every other undecodable line is corruption and throws.
@MainActor
public final class JournalStore: JournalPersisting {
    public static let fileName = "journal.jsonl"
    /// Schema v1's file. A workspace that still has one is refused, never migrated.
    public static let olderFileName = "transcript.jsonl"

    public let url: URL
    private let olderURL: URL
    private let diagnostics: TapQDiagnosticEmitter

    public init(directory: URL, diagnostics: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        url = directory.appendingPathComponent(Self.fileName)
        olderURL = directory.appendingPathComponent(Self.olderFileName)
        self.diagnostics = TapQDiagnosticEmitter(category: "kernel", sink: diagnostics)
    }

    /// Present → the next run resumes; absent → it starts fresh (§8). The kernel directory
    /// also holds diagnostics and recordings, so its existence says nothing (01-7).
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func load() throws -> [JournalRecord] {
        if FileManager.default.fileExists(atPath: olderURL.path) {
            throw JournalStoreError.olderTranscript
        }
        guard exists else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw JournalStoreError.unreadable(path: url.path, detail: "\(error)")
        }
        let complete = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        if complete < data.count { try dropTornTail(keeping: complete, of: data.count) }

        let decoder = KernelJSON.decoder()
        return try data[..<complete].split(separator: 0x0A, omittingEmptySubsequences: false)
            .dropLast()
            .enumerated()
            .map { index, line in
                do {
                    return try decoder.decode(JournalRecord.self, from: Data(line))
                } catch {
                    throw JournalStoreError.corrupt(line: index + 1, detail: "\(error)")
                }
            }
    }

    public func append(_ record: JournalRecord) throws {
        var line: Data
        do {
            line = try KernelJSON.encoder().encode(record)
        } catch {
            throw JournalStoreError.unwritable(path: url.path, detail: "\(error)")
        }
        line.append(0x0A)
        if !exists,
           !FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600]) {
            throw JournalStoreError.unwritable(path: url.path, detail: "cannot create the file")
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch {
            throw JournalStoreError.unwritable(path: url.path, detail: "\(error)")
        }
    }

    private func dropTornTail(keeping length: Int, of total: Int) throws {
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(length))
            try handle.synchronize()
        } catch {
            throw JournalStoreError.unwritable(path: url.path, detail: "\(error)")
        }
        diagnostics.record("journal.torn_tail_dropped", level: .warning,
                           fields: ["bytes": "\(total - length)"])
    }
}
