import AppKit
import SniffCore

/// A heavier, cropped silhouette that stays readable at the menu bar's 18 pt height.
@MainActor
public enum MenuBarDogImages {
    public static let frameCount = 24
    public static let framesPerSecond = 16.0

    public static func idle() -> NSImage { image(phase: nil) }
    public static func animation() -> [NSImage] {
        (0..<frameCount).map { image(phase: Double($0) / Double(frameCount) * .pi * 2) }
    }

    public static func image(phase: Double?, size: NSSize = NSSize(width: 30, height: 18)) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = min(rect.width / 158, rect.height / 94)
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: (rect.width - 158 * scale) / 2, y: (rect.height - 94 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -10, y: -5)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(6.7)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            func stroke(_ points: [CGPoint]) {
                guard let first = points.first else { return }
                context.beginPath(); context.move(to: first)
                for point in points.dropFirst() { context.addLine(to: point) }
                context.strokePath()
            }

            // Body and feet remain still. Sniffing and tail motion have their own rhythms.
            let body = CGMutablePath()
            body.move(to: CGPoint(x: 40, y: 57))
            body.addCurve(to: CGPoint(x: 104, y: 50), control1: CGPoint(x: 42, y: 28), control2: CGPoint(x: 86, y: 29))
            body.addCurve(to: CGPoint(x: 111, y: 76), control1: CGPoint(x: 108, y: 59), control2: CGPoint(x: 107, y: 70))
            body.addCurve(to: CGPoint(x: 45, y: 77), control1: CGPoint(x: 87, y: 81), control2: CGPoint(x: 60, y: 80))
            body.addCurve(to: CGPoint(x: 40, y: 57), control1: CGPoint(x: 39, y: 74), control2: CGPoint(x: 38, y: 64))
            context.addPath(body); context.strokePath()
            stroke([CGPoint(x: 49, y: 77), CGPoint(x: 45, y: 94), CGPoint(x: 57, y: 94)])
            stroke([CGPoint(x: 88, y: 79), CGPoint(x: 91, y: 94), CGPoint(x: 103, y: 94)])

            let angle = phase.map { sin($0 * 2) * 0.50 } ?? 0
            func tailPoint(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: 42 + x * cos(angle) - y * sin(angle), y: 49 + x * sin(angle) + y * cos(angle))
            }
            stroke([CGPoint(x: 42, y: 49), tailPoint(-16, -14), tailPoint(-22, -31)])

            context.saveGState()
            let sniff = phase.map { sin($0 * 3) * 0.065 } ?? 0
            context.translateBy(x: 105, y: 56)
            context.rotate(by: sniff)
            context.translateBy(x: -105, y: -56 + (phase.map { sin($0 * 3) * 2 } ?? 0))
            let head = CGMutablePath()
            head.move(to: CGPoint(x: 101, y: 49))
            head.addCurve(to: CGPoint(x: 129, y: 45), control1: CGPoint(x: 108, y: 34), control2: CGPoint(x: 124, y: 34))
            head.addLine(to: CGPoint(x: 135, y: 61)); head.addLine(to: CGPoint(x: 151, y: 69))
            head.addQuadCurve(to: CGPoint(x: 143, y: 83), control: CGPoint(x: 156, y: 82))
            head.addQuadCurve(to: CGPoint(x: 111, y: 75), control: CGPoint(x: 123, y: 86))
            context.addPath(head); context.strokePath()
            let ear = CGMutablePath()
            ear.move(to: CGPoint(x: 111, y: 45))
            ear.addCurve(to: CGPoint(x: 103, y: 79), control1: CGPoint(x: 91, y: 40), control2: CGPoint(x: 87, y: 72))
            ear.addCurve(to: CGPoint(x: 115, y: 51), control1: CGPoint(x: 119, y: 84), control2: CGPoint(x: 119, y: 59))
            context.addPath(ear); context.fillPath()
            context.fillEllipse(in: CGRect(x: 143, y: 65, width: 16, height: 12))
            context.fillEllipse(in: CGRect(x: 123, y: 51, width: 5.5, height: 5.5))
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = phase == nil ? L("Sniff, cachorro farejando") : L("Sniff, cachorro farejando e abanando o rabo")
        return image
    }
}
