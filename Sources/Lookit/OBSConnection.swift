// The socket. §7's reconnect behavior wrapped around a single connect attempt,
// which is why `connectOnce` knows nothing about retrying.
//
// @MainActor rather than an actor of its own: every consumer of this — the HUD,
// the menu, the tick loop — is already main-actor, and the work here is entirely
// IO-bound. An extra isolation domain would buy hops and Sendable friction, not
// concurrency.

import AppKit
import CryptoKit
import Foundation
import LookitCore

@MainActor
public final class OBSConnection {
    public private(set) var state: Connection = .disconnected(.notStarted) {
        didSet { if state != oldValue { onState(state) } }
    }

    private let onState: (Connection) -> Void
    private let onEvent: (ObsEvent) -> Void
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?

    /// Callers suspended on an op 7, keyed by the requestId they are waiting for.
    private var pending: [String: CheckedContinuation<Result<Data, ObsError>, Never>] = [:]
    private var nextRequestId = 0

    /// `onEvent` is §3's `obs.events` Stream. A closure rather than an
    /// AsyncStream because the other two Streams in this app — hotkeys and
    /// config file changes — are already closures onto the same main actor,
    /// and a `for await` here would only add a hop.
    ///
    /// Disconnects do not come through it: they are already `onState`, and one
    /// state change reported twice is one too many.
    public init(
        onState: @escaping (Connection) -> Void,
        onEvent: @escaping (ObsEvent) -> Void
    ) {
        self.onState = onState
        self.onEvent = onEvent
    }

    // MARK: - Lifecycle

    /// Connect, and keep reconnecting until told to stop or until an error says
    /// retrying is pointless.
    public func start(_ settings: Config.OBS) {
        stop()
        loop = Task { [weak self] in await self?.run(settings) }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        close()
        state = .disconnected(.notStarted)
    }

    /// Interrupt, not cleanup. `URLSessionWebSocketTask.receive()` does not
    /// observe Task cancellation, so killing the socket from outside is the
    /// only thing that unblocks a `pump` waiting on OBS.
    private func close() {
        if let socket { release(socket) }
    }

    /// Release, guarded by identity.
    ///
    /// A `start()` while the previous attempt is still suspended installs a new
    /// socket before the old one finishes unwinding. Without this check the
    /// outgoing connection's release would take the incoming one down with it.
    private func release(_ socket: URLSessionWebSocketTask) {
        socket.cancel(with: .goingAway, reason: nil)
        if self.socket === socket { self.socket = nil }
    }

    private func run(_ settings: Config.OBS) async {
        var attempt = 0

        while !Task.isCancelled {
            let failure: ObsError
            do {
                try await connectOnce(settings)
                // Identify succeeded at least once, so the next outage starts its
                // backoff from scratch rather than inheriting a long delay.
                attempt = 0
                failure = .dropped("connection closed")
            } catch {
                failure = error
            }

            let reason = DisconnectReason(failure)
            // The socket is already released — connectOnce owns that. What is
            // left is the callers: nobody remains to answer an in-flight
            // request, and one suspended on it would wait forever.
            failPending(failure)
            guard !Task.isCancelled else { return }
            state = .disconnected(reason)

            guard let delay = retryDelay(reason, attempt: attempt) else { return }
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }

    // MARK: - One attempt

    /// Returns only when the socket closes; everything else is in E.
    private func connectOnce(_ settings: Config.OBS) async throws(ObsError) {
        guard let url = URL(string: "ws://\(settings.host):\(settings.port)") else {
            throw .dropped("bad host or port in config")
        }

        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        // The whole point of this bead: release is structural. Every exit from
        // here — returned, thrown, or interrupted — gives the socket back.
        defer { release(socket) }

        state = .connecting
        socket.resume()

        let hello: Hello = try await expect(0, on: socket)
        try await send(identify(for: hello, password: settings.password), on: socket)
        let _: Identified = try await expect(2, on: socket)

        state = .identified
        try await pump(socket)
    }

    private func identify(for hello: Hello, password: String) -> Identify {
        Identify(
            d: Identify.Body(
                rpcVersion: hello.rpcVersion,
                authentication: hello.authentication.map {
                    identifyAuthentication(password: password, salt: $0.salt, challenge: $0.challenge)
                }
            )
        )
    }

    /// Hold the socket open, handing each frame to whoever is waiting for it.
    private func pump(_ socket: URLSessionWebSocketTask) async throws(ObsError) {
        while !Task.isCancelled {
            dispatch(try await receive(on: socket))
        }
    }

    private func dispatch(_ data: Data) {
        if let id = responseId(in: data) {
            // An op 7 for an id nobody is waiting on is dropped on purpose: the
            // caller was cancelled, and that is not an error worth killing the
            // socket over.
            pending.removeValue(forKey: id)?.resume(returning: .success(data))
            return
        }
        if let event = obsEvent(in: data) { onEvent(event) }
    }

    // MARK: - Requests

    /// Send a request and wait for its response, discarding the response body.
    public func call(_ requestType: String, _ body: some Encodable) async throws(ObsError) {
        _ = try await perform(requestType, body)
    }

    /// Send a request and wait for its response, decoding `responseData`.
    public func call<D: Decodable>(
        _ requestType: String, _ body: some Encodable, as: D.Type
    ) async throws(ObsError) -> D {
        let data = try await perform(requestType, body)
        guard
            let response = try? JSONDecoder().decode(Payload<ResponseBody<D>>.self, from: data),
            let decoded = response.d.responseData
        else {
            throw .dropped("could not read the \(requestType) response")
        }
        return decoded
    }

    private func perform(
        _ requestType: String, _ body: some Encodable
    ) async throws(ObsError) -> Data {
        guard state.isUsable, let socket else { throw .dropped("not connected to OBS") }

        nextRequestId += 1
        let id = String(nextRequestId)

        try await send(
            RequestEnvelope(d: .init(requestType: requestType, requestId: id, requestData: body)),
            on: socket
        )

        // ponytail: no timeout. Every way OBS can fail to answer that has been
        // observed goes through the socket, and failPending covers those. Add
        // one if a request is ever seen to vanish with the socket still up.
        let result: Result<Data, ObsError> = await withCheckedContinuation { continuation in
            pending[id] = continuation
        }
        let data = try result.get()

        if let failure = requestFailure(in: data) { throw failure }
        return data
    }

    private func failPending(_ error: ObsError) {
        // Taken before resuming: a resumed caller may issue a new request, and
        // that one must not land in the map being torn down.
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(returning: .failure(error)) }
    }

