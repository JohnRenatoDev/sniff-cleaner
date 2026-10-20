import Foundation

public struct DogPose: Sendable {
    public var headAngle: Double = 0
    public var earAngle: Double = 0
    public var tailAngle: Double = 0
    public var tailBend: Double = 0
    public var rumpSway: Double = 0
    public var rumpLift: Double = 0
    public var headTurn: Double = 0
    public var eyeLook: Double = 0
    public var eyeOpen: Double = 1
    public var curiosity: Double = 0
    public var scentOpacity: Double = 0
    public static let resting = DogPose()
}

/// Authored intentions and quiet beats, rather than one oscillator driving every joint.
public enum DogMotion {
    public static let duration = 12.0
    private struct Key: Sendable { let time: Double; let value: Double }
    private struct Sniff: Sendable { let start: Double; let length: Double; let strength: Double }
    private struct Wag: Sendable {
        let start: Double; let length: Double; let attack: Double; let release: Double
        let frequency: Double; let acceleration: Double; let strength: Double; let hips: Double
        func phase(_ time: Double) -> Double { 2 * .pi * (frequency * time + acceleration * time * time / 2) }
        func envelope(_ time: Double) -> Double {
            DogMotion.pulse(time, start: 0, attack: attack, hold: length - attack - release, release: release)
        }
        func wave(_ time: Double) -> Double {
            let angle = phase(time)
            return sin(angle) + 0.08 * sin(2 * angle + 0.6)
        }
    }
    private static let head: [Key] = [
        .init(time: 0, value: 0), .init(time: 0.5, value: -0.014),
        .init(time: 1.9, value: -0.025), .init(time: 2.2, value: -0.025),
        .init(time: 2.55, value: -0.145), .init(time: 2.9, value: -0.132),
        .init(time: 3.5, value: -0.132), .init(time: 3.92, value: -0.018),
        .init(time: 5.0, value: -0.022), .init(time: 6.35, value: -0.012),
        .init(time: 6.72, value: -0.065), .init(time: 7.03, value: -0.025),
        .init(time: 8.0, value: -0.02), .init(time: 8.65, value: -0.035),
        .init(time: 9.4, value: -0.008), .init(time: 10.5, value: -0.008),
        .init(time: 11.0, value: 0), .init(time: 12, value: 0)
    ]
    private static let search: [Key] = [
        .init(time: 0, value: 0), .init(time: 0.65, value: -0.38),
        .init(time: 0.9, value: -0.38), .init(time: 1.6, value: 0.63),
        .init(time: 1.95, value: 0.63), .init(time: 2.4, value: -0.48),
        .init(time: 3.45, value: -0.48), .init(time: 3.95, value: -0.08),
        .init(time: 5.12, value: 0.65), .init(time: 5.45, value: 0.65),
        .init(time: 6.15, value: -0.72), .init(time: 6.6, value: -0.72),
        .init(time: 7.2, value: 0.4), .init(time: 7.75, value: 0.4),
        .init(time: 8.6, value: -0.25), .init(time: 9.6, value: 0.1),
        .init(time: 10.45, value: 0.1), .init(time: 11.0, value: 0), .init(time: 12, value: 0)
    ]
    private static let gaze: [Key] = [
        .init(time: 0, value: 0), .init(time: 2.35, value: 0),
        .init(time: 2.55, value: -0.9), .init(time: 2.78, value: -0.9),
        .init(time: 3.0, value: 0.45), .init(time: 3.45, value: 0.45),
        .init(time: 3.85, value: 0), .init(time: 6.65, value: 0),
        .init(time: 6.85, value: 0.65), .init(time: 7.2, value: 0), .init(time: 12, value: 0)
    ]
    private static let sniffs: [Sniff] = [
        .init(start: 0.68, length: 0.21, strength: 0.032),
        .init(start: 1.12, length: 0.25, strength: 0.05),
        .init(start: 1.53, length: 0.17, strength: 0.035),
        .init(start: 4.18, length: 0.17, strength: 0.042),
        .init(start: 4.5, length: 0.22, strength: 0.035),
        .init(start: 5.85, length: 0.28, strength: 0.045),
        .init(start: 6.22, length: 0.19, strength: 0.03),
        .init(start: 7.1, length: 0.16, strength: 0.05),
        .init(start: 7.38, length: 0.23, strength: 0.045),
        .init(start: 8.48, length: 0.25, strength: 0.023)
    ]
    private static let wags: [Wag] = [
        .init(start: 0.35, length: 1.55, attack: 0.24, release: 0.4, frequency: 1.3, acceleration: 0.35, strength: 0.12, hips: 0.6),
        .init(start: 3.55, length: 2.05, attack: 0.18, release: 0.55, frequency: 2.0, acceleration: 0.42, strength: 0.31, hips: 2.35),
        .init(start: 7.1, length: 1.82, attack: 0.16, release: 0.5, frequency: 2.9, acceleration: -0.65, strength: 0.28, hips: 1.9),
        .init(start: 10.35, length: 0.65, attack: 0.12, release: 0.28, frequency: 1.4, acceleration: -0.4, strength: 0.08, hips: 0.25)
    ]

