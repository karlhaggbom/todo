import SwiftUI

// MARK: - Speed-based card distortion ("flick" effect)

/// Shear (CATransform3D-style lean via CGAffineTransform, c-coefficient):
/// x' = x + shear·y — the card leans into the direction of travel, like a
/// card flicked across a table. Animated via animatableData so it springs
/// back smoothly on release.
struct ShearEffect: ViewModifier {
    var shear: CGFloat

    func body(content: Content) -> some View {
        content.transformEffect(CGAffineTransform(a: 1, b: 0, c: shear, d: 1, tx: 0, ty: 0))
    }

    var animatableData: CGFloat {
        get { shear }
        set { shear = newValue }
    }
}

/// Composite distortion driven by smoothed horizontal velocity:
/// lean (shear) + slight rotation + horizontal stretch + vertical squash.
struct CardDistortion: ViewModifier {
    /// Smoothed velocity in pts/s; sign gives direction.
    var vx: CGFloat

    private var t: CGFloat {
        // Normalize: full distortion at ~3000 pts/s.
        let raw = vx / 3000
        return max(-1, min(1, raw))
    }

    func body(content: Content) -> some View {
        let t = self.t
        content
            .modifier(ShearEffect(shear: t * 0.22))
            .rotationEffect(.degrees(t * 3.5), anchor: .center)
            .scaleEffect(x: 1 + abs(t) * 0.05, y: 1 - abs(t) * 0.10, anchor: .center)
    }
}