// §3 Stream: OBS's program scene, into the HUD's preview box.
//
// Independent of the tick path on purpose. It reads, never writes, and if it
// dies the zoom is unaffected — which is the property that matters, since this
// is decoration on a tool with an invariant about not damaging layouts.
//
// R is explicit: `connection` is OBS, `scene` is whatever the app currently
// considers the program scene, `show` is the HUD. Swap all three and this runs
// with no machine underneath it.

import AppKit
import LookitCore

@MainActor
public final class PreviewFeed {
    private let connection: OBSConnection
    private let scene: () -> SceneName?
    private let show: (NSImage?, Bool) -> Void

    private var task: Task<Void, Never>?
    private var burstUntil: ContinuousClock.Instant = .now
    /// Consecutive failed refreshes while still connected.
    private var failures = 0
    private var lastFrame: NSImage?

    public init(
        connection: OBSConnection,
        scene: @escaping () -> SceneName?,
        show: @escaping (NSImage?, Bool) -> Void
    ) {
        self.connection = connection
        self.scene = scene
        self.show = show
    }

    deinit { task?.cancel() }

    // MARK: - Lifecycle

    /// Runs until stopped. The loop guards on connection state itself rather
    /// than being started and stopped from outside, so there is no lifecycle to
    /// get wrong — a disconnected feed is just one that shows nothing.
    public func start() {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Something changed the framing, so look more often for a moment.
    ///
    /// Called from the one path to a reframe, which covers hotkeys and stop
    /// clicks alike. Deliberately **not** called from the tick loop: that runs
    /// at 30Hz for the whole time the shot is zoomed, so bumping from there
    /// would pin the feed at burst rate for the entire session instead of the
    /// second after a press.
    public func bump() {
        burstUntil = .now + .seconds(1)
    }

    /// 2fps at rest; 8fps for a second after a change.
    ///
    /// Flat 2fps is wrong at the only moment that matters: an ease takes 350ms,
    /// so a press would show one frame or none and you could not tell whether
    /// the shot landed. Bursts are brief and event-driven, so the average cost
    /// stays at the resting rate.
    private var interval: Duration {
        ContinuousClock.now < burstUntil ? .milliseconds(125) : .milliseconds(500)
    }

    // MARK: - One frame

    private func refresh() async {
        guard connection.state.isUsable, let scene = scene() else {
            // Nothing to show and a reason already on screen: drop the stale
            // frame rather than leaving a picture that looks current.
            lastFrame = nil
            failures = 0
            show(nil, false)
            return
        }

        guard
            let response = try? await connection.call(
                "GetSourceScreenshot", ScreenshotRequest(scene: scene), as: ScreenshotResponse.self
            ),
            let data = imageData(fromDataURI: response.imageData),
            let image = NSImage(data: data)
        else {
            // A confidence check that is confidently wrong is worse than none,
            // so a frame that stops updating has to start looking wrong. One
            // hiccup is not worth a flicker; a run of them is worth saying.
            failures += 1
            show(lastFrame, failures >= 2)
            return
        }

        failures = 0
        lastFrame = image
        show(image, false)
    }
}

// MARK: - Boundary

/// The bytes inside a `data:image/jpg;base64,…` URI, or nil if it is not one.
///
/// Pure, and deliberately strict about the prefix: this is untrusted input from
/// the socket, and "decoded something" is not the same as "was given an image".
public func imageData(fromDataURI uri: String) -> Data? {
    guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
    return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
}
