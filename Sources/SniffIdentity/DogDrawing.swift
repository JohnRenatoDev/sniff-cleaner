import CoreGraphics
import Foundation

/// The dachshund's planted paws anchor its rocking hips, sniffing head and wagging tail.
public enum DogDrawing {
    public static func draw(in context: CGContext, size: CGSize, pose: DogPose = .resting,
                            ink: CGColor, lineWidth: CGFloat = 2.65, compact: Bool = false) {
        let bounds = compact ? CGRect(x: -4, y: 0, width: 182, height: 100) : CGRect(x: 0, y: 0, width: 180, height: 110)
        let scale = min(size.width / bounds.width, size.height / bounds.height)
        context.saveGState()
        context.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        // Apply semantic-color opacity once, so joined strokes do not leave dark knots.
        context.setAlpha(ink.alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer(); context.restoreGState() }
        let solidInk = ink.copy(alpha: 1) ?? ink
        context.setStrokeColor(solidInk); context.setFillColor(solidInk)
        context.setLineWidth(lineWidth); context.setLineCap(.round); context.setLineJoin(.round)

        func move(_ x: CGFloat, _ y: CGFloat) { context.move(to: CGPoint(x: x, y: y)) }
        func curve(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            context.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
        }
        func stroke(_ draw: () -> Void) { context.beginPath(); draw(); context.strokePath() }
        func rotate(_ radians: Double, around pivot: CGPoint) {
            context.translateBy(x: pivot.x, y: pivot.y); context.rotate(by: radians)
            context.translateBy(x: -pivot.x, y: -pivot.y)
        }
        let hipX = CGFloat(pose.rumpSway), hipY = CGFloat(pose.rumpLift)
        let yaw = CGFloat(pose.headTurn) * 0.09
        func headPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let dx = x - 130 + yaw * (y - 54), dy = y - 54
            let angle = CGFloat(pose.headAngle)
            return CGPoint(x: 130 + dx * cos(angle) - dy * sin(angle),
                           y: 54 + dx * sin(angle) + dy * cos(angle))
        }

