import Foundation
import CoreGraphics

/// Normal list: 280–380 pt. Drag beyond its minimum to snap into a 96 pt rail.
/// The screen owns hinge placement; this helper only handles unfolded resizing.
enum DYMessageSidebarLayout {
    static let compactWidth: CGFloat = 96
    static let collapseDistance: CGFloat = 40
    static let expansionDistance: CGFloat = 48

    static func showsSplit(in size: CGSize, window: CGSize = .zero) -> Bool {
        let orientation = window == .zero ? size : window
        return size.width >= 560 && orientation.width > orientation.height
    }

    static func expandedBounds(in width: CGFloat) -> ClosedRange<CGFloat> {
        let upper = max(compactWidth, min(380, width / 2))
        return min(280, upper)...upper
    }

    static func listWidth(fraction: Double, in width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let bounds = expandedBounds(in: width)
        guard fraction.isFinite else { return min(max(width * 0.36, bounds.lowerBound), bounds.upperBound) }
        if fraction <= 0 { return compactWidth }
        return min(max(width * fraction, bounds.lowerBound), bounds.upperBound)
    }

    static func fraction(startWidth: CGFloat, translation: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return 0.36 }
        let bounds = expandedBounds(in: width)
        let proposed = startWidth + translation
        if startWidth <= compactWidth + 1 {
            guard proposed > compactWidth + expansionDistance else { return 0 }
            return min(bounds.upperBound, bounds.lowerBound + proposed - compactWidth - expansionDistance) / width
        }
        guard proposed >= bounds.lowerBound - collapseDistance else { return 0 }
        return min(max(proposed, bounds.lowerBound), bounds.upperBound) / width
    }
}
