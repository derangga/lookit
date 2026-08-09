// Turning "where is the cursor" into an answer. Still pure — asking the
// window server happens above this.

/// Map a screen cursor position into the captured source's pixel space.
///
/// Returns `nil` when the cursor is outside the captured window. That is not an
/// error: it is the Frozen state, where the shot holds its last position.
public func mapCursorToSource(cursor: ScreenPoint, rect: CaptureRect) -> SourcePoint? {
    let dx = cursor.x - rect.x
    let dy = cursor.y - rect.y

    guard dx >= 0, dy >= 0, dx <= rect.width, dy <= rect.height else { return nil }

    return SourcePoint(x: dx * rect.scale, y: dy * rect.scale)
}
