// Renders Shotcue's 1024x1024 app icon with CoreGraphics and writes it as a PNG.
// No .xcassets, no actool: `swift scripts/render-icon.swift out.png` runs in interpreter mode.
// Glyph: rounded-rect plate with a blue→indigo gradient, a camera viewfinder (four corner brackets)
// and a cue mark (ring + amber dot) in the middle.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <output.png>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

guard
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    FileHandle.standardError.write(Data("cannot create bitmap context\n".utf8))
    exit(1)
}

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let full = CGRect(x: 0, y: 0, width: Double(side), height: Double(side))

// 1. Rounded-rect plate. macOS icons leave a margin inside the 1024 pt canvas; 100 pt reads well
//    at 16 pt and still fills the Dock tile.
let plate = full.insetBy(dx: 100, dy: 100)
let platePath = CGPath(roundedRect: plate, cornerWidth: 190, cornerHeight: 190, transform: nil)
context.saveGState()
context.addPath(platePath)
context.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [color(0.29, 0.44, 0.96), color(0.36, 0.22, 0.80)] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: plate.midX, y: plate.maxY),
    end: CGPoint(x: plate.midX, y: plate.minY),
    options: [])
context.restoreGState()

// 2. Camera viewfinder: four corner brackets.
let viewfinder = plate.insetBy(dx: 150, dy: 150)
let armLength = 150.0
context.setStrokeColor(color(1, 1, 1, 0.96))
context.setLineWidth(46)
context.setLineCap(.round)
context.setLineJoin(.round)

func bracket(_ corner: CGPoint, dx: Double, dy: Double) {
    context.beginPath()
    context.move(to: CGPoint(x: corner.x + dx * armLength, y: corner.y))
    context.addLine(to: corner)
    context.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * armLength))
    context.strokePath()
}

bracket(CGPoint(x: viewfinder.minX, y: viewfinder.maxY), dx: 1, dy: -1)
bracket(CGPoint(x: viewfinder.maxX, y: viewfinder.maxY), dx: -1, dy: -1)
bracket(CGPoint(x: viewfinder.minX, y: viewfinder.minY), dx: 1, dy: 1)
bracket(CGPoint(x: viewfinder.maxX, y: viewfinder.minY), dx: -1, dy: 1)

// 3. Cue mark: ring plus amber dot.
let center = CGPoint(x: viewfinder.midX, y: viewfinder.midY)
context.setStrokeColor(color(1, 1, 1, 0.55))
context.setLineWidth(26)
context.beginPath()
context.addArc(center: center, radius: 128, startAngle: 0, endAngle: .pi * 2, clockwise: false)
context.strokePath()

context.setFillColor(color(1, 0.86, 0.32, 1))
context.beginPath()
context.addArc(center: center, radius: 62, startAngle: 0, endAngle: .pi * 2, clockwise: false)
context.fillPath()

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("cannot snapshot context\n".utf8))
    exit(1)
}
guard
    let destination = CGImageDestinationCreateWithURL(
        output as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("cannot create PNG destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("cannot write PNG\n".utf8))
    exit(1)
}
print("wrote \(output.path) (\(side)x\(side))")