    // MARK: - Wire

    /// Read until a message with the wanted opcode arrives, decoding its `d`.
    ///
    /// Skipping rather than failing on an unexpected opcode: OBS may legitimately
    /// interleave an event before Identified, and a strict reader would drop the
    /// connection over something harmless.
    private func expect<D: Decodable>(
        _ op: Int, on socket: URLSessionWebSocketTask
    ) async throws(ObsError) -> D {
        while !Task.isCancelled {
            let data = try await receive(on: socket)
            guard (try? JSONDecoder().decode(OpCode.self, from: data))?.op == op else { continue }
            guard let payload = try? JSONDecoder().decode(Payload<D>.self, from: data) else {
                throw .dropped("could not read op \(op) from OBS")
            }
            return payload.d
        }
        throw .dropped("cancelled")
    }

    private func receive(on socket: URLSessionWebSocketTask) async throws(ObsError) -> Data {
        do {
            switch try await socket.receive() {
            case let .string(text): return Data(text.utf8)
            case let .data(data): return data
            @unknown default: throw ObsError.dropped("unknown frame type")
            }
        } catch let error as ObsError {
            throw error
        } catch {
            throw failure(error, on: socket)
        }
    }

    private func send(_ message: some Encodable, on socket: URLSessionWebSocketTask) async throws(ObsError) {
        guard let data = try? JSONEncoder().encode(message) else {
            throw .dropped("could not encode a message for OBS")
        }
        do {
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            throw failure(error, on: socket)
        }
    }

    private func failure(_ error: Error, on socket: URLSessionWebSocketTask) -> ObsError {
        let ns = error as NSError
        return transportFailure(
            closeCode: socket.closeCode.rawValue,
            urlErrorCode: ns.domain == NSURLErrorDomain ? ns.code : nil,
            obsRunning: obsIsRunning(),
            detail: ns.localizedDescription
        )
    }
}

// MARK: - Envelopes

/// The opcode alone, read first so the payload can be decoded into the right
/// type from the same bytes.
struct OpCode: Decodable { let op: Int }

struct Payload<D: Decodable>: Decodable { let d: D }

struct Hello: Decodable {
    let rpcVersion: Int
    let authentication: Auth?

    struct Auth: Decodable {
        let challenge: String
        let salt: String
    }
}

/// Empty, but decoded rather than ignored so `expect` proves op 2 actually
/// arrived instead of assuming it did.
struct Identified: Decodable {}

struct Identify: Encodable {
    let op = 1
    let d: Body

    struct Body: Encodable {
        let rpcVersion: Int
        /// Omitted entirely when OBS is not asking for auth — sending null makes
        /// obs-websocket reject the Identify.
        let authentication: String?
    }
}

struct RequestEnvelope<Body: Encodable>: Encodable {
    let op = 6
    let d: D

    struct D: Encodable {
        let requestType: String
        let requestId: String
        let requestData: Body
    }
}

/// For requests that take no arguments. Encodes as `{}`, which obs-websocket
/// accepts.
public struct NoBody: Encodable {
    public init() {}
}

struct ResponseHeader: Decodable {
    let requestId: String
    let requestStatus: Status

    struct Status: Decodable {
        let result: Bool
        let code: Int
        let comment: String?
    }
}

struct ResponseBody<D: Decodable>: Decodable {
    let responseData: D?
}

// MARK: - Reading a response

/// The requestId an op 7 belongs to, or nil if this is not a response at all.
///
/// Pure, and deliberately tolerant: anything unrecognised is "not for us"
/// rather than a parse failure, because op 5 events come down the same pipe.
public func responseId(in data: Data) -> String? {
    guard (try? JSONDecoder().decode(OpCode.self, from: data))?.op == 7 else { return nil }
    return try? JSONDecoder().decode(Payload<ResponseHeader>.self, from: data).d.requestId
}

/// The error in an op 7, or nil when it succeeded.
///
/// Pure so the mapping from OBS's `requestStatus` to a typed value is checkable
/// against real captured JSON without a socket.
public func requestFailure(in data: Data) -> ObsError? {
    guard let header = try? JSONDecoder().decode(Payload<ResponseHeader>.self, from: data).d else {
        return .dropped("unreadable response from OBS")
    }
    guard header.requestStatus.result else {
        return .requestFailed(
            code: header.requestStatus.code, comment: header.requestStatus.comment
        )
    }
    return nil
}

// MARK: - Auth

/// obs-websocket's challenge:
/// `base64(sha256(base64(sha256(password + salt)) + challenge))`.
public func identifyAuthentication(password: String, salt: String, challenge: String) -> String {
    func digest(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
    }
    return digest(digest(password + salt) + challenge)
}

// MARK: - Is OBS even running

let obsBundleIdentifier = "com.obsproject.obs-studio"

/// Used only to tell "OBS is not running" apart from "its server is off", which
/// look identical at the socket.
@MainActor
func obsIsRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: obsBundleIdentifier).isEmpty
}
