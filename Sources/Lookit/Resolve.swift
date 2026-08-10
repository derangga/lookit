// §2 A-path: finding the thing to zoom.
//
// The one node that turns "OBS is connected" into "here is the Target". Runs at
// launch and again whenever the program scene changes.

import Foundation
import LookitCore

/// Find the capture in the current scene, or say why there isn't one.
///
/// Never throws. `TargetState.unresolved` is a **success value** — every way
/// this can fail is an escape the HUD can state plainly, and none of them is
/// the caller's problem to handle. That is why the guards below read as part of
/// the happy path rather than as error handling.
///
/// R is explicit: `locate` and `owner` are the window server, `connection` is
/// OBS. Swap all three and this runs with no machine underneath it.
@MainActor
public func resolveTarget(
    connection: OBSConnection,
    locate: (WindowID) -> CaptureRect?,
    owner: (WindowID) -> String?,
    preferring: (SceneName) -> InputName? = { _ in nil }
) async -> TargetState {
    guard connection.state.isUsable else { return .unresolved(.notConnected) }

    do {
        let scene = try await connection.call(
            "GetCurrentProgramScene", NoBody(), as: CurrentSceneResponse.self
        ).sceneName

        let items = try await connection.call(
            "GetSceneItemList", SceneRequest(scene), as: SceneItemListResponse.self
        )
        let item = try pickCaptureItem(items.summaries, preferring: preferring(scene))

        let input = try await connection.call(
            "GetInputSettings", InputRequest(item.inputName), as: InputSettingsResponse.self
        )
        let binding = captureBinding(from: input.inputSettings)
        if let unsupported = UnresolvedReason(unsupported: binding) {
            return .unresolved(unsupported)
        }
        guard case let .window(window) = binding else { return .unresolved(.windowGone) }

        let transform = try await connection.call(
            "GetSceneItemTransform", SceneItemRequest(scene: scene, itemId: item.id),
            as: SceneItemTransformResponse.self
        ).sceneItemTransform

        // OBS answers 0x0 for a capture whose window has gone, which is the
        // cheapest possible proof that the binding is dead — no window server
        // lookup needed to know it.
        guard let source = transform.sourceSize else { return .unresolved(.degenerateSource) }

        // The id came out of OBS's saved settings and can be stale, so it is
        // not trusted until the window it names is the size OBS says it is
        // capturing.
        guard let rect = locate(window), matchesSource(rect, source) else {
            return .unresolved(.windowGone)
        }

        return .resolved(
            Target(
                scene: scene, itemId: item.id, inputName: item.inputName,
                window: window,
                // From the window server, never from OBS's `application`.
                bundleID: owner(window),
                transform: transform
            )
        )
    } catch {
        return .unresolved(UnresolvedReason(resolving: error))
    }
}

extension UnresolvedReason {
    /// Scope everything the resolve path can throw into one vocabulary, so no
    /// caller ever sees an ObsError or a TargetError from three layers down.
    init(resolving error: any Error) {
        switch error {
        case let target as TargetError:
            self.init(target)
        case let obs as ObsError:
            // A socket that died mid-resolve is reported as what it is; the HUD
            // ranks the connection above the target anyway, so this rarely shows.
            self = if case .requestFailed = obs {
                .obsRefused(DisconnectReason(obs).message)
            } else {
                .notConnected
            }
        default:
            self = .obsRefused(String(describing: error))
        }
    }
}

extension WindowLocator {
    /// The locator resolve uses: the id has not been validated yet, so there is
    /// no owner to expect.
    public static var unverified: WindowLocator { .live(expecting: nil) }
}
