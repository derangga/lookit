// §9: the same graph, with R as parameters.
//
// The loop lived in the app shell first, which meant it could only run with a
// real clock, a real cursor and a real OBS. That is exactly the hidden
// dependency §9 exists to catch — so R is a struct of closures, and the shell
// is now just the thing that calls `step` on a timer.

import Foundation
import LookitCore

@MainActor
public final class TickLoop {
    /// Everything the loop needs from outside itself.
    public struct Environment {
        public var cursor: () -> ScreenPoint
        public var locate: (CaptureSource) -> CaptureRect?
        /// Monotonic seconds. A parameter so the ease can be stepped by hand.
        public var now: () -> Double
        public var send: (SetSceneItemTransformRequest) -> Void

        public init(
            cursor: @escaping () -> ScreenPoint,
            locate: @escaping (CaptureSource) -> CaptureRect?,
            now: @escaping () -> Double,
            send: @escaping (SetSceneItemTransformRequest) -> Void
        ) {
            self.cursor = cursor
            self.locate = locate
            self.now = now
            self.send = send
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Still easing, or still following the cursor.
        case running
        /// Back at rest with the ease finished — the caller should release.
        case settled
        /// The source went away mid-session. Not an error: stop and re-resolve.
        case sourceGone
        /// Nothing is held.
        case idle
    }

    private struct Held {
        let pristine: Pristine
        let source: CaptureSource
        var center: SourcePoint
    }

    private let environment: Environment
    private let deadZone: Double
    private let panRate: Double
    private let easeSeconds: Double
    private let resting: Double

    private var held: Held?
    private var from = 1.0
    private var to = 1.0
    private var startedAt = 0.0
    /// When `step` last ran, so the pan can be advanced by real elapsed time
    /// rather than by an assumed 30Hz.
    private var lastStepAt: Double?

    public private(set) var zoom = 1.0

    public init(
        environment: Environment, deadZone: Double, panRate: Double, easeMs: Int, resting: Double
    ) {
        self.environment = environment
        self.deadZone = deadZone
        self.panRate = panRate
        easeSeconds = Double(max(easeMs, 0)) / 1000
        self.resting = resting
        zoom = resting
        from = resting
        to = resting
    }

    public var isHolding: Bool { held != nil }
    public var panCenter: SourcePoint? { held?.center }

    /// Point the ease at a new stop.
    ///
    /// Eases from wherever the zoom actually is, never from the stop it was
    /// heading for, so pressing the key mid-animation does not snap backwards.
    public func aim(at stop: Double, pristine: Pristine, source: CaptureSource) {
        if held == nil {
            let size = pristine.transform.sourceSize ?? SourceSize(width: 0, height: 0)
            held = Held(
                pristine: pristine, source: source,
                center: SourcePoint(x: size.width / 2, y: size.height / 2)
            )
        }
        from = zoom
        to = stop
        startedAt = environment.now()
    }

    public func stopHolding() {
        held = nil
        lastStepAt = nil
        zoom = resting
        from = resting
        to = resting
    }

    /// One frame.
    public func step() -> Outcome {
        guard let held, let source = held.pristine.transform.sourceSize else { return .idle }

        let now = environment.now()
        let progress = easeSeconds <= 0 ? 1 : (now - startedAt) / easeSeconds
        zoom = eased(from: from, to: to, progress: progress)

        // Clamped the way zoominator clamps its frame delta: only to survive a
        // stalled tick, not to impose a rate of our own. Unclamped, a machine
        // that froze for a second would hand the pan a dt large enough to close
        // the whole distance in one frame — exactly the snap the chase exists
        // to avoid. The first step has no predecessor, so it assumes the 30Hz
        // the caller is aiming for.
        let dt = min(max(now - (lastStepAt ?? now - 1.0 / 30), 1.0 / 480), 1.0 / 20)
        lastStepAt = now

        // Re-read every tick: a window moves, a display gets rearranged, and
        // one that has gone — or whose id was recycled to another app — must
        // stop the zoom rather than frame something else.
        guard let rect = environment.locate(held.source) else { return .sourceGone }

        let framed = framing(
            cursor: environment.cursor(), rect: rect, source: source,
            zoom: zoom, center: held.center, deadZone: deadZone,
            panRate: panRate, dt: dt
        )
        self.held?.center = framed.center

        // Sent before reporting settled, so the frame that lands the ease on
        // its target is never the one skipped.
        environment.send(
            SetSceneItemTransformRequest(
                scene: held.pristine.scene, itemId: held.pristine.itemId,
                transform: reframed(held.pristine.transform, crop: framed.crop)
            )
        )

        return progress >= 1 && to <= resting ? .settled : .running
    }
}
