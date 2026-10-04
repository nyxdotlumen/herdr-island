import Foundation
import CoreGraphics

public enum IslandPhase: Equatable, Sendable { case hidden, compact, expanded }

public struct NotchGeometry: Equatable, Sendable {
    public let screen: CGRect
    public let centerX: CGFloat
    public let notchWidth: CGFloat
    public let notchHeight: CGFloat
    public let hasNotch: Bool

    public init(screen: CGRect, safeTop: CGFloat, leftArea: CGRect? = nil, rightArea: CGRect? = nil) {
        self.screen = screen
        if safeTop > 0, let leftArea, let rightArea,
           rightArea.minX > leftArea.maxX, rightArea.minX - leftArea.maxX < screen.width / 2 {
            self.centerX = (leftArea.maxX + rightArea.minX) / 2
            self.notchWidth = rightArea.minX - leftArea.maxX
            self.notchHeight = safeTop
            self.hasNotch = true
        } else {
            self.centerX = screen.midX
            self.notchWidth = 180
            self.notchHeight = 12
            self.hasNotch = false
        }
    }

    public var expandedWidth: CGFloat { min(664, screen.width - 48) }
    public var expandedHeight: CGFloat { min(notchHeight + 468, screen.height - 72) }
    public var contentHeight: CGFloat { expandedHeight - notchHeight }

    public func size(for phase: IslandPhase) -> CGSize {
        switch phase {
        case .hidden: return CGSize(width: notchWidth, height: notchHeight)
        case .compact: return CGSize(width: min(400, screen.width - 48), height: notchHeight + 44)
        case .expanded: return CGSize(width: expandedWidth, height: expandedHeight)
        }
    }

    /// The top never moves; only the sides and bottom animate. Extra room holds the spring/shadow.
    public func panelFrame(from: IslandPhase, to: IslandPhase) -> CGRect {
        let a = size(for: from), b = size(for: to)
        let width = max(a.width, b.width) + 48
        let height = max(a.height, b.height) + 32
        return CGRect(x: centerX - width / 2, y: screen.maxY - height, width: width, height: height)
    }
}

/// Frames use AppKit's global bottom-left coordinates. Screen zero is the menu-bar display.
public enum DisplaySelection {
    public static func index(screens: [CGRect], primary: Int = 0, window: CGRect?, pointer: CGPoint,
                             usePrimary: Bool = false) -> Int? {
        guard !screens.isEmpty else { return nil }
        let fallback = screens.indices.contains(primary) ? primary : 0
        if usePrimary { return fallback }
        if let window {
            let areas = screens.map { frame -> CGFloat in
                let overlap = frame.intersection(window)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        }
        return screens.firstIndex(where: { $0.contains(pointer) }) ?? fallback
    }
    public static func appKitRect(quartz: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
    }
}
