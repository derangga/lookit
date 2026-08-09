// §1 Shapes — the E channel for the transport, and §4's retry/escape decision.
//
// This is the only layer that knows OBS is reached over a network. Everything
// above sees these cases, never an NSError and never a string.

import Foundation

public enum ObsError: Error, Equatable, Sendable {
    /// Nothing is listening. OBS is probably not running.
    case refused
    /// OBS is running but its WebSocket server is switched off.
    case serverDisabled
    /// The password is wrong.
    case authFailed
    /// A request reached OBS and came back refused.
    case requestFailed(code: Int, comment: String?)
    /// The socket died for some other reason, carrying what the OS said.
    case dropped(String)
}

extension DisconnectReason {
    /// Scope a transport error into the state the rest of the app reasons about.
    public init(_ error: ObsError) {
        switch error {
        case .refused: self = .refused
        case .serverDisabled: self = .serverDisabled
        case .authFailed: self = .authFailed
        case let .dropped(detail): self = .dropped(detail)
        case let .requestFailed(code, comment):
            self = .dropped("request failed (\(code))\(comment.map { ": \($0)" } ?? "")")
        }
    }
}

// MARK: - Classifying a transport failure

/// obs-websocket closes with this code when Identify carries the wrong auth.
/// The thrown error is an unhelpful generic POSIX 57, so the close code is the
/// only reliable signal.
public let authenticationFailedCloseCode = 4009

/// What a socket failure actually means.
///
/// Pure so the mapping is checkable without a network: the caller supplies what
/// it observed. `urlErrorCode` is the `NSURLErrorDomain` code when the error came
/// from one, nil otherwise.
///
/// Refused and serverDisabled are indistinguishable at the socket — both are
/// -1004 — because a disabled server means nothing is bound to the port. Whether
/// OBS is running is what separates "start OBS" from "enable the server", and
/// those need different HUD messages and different retry speeds.
public func transportFailure(
    closeCode: Int, urlErrorCode: Int?, obsRunning: Bool, detail: String
) -> ObsError {
    if closeCode == authenticationFailedCloseCode { return .authFailed }
    if urlErrorCode == NSURLErrorCannotConnectToHost {
        return obsRunning ? .serverDisabled : .refused
    }
    return .dropped(detail)
}

// MARK: - §4 retry or escape

/// How long to wait before reconnecting, or nil to stop trying.
///
/// Pure, so the escalation is checkable without waiting for it.
public func retryDelay(_ reason: DisconnectReason, attempt: Int) -> Duration? {
    switch reason {
    // Escape, not retry. A wrong password will never become right by trying
    // again, and a reconnect loop would hammer OBS forever for nothing.
    case .authFailed:
        return nil

    // Retry, but slowly: this one needs the user to go and click something, so
    // fast polling is pure noise. Slow enough to be free, quick enough that
    // enabling the server feels like it just connects.
    case .serverDisabled:
        return .seconds(5)

    case .notStarted, .refused, .dropped:
        // 0.5s doubling to a 10s ceiling: fast enough that starting OBS feels
        // instant, bounded so a long absence costs nothing.
        let seconds = min(0.5 * pow(2, Double(max(attempt, 0))), 10)
        return .milliseconds(Int(seconds * 1000))
    }
}
