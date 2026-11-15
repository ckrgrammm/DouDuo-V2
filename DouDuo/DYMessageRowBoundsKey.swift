import SwiftUI

/// Extend visible pinned rows behind Duo's system column without putting row
/// controls outside the safe area. Anchors also follow scrolling and rotation.
struct DYMessageRowBoundsKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
