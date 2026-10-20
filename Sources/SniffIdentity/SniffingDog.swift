import SwiftUI
import SniffCore

public struct SniffingDog: View {
    public var active: Bool
    public var ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(active: Bool = false, ink: Color = .primary) { self.active = active; self.ink = ink }
    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !active || reduceMotion)) { timeline in
            let phase = active && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate * 4.5 : 0
            Canvas { context, size in
                context.scaleBy(x: size.width / 180, y: size.height / 110)
                let bob = sin(phase) * (active && !reduceMotion ? 2.1 : 0)
                let tail = sin(phase * 1.3) * (active && !reduceMotion ? 5.0 : 0)
                let stroke = StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                func line(_ points: [CGPoint]) {
                    var path = Path(); if let first = points.first { path.move(to: first); for point in points.dropFirst() { path.addLine(to: point) } }
                    context.stroke(path, with: .color(ink), style: stroke)
                }
                // Low, long body; a floppy ear and an oversized nose carry the silhouette.
                var body = Path()
                body.move(to: CGPoint(x: 40, y: 58)); body.addCurve(to: CGPoint(x: 103, y: 51), control1: CGPoint(x: 43, y: 25), control2: CGPoint(x: 88, y: 29))
                body.addCurve(to: CGPoint(x: 112, y: 76), control1: CGPoint(x: 107, y: 61), control2: CGPoint(x: 107, y: 72))
                body.addCurve(to: CGPoint(x: 45, y: 78), control1: CGPoint(x: 88, y: 82), control2: CGPoint(x: 61, y: 82))
                body.addCurve(to: CGPoint(x: 40, y: 58), control1: CGPoint(x: 40, y: 75), control2: CGPoint(x: 38, y: 65))
                context.stroke(body, with: .color(ink), style: stroke)
                line([CGPoint(x: 42, y: 49), CGPoint(x: 27, y: 34 + tail), CGPoint(x: 22, y: 22 + tail)])
                line([CGPoint(x: 49, y: 77), CGPoint(x: 45, y: 95), CGPoint(x: 57, y: 95)])
                line([CGPoint(x: 88, y: 80), CGPoint(x: 91, y: 95), CGPoint(x: 104, y: 95)])
                var head = Path()
                head.move(to: CGPoint(x: 100, y: 49 + bob)); head.addCurve(to: CGPoint(x: 129, y: 45 + bob), control1: CGPoint(x: 107, y: 33 + bob), control2: CGPoint(x: 124, y: 33 + bob))
                head.addLine(to: CGPoint(x: 135, y: 60 + bob)); head.addLine(to: CGPoint(x: 151, y: 68 + bob))
                head.addQuadCurve(to: CGPoint(x: 143, y: 83 + bob), control: CGPoint(x: 156, y: 82 + bob))
                head.addQuadCurve(to: CGPoint(x: 112, y: 75 + bob), control: CGPoint(x: 123, y: 86 + bob))
                context.stroke(head, with: .color(ink), style: stroke)
                var ear = Path()
                ear.move(to: CGPoint(x: 111, y: 45 + bob)); ear.addCurve(to: CGPoint(x: 103, y: 79 + bob), control1: CGPoint(x: 90, y: 40 + bob), control2: CGPoint(x: 86, y: 73 + bob))
                ear.addCurve(to: CGPoint(x: 115, y: 51 + bob), control1: CGPoint(x: 119, y: 85 + bob), control2: CGPoint(x: 119, y: 60 + bob))
                context.fill(ear, with: .color(ink))
                context.fill(Path(ellipseIn: CGRect(x: 143, y: 65 + bob, width: 16, height: 12)), with: .color(ink))
                context.fill(Path(ellipseIn: CGRect(x: 124, y: 52 + bob, width: 4.5, height: 4.5)), with: .color(ink))
                if active {
                    for index in 0..<3 {
                        let opacity = reduceMotion ? 0.3 : (sin(phase - Double(index) * 0.8) + 1) * 0.2 + 0.08
                        context.fill(Path(ellipseIn: CGRect(x: 153 + Double(index) * 8, y: 91 - Double(index) * 3, width: 3, height: 3)), with: .color(ink.opacity(opacity)))
                    }
                }
            }
        }
        .aspectRatio(180.0 / 110, contentMode: .fit)
        .accessibilityLabel(active ? L("Cachorro farejando. Operação em andamento.") : L("Sniff, um cachorro farejando"))
    }
}
