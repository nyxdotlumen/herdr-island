import AppKit
import SwiftUI
import IslandCore

@MainActor
final class NotchPresentation: ObservableObject {
    @Published var phase: IslandPhase = .hidden
    @Published var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), safeTop: 0)

    func setPhase(_ value: IslandPhase, animated: Bool) {
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.interpolatingSpring(mass: 1, stiffness: 380, damping: 36, initialVelocity: 0)) { phase = value }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { phase = value }
        }
    }
}

/// Concave shoulders meet the menu-bar edge; the black body merges with the camera housing.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var radius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set { shoulder = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.height / 3)
        let r = min(radius, (rect.height - s) / 2)
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: w, y: 0))
        path.addCurve(to: CGPoint(x: w - s, y: s), control1: CGPoint(x: w - s, y: 0), control2: CGPoint(x: w - s, y: s * 0.5))
        path.addLine(to: CGPoint(x: w - s, y: h - r))
        path.addQuadCurve(to: CGPoint(x: w - s - r, y: h), control: CGPoint(x: w - s, y: h))
        path.addLine(to: CGPoint(x: s + r, y: h))
        path.addQuadCurve(to: CGPoint(x: s, y: h - r), control: CGPoint(x: s, y: h))
        path.addLine(to: CGPoint(x: s, y: s))
        path.addCurve(to: .zero, control1: CGPoint(x: s, y: s * 0.5), control2: CGPoint(x: s, y: 0))
        path.closeSubpath()
        return path
    }
}
