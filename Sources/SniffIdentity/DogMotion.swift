import Foundation

/// A four-second cycle with matching position and velocity at the loop boundary.
public struct DogPose: Sendable {
    public var headAngle: Double = 0
    public var earAngle: Double = 0
    public var tailAngle: Double = 0
    public var scentOpacity: Double = 0
    public static let resting = DogPose()
}

public enum DogMotion {
    public static let duration = 4.0
    public static func pose(at elapsed: TimeInterval, amount: Double = 1) -> DogPose {
        let phase = elapsed.truncatingRemainder(dividingBy: duration) / duration
        let turn = phase * 2 * Double.pi
        func sniff(_ offset: Double) -> Double {
            let start = offset, end = offset + 0.13
            guard phase >= start, phase <= end else { return 0 }
            return (1 - cos((phase - start) / (end - start) * 2 * .pi)) / 2
        }
        let breath = (1 - cos(turn)) / 2
        let inhaling = sniff(0.24) + sniff(0.43)
        var pose = DogPose()
        pose.headAngle = (0.025 * breath + 0.045 * inhaling) * amount
        pose.earAngle = -sin(turn * 2 - 0.25) * 0.018 * breath * amount
        // Tail rotates at its base; the tip never stretches or detaches.
        pose.tailAngle = sin(turn * 5) * 0.22 * (0.75 + 0.25 * cos(turn)) * amount
        pose.scentOpacity = (0.12 + 0.24 * inhaling) * amount
        return pose
    }
}
