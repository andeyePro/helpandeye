import Foundation

/// The conversation with the box over Bluetooth, one command at a time, as MeshCore's companion
/// protocol requires. Calls for help go to the front of the queue, so they never wait behind setup
/// or message syncing. Replies carry no command number, so after a timeout a late reply could be
/// taken for the next command's: the queue then stops writing until the link is set up afresh, and
/// everything still waiting gets no answer rather than a wrong one.
@MainActor
public final class CommandQueue {
    public typealias Expect = (MeshCore.Response) -> Bool

    /// What became of a command. Only `notWritten` means it certainly never reached the box.
    public enum Outcome: Equatable, Sendable {
        case reply(MeshCore.Response)
        case timedOut
        case notWritten
    }

    private struct Job {
        let id = UUID()
        let data: Data
        let expect: Expect
        let done: CheckedContinuation<Outcome, Never>
    }

    private var waiting: [Job] = []
    private var pending: Job?
    /// Whether commands may be written. False until the link is up, and after a timeout.
    public private(set) var isUp = false
    private let write: (Data) -> Void
    private let timeout: TimeInterval
    /// Called after a timeout, so the owner can drop the link and connect again.
    public var onTimeout: (() -> Void)?

    public init(timeout: TimeInterval = 5, write: @escaping (Data) -> Void) {
        self.timeout = timeout
        self.write = write
    }

    /// Sends one command and waits for the reply `expect` accepts. Nil if the link is down, the
    /// command cannot be encoded, or no reply comes in time.
    public func run(_ command: MeshCore.Command, urgent: Bool = false, expect: @escaping Expect) async -> MeshCore.Response? {
        if case let .reply(r) = await send(command, urgent: urgent, expect: expect) { return r }
        return nil
    }

    public func send(_ command: MeshCore.Command, urgent: Bool = false, expect: @escaping Expect) async -> Outcome {
        guard isUp, let data = try? command.encoded() else { return .notWritten }
        return await withCheckedContinuation { c in
            let job = Job(data: data, expect: expect, done: c)
            if urgent { waiting.insert(job, at: 0) } else { waiting.append(job) }
            pump()
        }
    }

    /// A frame from the box. True if it was the reply to the command in flight.
    @discardableResult
    public func receive(_ response: MeshCore.Response) -> Bool {
        guard let p = pending, p.expect(response) else { return false }
        pending = nil
        p.done.resume(returning: .reply(response))
        pump()
        return true
    }

    public func linkUp() {
        isUp = true
        pump()
    }

    /// The link dropped or is being replaced: nothing in flight or waiting will be answered.
    public func linkDown() { drop(inFlight: .timedOut) }

    /// The command in flight was written, so it may have gone on air; the rest never were.
    private func drop(inFlight: Outcome) {
        isUp = false
        let flying = pending, rest = waiting
        pending = nil
        waiting = []
        flying?.done.resume(returning: inFlight)
        for j in rest { j.done.resume(returning: .notWritten) }
    }

    public var isIdle: Bool { pending == nil && waiting.isEmpty }

    private func pump() {
        guard isUp, pending == nil, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        pending = job
        write(job.data)
        let id = job.id, wait = timeout
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            self?.timedOut(id)
        }
    }

    private func timedOut(_ id: UUID) {
        guard pending?.id == id else { return }
        drop(inFlight: .timedOut)
        onTimeout?()
    }
}
