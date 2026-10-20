import Foundation

/// A four-second cycle with matching position and velocity at the loop boundary.
public struct DogPose: Sendable {
    public var headAngle: Double = 0
    public var earAngle: Double = 0
    public var tailAngle: Double = 0
    public var rumpSway: Double = 0
    public var rumpLift: Double = 0
    public var headTurn: Double = 0
    public var scentOpacity: Double = 0
    public static let resting = DogPose()
}

public enum DogMotion {
    public static let duration = 4.0
    public static func pose(at elapsed: TimeInterval, amount: Double = 1) -> DogPose {
        let phase = elapsed.truncatingRemainder(dividingBy: duration) / duration
        let turn = phase * 2 * Double.pi
        func sniff(_ offset: Double) -> Double {
            let start = offset, end = offset + 0.09
            guard phase >= start, phase <= end else { return 0 }
            return (1 - cos((phase - start) / (end - start) * 2 * .pi)) / 2
        }
        let breath = (1 - cos(turn * 2)) / 2
        let inhaling = sniff(0.13) + sniff(0.25) + sniff(0.55) + sniff(0.67)
        let excitement = 0.82 + 0.18 * cos(turn * 2)
        var pose = DogPose()
        // Lift the low muzzle slightly on each breath, then settle back to the ground.
        pose.headAngle = -(0.018 * breath + 0.065 * inhaling) * amount
        // A loose ear follows the head with a small delay instead of moving in lockstep.
        pose.earAngle = (sin(turn * 4 - 0.5) * 0.025 * breath + 0.025 * inhaling) * amount
        // Tail rotates at its base; the tip never stretches or detaches.
        pose.tailAngle = sin(turn * 8) * 0.30 * excitement * amount
        // The hips rock once for every two wags. Knees flex while paws stay planted.
        pose.rumpSway = sin(turn * 4) * 2.6 * excitement * amount
        pose.rumpLift = sin(turn * 8) * 0.65 * excitement * amount
        // A slower sweep searches for the scent between the quick paired sniffs.
        pose.headTurn = sin(turn * 2) * amount
        pose.scentOpacity = (0.12 + 0.43 * inhaling) * amount
        return pose
    }
}
