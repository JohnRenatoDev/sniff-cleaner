import Foundation
import Testing
import SniffIdentity

@Test func animationLoopMatchesPositionAndVelocity() {
    let step = 0.0001
    let before = DogMotion.pose(at: DogMotion.duration - step)
    let start = DogMotion.pose(at: 0)
    let end = DogMotion.pose(at: DogMotion.duration)
    let after = DogMotion.pose(at: step)
    #expect(abs(start.headAngle - end.headAngle) < 0.000001)
    #expect(abs(start.tailAngle - end.tailAngle) < 0.000001)
    #expect(abs(start.earAngle - end.earAngle) < 0.000001)
    let enteringVelocity = (start.tailAngle - before.tailAngle) / step
    let leavingVelocity = (after.tailAngle - start.tailAngle) / step
    #expect(abs(enteringVelocity - leavingVelocity) < 0.001)
}

@Test func motionStaysSmallAndReducedMotionRemainsStill() {
    for frame in 0..<240 {
        let time = Double(frame) / 60
        let pose = DogMotion.pose(at: time)
        #expect(abs(pose.headAngle) <= 0.071)
        #expect(abs(pose.tailAngle) <= 0.221)
        #expect(abs(pose.earAngle) <= 0.019)
        let still = DogMotion.pose(at: time, amount: 0)
        #expect(still.headAngle == 0 && still.tailAngle == 0 && still.earAngle == 0 && still.scentOpacity == 0)
    }
}