    public static func pose(at elapsed: TimeInterval, amount: Double = 1) -> DogPose {
        let amount = min(1, max(0, amount))
        guard amount > 0 else { return .resting }
        let time = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        let inhale = sniff(at: time)
        let angle = headAngle(at: time)
        let turn = track(search, at: time)
        var pose = DogPose()
        pose.headAngle = angle * amount
        pose.headTurn = turn * amount
        // The loose ear trails changes of direction and settles after the head stops.
        pose.earAngle = ((headAngle(at: time - 0.11) - angle) * 0.9
                        + (track(search, at: time - 0.14) - turn) * 0.025) * amount
        for wag in wags {
            let local = time - wag.start
            let envelope = wag.envelope(local)
            pose.tailAngle += wag.wave(local) * envelope * wag.strength * amount
            // A flexible tip and hips carry on briefly after the tail changes direction.
            pose.tailBend += (sin(wag.phase(local - 0.065)) - sin(wag.phase(local)))
                            * wag.envelope(local - 0.035) * 2.2 * amount
            let following = local - 0.1
            let hipPhase = wag.phase(following) / 2 - 0.18
            let hipEnvelope = wag.envelope(following)
            pose.rumpSway += (sin(hipPhase) + 0.1 * sin(hipPhase * 2)) * hipEnvelope * wag.hips * amount
            pose.rumpLift -= pow(sin(hipPhase), 2) * hipEnvelope * 0.45 * amount
        }
        pose.eyeLook = track(gaze, at: time) * amount
        pose.curiosity = pulse(time, start: 2.25, attack: 0.3, hold: 0.85, release: 0.4) * amount
        let blink = [2.9, 3.25, 6.95, 10.2].map {
            pulse(time, start: $0, attack: 0.035, hold: 0.025, release: 0.085)
        }.max() ?? 0
        pose.eyeOpen = 1 - blink * amount
        pose.scentOpacity = min(1, inhale / 0.05) * 0.6 * amount
        return pose
    }

    private static func headAngle(at time: Double) -> Double { track(head, at: time) - sniff(at: time) }
    private static func sniff(at time: Double) -> Double {
        sniffs.reduce(0) { sum, sniff in
            sum + sniff.strength * pulse(time, start: sniff.start, attack: sniff.length * 0.28,
                                         hold: 0, release: sniff.length * 0.72)
        }
    }
    private static func track(_ keys: [Key], at time: Double) -> Double {
        guard time > keys[0].time else { return keys[0].value }
        for index in 1..<keys.count where time < keys[index].time {
            let before = keys[index - 1], after = keys[index]
            return before.value + (after.value - before.value) * ease((time - before.time) / (after.time - before.time))
        }
        return keys.last!.value
    }
    private static func pulse(_ time: Double, start: Double, attack: Double, hold: Double, release: Double) -> Double {
        let local = time - start
        guard local > 0, local < attack + hold + release else { return 0 }
        if local < attack { return ease(local / attack) }
        if local < attack + hold { return 1 }
        return 1 - ease((local - attack - hold) / release)
    }
    // Shared ease-in-out: cubic-bezier(0.77, 0, 0.175, 1).
    private static func ease(_ progress: Double) -> Double {
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let t = (low + high) / 2, inverse = 1 - t
            let x = 3 * inverse * inverse * t * 0.77 + 3 * inverse * t * t * 0.175 + t * t * t
            if x < progress { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }
}
