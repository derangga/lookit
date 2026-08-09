// Prints the HUD panel's screen rect as "x,y,w,h" in top-left global points,
// which is the form screencapture -R wants. Used by verify-hud-not-captured.sh.
import AppKit

let infos =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []

for info in infos where (info[kCGWindowOwnerName as String] as? String) == "lookit" {
    guard let b = info[kCGWindowBounds as String] as? [String: Any],
        let x = b["X"] as? Double, let y = b["Y"] as? Double,
        let w = b["Width"] as? Double, let h = b["Height"] as? Double
    else { continue }
    print("\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h))")
    exit(0)
}

FileHandle.standardError.write(Data("no lookit window on screen\n".utf8))
exit(1)
