import SwiftUI
import Combine
import SniffCore

@MainActor
private final class DogClock: ObservableObject {
    @Published var start = Date()
}

public struct SniffingDog: View {
    public var active: Bool
    public var ink: Color
    @StateObject private var clock = DogClock()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(active: Bool = false, ink: Color = .primary) { self.active = active; self.ink = ink }
    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active || reduceMotion)) { timeline in
            DogCanvas(elapsed: max(0, timeline.date.timeIntervalSince(clock.start)), amount: active && !reduceMotion ? 1 : 0, ink: ink)
                .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.2), value: active)
        }
        .aspectRatio(180.0 / 110, contentMode: .fit)
        .onChange(of: active) { _, running in if running { clock.start = .now } }
        .accessibilityLabel(active ? L("Cachorro farejando. Operação em andamento.") : L("Sniff, um cachorro farejando"))
    }
}

private struct DogCanvas: View, @MainActor Animatable {
    var elapsed: TimeInterval
    var amount: Double
    var ink: Color
    var animatableData: Double { get { amount } set { amount = newValue } }
    @Environment(\.self) private var environment
    var body: some View {
        Canvas { context, size in
            let color = ink.resolve(in: environment)
            context.withCGContext { cg in
                let ink = CGColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: CGFloat(color.opacity))
                DogDrawing.draw(in: cg, size: size, pose: DogMotion.pose(at: elapsed, amount: amount), ink: ink)
            }
        }
    }
}
