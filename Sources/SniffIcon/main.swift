import AppKit
import SwiftUI
import SniffIdentity
import ImageIO
import UniformTypeIdentifiers

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--menu-bar-preview" {
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let frames = MenuBarDogImages.animation()
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { fatalError("Não foi possível criar o preview.") }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for index in frames.indices {
        let dog = MenuBarDogImages.image(phase: Double(index) / Double(frames.count) * .pi * 2, size: NSSize(width: 300, height: 180))
        let preview = NSImage(size: NSSize(width: 340, height: 220), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            dog.draw(in: NSRect(x: 20, y: 20, width: 300, height: 180))
            return true
        }
        if let image = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / MenuBarDogImages.framesPerSecond]] as CFDictionary)
        }
    }
    guard CGImageDestinationFinalize(destination) else { fatalError("Falha ao salvar o preview.") }
    print(output.path)
    exit(0)
}

let destination = CommandLine.arguments.dropFirst().first ?? "work/SniffIcon.png"
let content = ZStack {
    RoundedRectangle(cornerRadius: 220, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
    RoundedRectangle(cornerRadius: 220, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 10)
    SniffingDog(ink: .primary).padding(.horizontal, 80).offset(y: -10)
}.frame(width: 1024, height: 1024).environment(\.colorScheme, .light)
let renderer = ImageRenderer(content: content)
renderer.scale = 1
guard let cgImage = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { fatalError("Não foi possível renderizar o ícone.") }
try png.write(to: URL(fileURLWithPath: destination))
print(destination)