        context.saveGState()
        context.translateBy(x: hipX, y: hipY)
        rotate(pose.tailAngle, around: CGPoint(x: 39, y: 43))
        func tailPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let weight = pow(max(0, (43 - y) / 26), 2)
            return CGPoint(x: x + CGFloat(pose.tailBend) * weight,
                           y: y + CGFloat(abs(pose.tailBend)) * weight * 0.1)
        }
        stroke {
            context.move(to: tailPoint(40, 41))
            context.addCurve(to: tailPoint(20, 17), control1: tailPoint(27, 42), control2: tailPoint(17, 28))
            context.addCurve(to: tailPoint(38, 45), control1: tailPoint(10, 25), control2: tailPoint(15, 44))
        }
        context.restoreGState()

        // Far hind leg sits behind the nearer thigh. Both feet stay on the ground.
        stroke {
            move(37.5, 72)
            curve(35, 74.5, 41.5, 77, 43, 81)
            curve(44.5, 84.5, 49, 83.8, 52, 83)
            curve(55.7, 82, 53.5, 78, 48, 78.5)
            curve(45.5, 75, 45, 74.5, 47.3, 71)
        }
        stroke {
            move(40 + hipX, 41 + hipY)
            curve(53.75 + hipX * 0.8, 34.5 + hipY, 63.5 + hipX * 0.5, 36.875 + hipY * 0.7, 75.25 + hipX * 0.25, 41 + hipY * 0.3)
            curve(86.25, 44.625 + hipY * 0.15, 93.125, 47, 104.625, 44.75)
            curve(115.625, 42.875, 117.25, 47.25, 131.5, 53.375)
        }
        stroke {
            move(38 + hipX, 45 + hipY)
            curve(32 + hipX, 53 + hipY, 34.7 + hipX * 0.7, 56.7 + hipY * 0.6, 34.2 + hipX * 0.4, 62.3 + hipY * 0.3)
            curve(34 + hipX * 0.2, 67, 27, 67.4, 25, 71.4)
            curve(23, 75, 22, 80, 22.5, 83.4)
            curve(22.8, 86, 28.8, 85.8, 31.3, 84.8)
            curve(33, 83.5, 31.8, 80.4, 29, 80)
            curve(30, 74, 33.5, 72, 39.5, 71.5)
            curve(51, 70.7, 57.5 + hipX * 0.3, 64.9 + hipY * 0.3, 58.8 + hipX * 0.5, 57.4 + hipY * 0.6)
        }
        stroke {
            move(57.5 + hipX * 0.4, 63 + hipY * 0.4)
            curve(70 + hipX * 0.2, 62 + hipY * 0.2, 77, 75, 95, 73.5)
        }
        stroke {
            move(98.25, 63)
            curve(94, 66, 92, 70, 94, 72)
            curve(96, 74.5, 101, 76, 102.5, 80)
            curve(103.5, 85, 108, 85, 113.5, 84.7)
            curve(118, 84.7, 116, 78.5, 110, 79)
            curve(109, 76.5, 108, 74, 107, 71)
        }
        stroke {
            move(107, 73.3)
            curve(112, 72.8, 117, 70.4, 117.25, 65.125)
            move(115, 69.5)
            let neck = headPoint(120, 71.5)
            curve(117, 70, 118.5, 70.8, neck.x, neck.y)
        }
        if !compact {
            context.saveGState(); context.setLineWidth(lineWidth * 0.55)
            stroke {
                move(27.5, 83); curve(28.1, 83.2, 28.3, 84.5, 28.2, 85.3)
                move(29.6, 82.6); curve(30.3, 82.8, 30.5, 84, 30.4, 85)
                move(49, 81.7); curve(49.7, 81.8, 50, 82.6, 50, 83.4)
                move(51, 81.1); curve(51.7, 81.2, 52.1, 82.2, 52, 83)
                move(111, 82); curve(111.8, 82.2, 112.1, 83.6, 112, 84.7)
                move(113.2, 81.6); curve(114, 81.8, 114.3, 83.3, 114.2, 84.4)
            }
            context.restoreGState()
        }

        context.saveGState()
        rotate(pose.headAngle, around: CGPoint(x: 130, y: 54))
        context.translateBy(x: 130, y: 54)
        context.concatenate(CGAffineTransform(a: 1, b: 0, c: yaw, d: 1, tx: 0, ty: 0))
        context.translateBy(x: -130, y: -54)
        stroke {
            move(131, 54)
            curve(136, 50, 141, 52.5, 146, 57)
            curve(153, 62.5, 150.5, 67.5, 153, 71)
            curve(155, 74, 159, 77, 162.3, 79.4)
            move(162, 84)
            curve(156, 87, 149, 85.5, 143, 81)
            curve(139, 78.5, 138, 78, 136, 77.5)
        }
        context.saveGState()
        rotate(pose.earAngle, around: CGPoint(x: 130, y: 55))
        stroke {
            move(129, 55.7)
            curve(119.5, 60, 118.5, 70.5, 122, 77.5)
            curve(125.5, 83.5, 132.5, 86, 136, 78)
            curve(140, 72, 136.5, 62, 141, 60)
        }
        context.restoreGState()
        context.fillEllipse(in: CGRect(x: 156.5, y: 78.4, width: 7.5, height: 6.5))
        let eyeX = 142.9 + CGFloat(pose.headTurn) * 0.75 + CGFloat(pose.eyeLook) * 0.9
        let eyeHeight = CGFloat(max(0, min(1, pose.eyeOpen))) * 4.2
        if eyeHeight > 1 {
            context.fillEllipse(in: CGRect(x: eyeX, y: 68.25 - eyeHeight / 2, width: 4.2, height: eyeHeight))
        } else {
            context.saveGState(); context.setLineWidth(1.5)
            stroke { move(eyeX - 0.2, 68.25); curve(eyeX + 1, 68.8, eyeX + 3.2, 68.8, eyeX + 4.4, 68.25) }
            context.restoreGState()
        }
        if !compact, pose.curiosity > 0 {
            context.saveGState(); context.setAlpha(pose.curiosity * 0.8); context.setLineWidth(1.1)
            let lift = CGFloat(pose.curiosity) * 0.8
            stroke { move(eyeX - 1, 63.5 - lift); curve(eyeX + 1, 61.9 - lift, eyeX + 3.5, 62.1 - lift, eyeX + 5, 63.2 - lift) }
            context.restoreGState()
        }
        context.restoreGState()

        if !compact, pose.scentOpacity > 0 {
            for index in 0..<3 {
                context.setAlpha(pose.scentOpacity * (1 - Double(index) * 0.2))
                let point = CGPoint(x: 165 + CGFloat(index) * 4, y: 90 - CGFloat(index) * 2)
                context.fillEllipse(in: CGRect(origin: point, size: CGSize(width: 1.6, height: 1.6)))
            }
        }
    }
}
