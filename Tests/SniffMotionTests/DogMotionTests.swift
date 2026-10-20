import Foundation
import CoreGraphics
import Testing
import SniffIdentity

@Test func animationLoopMatchesPositionAndVelocity() {
    let step = 0.0001
    let before = DogMotion.pose(at: DogMotion.duration - step)
    let start = DogMotion.pose(at: 0)
    let end = DogMotion.pose(at: DogMotion.duration)
    let after = DogMotion.pose(at: step)
    let channels: [KeyPath<DogPose, Double>] = [\.headAngle, \.tailAngle, \.tailBend, \.earAngle, \.rumpSway, \.rumpLift, \.headTurn, \.eyeLook, \.eyeOpen, \.curiosity, \.scentOpacity]
    for channel in channels {
        #expect(abs(start[keyPath: channel] - end[keyPath: channel]) < 0.000001)
        let enteringVelocity = (start[keyPath: channel] - before[keyPath: channel]) / step
        let leavingVelocity = (after[keyPath: channel] - start[keyPath: channel]) / step
        #expect(abs(enteringVelocity - leavingVelocity) < 0.001)
    }
}

@Test func motionStaysSmallAndReducedMotionRemainsStill() {
    for frame in 0..<Int(DogMotion.duration * 60) {
        let time = Double(frame) / 60
        let pose = DogMotion.pose(at: time)
        #expect(pose.headAngle >= -0.16 && pose.headAngle <= 0)
        #expect(abs(pose.tailAngle) <= 0.36 && abs(pose.tailBend) <= 3.5)
        #expect(abs(pose.earAngle) <= 0.15)
        #expect(abs(pose.rumpSway) <= 2.8 && abs(pose.rumpLift) <= 0.5)
        #expect(abs(pose.headTurn) <= 1)
        let still = DogMotion.pose(at: time, amount: 0)
        #expect(still.headAngle == 0 && still.tailAngle == 0 && still.earAngle == 0 && still.scentOpacity == 0)
        #expect(still.rumpSway == 0 && still.rumpLift == 0 && still.headTurn == 0)
        #expect(still.tailBend == 0 && still.eyeLook == 0 && still.eyeOpen == 1 && still.curiosity == 0)
    }
}

@Test func artworkFitsEveryFrameWithEvenInkAndPlantedPaws() {
    for compact in [false, true] {
        let width = compact ? 60 : 180, height = compact ? 36 : 110
        var plantedPaws: [UInt8]?
        for frame in 0..<Int(DogMotion.duration * 30) {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                DogDrawing.draw(in: context, size: CGSize(width: width, height: height),
                                pose: DogMotion.pose(at: Double(frame) / 30),
                                ink: CGColor(gray: 0, alpha: 0.5), lineWidth: compact ? 4.7 : 2.65, compact: compact)
            }
            let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
            #expect(alpha.max()! <= 128)
            #expect(alpha.contains { $0 > 100 })
            if !compact {
                var pawPixels: [UInt8] = []
                for (xs, ys) in [(22..<33, 80..<87), (43..<54, 80..<85), (103..<116, 80..<86)] {
                    for y in ys { for x in xs { pawPixels.append(alpha[(height - 1 - y) * width + x]) } }
                }
                if let plantedPaws { #expect(pawPixels == plantedPaws) }
                else { plantedPaws = pawPixels }
            }
            for x in 0..<width {
                #expect(alpha[x] == 0 && alpha[(height - 1) * width + x] == 0)
            }
            for y in 0..<height {
                #expect(alpha[y * width] == 0 && alpha[y * width + width - 1] == 0)
            }
        }
    }
}

@Test func actingHasQuietBeatsAndBriefExpressions() {
    let poses = (0..<Int(DogMotion.duration * 60)).map { DogMotion.pose(at: Double($0) / 60) }
    let quiet = poses.filter { abs($0.tailAngle) < 0.005 && abs($0.rumpSway) < 0.05 }
    let lively = poses.filter { abs($0.tailAngle) > 0.1 && abs($0.rumpSway) > 0.2 }
    #expect(quiet.count > poses.count / 4)
    #expect(lively.count > 50)
    #expect(poses.filter { $0.eyeOpen < 0.15 }.count >= 4)
    #expect(poses.filter { $0.curiosity > 0.8 && abs($0.tailAngle) < 0.005 }.count > 20)
}
