import Foundation

public enum ChannelSignal: Sendable, Equatable {
    case stdout(String), stderr(String)
    /// Delivered only after BOTH readers reached EOF (02-10).
    case exited(Int32)
}

/// A child's three pipes as lines. Both delegates talk to one, so their tests feed lines and
/// never spawn a process.
public protocol LineChannel: AnyObject, Sendable {
    var signals: AsyncStream<ChannelSignal> { get }
    /// EPIPE → throws; SIGPIPE is ignored process-wide.
    func write(line: String) throws
    func closeInput()
    /// D13 escalation, on the process group: close stdin, wait up to `grace`; SIGTERM, wait
    /// up to `killAfter`; SIGKILL.
    func terminate(grace: Duration, killAfter: Duration) async
}
