import CoreGraphics

/// Shared artwork for the app, installer, icon and menu bar. Coordinates use a fixed rig.
public enum DogDrawing {
    public static func draw(in context: CGContext, size: CGSize, pose: DogPose = .resting,
                            ink: CGColor, lineWidth: CGFloat = 4.5, compact: Bool = false) {
        let bounds = compact ? CGRect(x: 12, y: 6, width: 156, height: 96) : CGRect(x: 0, y: 0, width: 180, height: 110)
        let scale = min(size.width / bounds.width, size.height / bounds.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setStrokeColor(ink); context.setFillColor(ink)
        context.setLineWidth(lineWidth); context.setLineCap(.round); context.setLineJoin(.round)
        func line(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            context.beginPath(); context.move(to: first)
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        }
        func rotate(_ radians: Double, around pivot: CGPoint) {
            context.translateBy(x: pivot.x, y: pivot.y); context.rotate(by: radians)
            context.translateBy(x: -pivot.x, y: -pivot.y)
        }
        context.saveGState()
        rotate(pose.tailAngle, around: CGPoint(x: 42, y: 50))
        context.beginPath(); context.move(to: CGPoint(x: 42, y: 50))
        context.addCurve(to: CGPoint(x: 22, y: 20), control1: CGPoint(x: 30, y: 41), control2: CGPoint(x: 23, y: 28))
        context.strokePath(); context.restoreGState()

        // Feet and torso stay planted while the head pivots at the neck.
        context.beginPath(); context.move(to: CGPoint(x: 103, y: 51))
        context.addCurve(to: CGPoint(x: 40, y: 58), control1: CGPoint(x: 87, y: 30), control2: CGPoint(x: 43, y: 27))
        context.addCurve(to: CGPoint(x: 45, y: 78), control1: CGPoint(x: 38, y: 65), control2: CGPoint(x: 39, y: 74))
        context.addCurve(to: CGPoint(x: 111, y: 76), control1: CGPoint(x: 61, y: 82), control2: CGPoint(x: 88, y: 82))
        context.strokePath()
        line([CGPoint(x: 49, y: 78), CGPoint(x: 45, y: 95), CGPoint(x: 57, y: 95)])
        line([CGPoint(x: 88, y: 80), CGPoint(x: 91, y: 95), CGPoint(x: 104, y: 95)])

        context.saveGState()
        rotate(pose.headAngle, around: CGPoint(x: 105, y: 57))
        context.beginPath(); context.move(to: CGPoint(x: 101, y: 49))
        context.addCurve(to: CGPoint(x: 129, y: 45), control1: CGPoint(x: 108, y: 34), control2: CGPoint(x: 124, y: 34))
        context.addLine(to: CGPoint(x: 135, y: 60)); context.addLine(to: CGPoint(x: 151, y: 68))
        context.addQuadCurve(to: CGPoint(x: 143, y: 83), control: CGPoint(x: 156, y: 82))
        context.addQuadCurve(to: CGPoint(x: 111, y: 76), control: CGPoint(x: 123, y: 86))
        context.strokePath()
        context.saveGState()
        rotate(pose.earAngle, around: CGPoint(x: 110, y: 46))
        context.beginPath(); context.move(to: CGPoint(x: 111, y: 45))
        context.addCurve(to: CGPoint(x: 103, y: 78), control1: CGPoint(x: 92, y: 41), control2: CGPoint(x: 88, y: 72))
        context.addCurve(to: CGPoint(x: 115, y: 51), control1: CGPoint(x: 118, y: 84), control2: CGPoint(x: 119, y: 60))
        context.strokePath(); context.restoreGState()
        context.fillEllipse(in: CGRect(x: 143, y: 65, width: 15, height: 11))
        context.fillEllipse(in: CGRect(x: 124, y: 51, width: 4.5, height: 4.5))
        context.restoreGState()
        if !compact, pose.scentOpacity > 0 {
            for index in 0..<3 {
                context.setAlpha(pose.scentOpacity * (1 - Double(index) * 0.2))
                let point = CGPoint(x: 158 + CGFloat(index) * 6, y: 91 - CGFloat(index) * 3)
                context.fillEllipse(in: CGRect(origin: point, size: CGSize(width: 2.5, height: 2.5)))
            }
        }
    }
}
