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
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?

    public init(onState: @escaping (Connection) -> Void) {
        self.onState = onState
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

    private func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func run(_ settings: Config.OBS) async {
        var attempt = 0

        while !Task.isCancelled {
            let reason: DisconnectReason
            do {
                try await connectOnce(settings)
                // Identify succeeded at least once, so the next outage starts its
                // backoff from scratch rather than inheriting a long delay.
                attempt = 0
                reason = .dropped("connection closed")
            } catch {
                reason = DisconnectReason(error)
            }

            close()
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

    /// Hold the socket open. Payloads are ignored here — correlating responses
    /// and surfacing events are their own beads; what this does today is notice
    /// the moment the connection dies.
    private func pump(_ socket: URLSessionWebSocketTask) async throws(ObsError) {
        while !Task.isCancelled {
            _ = try await receive(on: socket)
        }
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
