import AppKit
import SniffCore

@MainActor
public enum MenuBarDogImages {
    public static let framesPerSecond = 30.0
    public static let frameCount = Int(DogMotion.duration * framesPerSecond)
    public static func idle() -> NSImage { image(phase: nil) }
    public static func animation() -> [NSImage] {
        (0..<frameCount).map { image(phase: Double($0) / Double(frameCount) * .pi * 2) }
    }
    public static func image(phase: Double?, size: NSSize = NSSize(width: 30, height: 18)) -> NSImage {
        let pose = phase.map { DogMotion.pose(at: $0 / (.pi * 2) * DogMotion.duration) } ?? .resting
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            DogDrawing.draw(in: context, size: rect.size, pose: pose, ink: NSColor.black.cgColor, lineWidth: 6.7, compact: true)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = phase == nil ? L("Sniff, cachorro farejando") : L("Sniff, cachorro farejando e abanando o rabo")
        return image
    }
}
