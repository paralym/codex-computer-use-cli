import AppKit
import CoreGraphics

/// Smooth cursor motion along an S-curve (cubic bezier) with spring physics.
///
/// Replicates the fluid AI cursor animation seen in Codex:
/// - Cubic bezier path with perpendicular control points (S-curve)
/// - Spring-based easing for natural acceleration/deceleration
/// - Configurable arc size, flow direction, and spring parameters
@MainActor
public final class CursorMotion {
    public static let shared = CursorMotion()

    // MARK: - Configuration

    /// How far the bezier control points extend perpendicular to the line (0..1)
    public var arcSize: CGFloat = 0.35
    /// Controls which side the S-curve bows toward (positive = right, negative = left)
    public var arcFlow: CGFloat = 1.0
    /// Spring damping ratio (0..1, lower = more bouncy)
    public var springDamping: CGFloat = 0.7
    /// Spring frequency (higher = faster)
    public var springFrequency: CGFloat = 2.5
    /// Total animation duration in seconds
    public var duration: TimeInterval = 0.4
    /// Number of interpolation steps
    public var steps: Int = 60

    private init() {}

    // MARK: - Animate

    /// Animate the ComputerUseCursor from its current position to `destination`
    /// along a smooth S-curve path with spring easing.
    ///
    /// - Parameters:
    ///   - from: Starting point in CG screen coordinates (top-left origin)
    ///   - to: Destination point in CG screen coordinates
    ///   - completion: Called when animation completes
    public func animate(from: CGPoint, to: CGPoint, completion: (() -> Void)? = nil) {
        let cursor = ComputerUseCursor.shared

        // Show cursor at start if not visible
        if !cursor.isVisible {
            cursor.show()
            cursor.moveTo(from, animated: false)
        }

        // Build the S-curve path
        let path = buildSCurve(from: from, to: to)

        // Animate along the path with spring easing
        let stepDelay = duration / Double(steps)
        for i in 0..<steps {
            let t = Double(i) / Double(steps - 1)
            let easedT = springEase(t)
            let point = evaluateBezier(path: path, t: easedT)

            DispatchQueue.main.asyncAfter(deadline: .now() + stepDelay * Double(i)) {
                cursor.moveTo(point, animated: false)
                if i == self.steps - 1 {
                    completion?()
                }
            }
        }
    }

    /// Animate cursor to destination, pulse on arrival, then hide after delay.
    public func animateAndClick(from: CGPoint, to: CGPoint, hideDelay: TimeInterval = 2.0) {
        animate(from: from, to: to) {
            ComputerUseCursor.shared.pulseClick()
            DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay) {
                ComputerUseCursor.shared.hide()
            }
        }
    }

    // MARK: - S-Curve (Cubic Bezier)

    private struct BezierPath {
        let p0: CGPoint  // start
        let p1: CGPoint  // control point 1
        let p2: CGPoint  // control point 2
        let p3: CGPoint  // end
    }

    /// Build a cubic bezier S-curve between two points.
    ///
    /// The control points are placed perpendicular to the line connecting start→end,
    /// on opposite sides, creating the characteristic S-shape:
    ///
    /// ```
    ///        p1
    ///       /
    ///  p0--'         (S-curve)
    ///          `--p3
    ///            \
    ///             p2
    /// ```
    private func buildSCurve(from: CGPoint, to: CGPoint) -> BezierPath {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let dist = hypot(dx, dy)

        // Perpendicular direction (rotated 90 degrees)
        let perpX: CGFloat
        let perpY: CGFloat
        if dist > 0.001 {
            perpX = -dy / dist
            perpY = dx / dist
        } else {
            perpX = 0
            perpY = 1
        }

        // Control point offset magnitude
        let offset = dist * arcSize * arcFlow

        // Place control points at 1/3 and 2/3 along the line, offset perpendicularly
        // in opposite directions to create the S-shape
        let p1 = CGPoint(
            x: from.x + dx * 0.33 + perpX * offset,
            y: from.y + dy * 0.33 + perpY * offset
        )
        let p2 = CGPoint(
            x: from.x + dx * 0.67 - perpX * offset,
            y: from.y + dy * 0.67 - perpY * offset
        )

        return BezierPath(p0: from, p1: p1, p2: p2, p3: to)
    }

    /// Evaluate a cubic bezier at parameter t ∈ [0, 1]
    private func evaluateBezier(path: BezierPath, t: Double) -> CGPoint {
        let t = CGFloat(t)
        let mt = 1 - t
        let mt2 = mt * mt
        let mt3 = mt2 * mt
        let t2 = t * t
        let t3 = t2 * t

        let x = mt3 * path.p0.x + 3 * mt2 * t * path.p1.x + 3 * mt * t2 * path.p2.x + t3 * path.p3.x
        let y = mt3 * path.p0.y + 3 * mt2 * t * path.p1.y + 3 * mt * t2 * path.p2.y + t3 * path.p3.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Spring Easing

    /// Spring-based easing function. Maps linear t ∈ [0,1] to eased t ∈ [0,1]
    /// with overshoot and settling behavior controlled by damping and frequency.
    private func springEase(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }

        let omega = springFrequency * 2.0 * .pi  // angular frequency
        let zeta = Double(springDamping)

        if zeta < 1.0 {
            // Under-damped: oscillation with decay
            let omegaD = omega * sqrt(1 - zeta * zeta)
            let envelope = exp(-zeta * omega * t)
            return 1 - envelope * (cos(omegaD * t) + (zeta * omega / omegaD) * sin(omegaD * t))
        } else {
            // Critically/over-damped: smooth approach without oscillation
            let envelope = exp(-omega * t)
            return 1 - envelope * (1 + omega * t)
        }
    }
}
