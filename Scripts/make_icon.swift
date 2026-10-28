#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Renders Assets/AppIcon-1024.png.
//
// Geometry follows the mark the user picked in the About panel (a rounded, filled
// paper plane in the app accent orange, nose to the upper right, vertical tail fin),
// on the macOS Big Sur icon grid: 824pt squircle centered on a 1024pt canvas.

let canvas: CGFloat = 1024
let tileHalf: CGFloat = 412
let center = CGPoint(x: canvas / 2, y: canvas / 2)

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func squircle(half: CGFloat, exponent: CGFloat = 5, samples: Int = 720) -> CGPath {
    let path = CGMutablePath()
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = center.x + half * copysign(pow(abs(c), 2 / exponent), c)
        let y = center.y + half * copysign(pow(abs(s), 2 / exponent), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Tile-relative point (0...1, y up) to canvas coordinates.
func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
    CGPoint(x: center.x - tileHalf + fx * tileHalf * 2,
            y: center.y - tileHalf + fy * tileHalf * 2)
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas),
    pixelsHigh: Int(canvas),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
let space = CGColorSpaceCreateDeviceRGB()

let tile = squircle(half: tileHalf)

// Baked drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x1A0C05, alpha: 0.26))
ctx.addPath(tile)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()

// Paper-white tile with a barely-there warm falloff so it is not flat.
let base = CGGradient(colorsSpace: space, colors: [
    color(0xFFFFFF),
    color(0xFFFDFB),
    color(0xFFF6F1)
] as CFArray, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(base,
                       start: CGPoint(x: 512, y: 940),
                       end: CGPoint(x: 512, y: 110),
                       options: [])

let glow = CGGradient(colorsSpace: space, colors: [
    color(0xFF6C37, alpha: 0.07),
    color(0xFF6C37, alpha: 0.0)
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: 560, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 560, y: 560), endRadius: 420,
                       options: [])

ctx.addPath(tile)
ctx.setLineWidth(4)
ctx.setStrokeColor(color(0xB08976, alpha: 0.26))
ctx.strokePath()

ctx.restoreGState()

// Paper plane, measured against the About-panel mark: nose upper right, long thin
// upper wing to the left, vertical tail fin below the fold. The points are recentered
// on their bounding box so the mark sits in the middle of the tile.
let raw: [(CGFloat, CGFloat)] = [
    (0.90, 0.70),    // nose
    (0.245, 0.475),  // upper wing tip
    (0.565, 0.405),  // fold
    (0.655, 0.155)   // tail tip
]
let rawMinX = raw.map { $0.0 }.min()!
let rawMaxX = raw.map { $0.0 }.max()!
let rawMinY = raw.map { $0.1 }.min()!
let rawMaxY = raw.map { $0.1 }.max()!
// Slight upward bias keeps the drop shadow from making the mark read low.
let shift = (0.5 - (rawMinX + rawMaxX) / 2, 0.5 - (rawMinY + rawMaxY) / 2 + 0.006)
func mark(_ p: (CGFloat, CGFloat)) -> CGPoint { point(p.0 + shift.0, p.1 + shift.1) }
let nose = mark(raw[0])
let wingTip = mark(raw[1])
let fold = mark(raw[2])
let tailTip = mark(raw[3])
let orange = color(0xFF6A2E)

let upper = CGMutablePath()
upper.move(to: nose)
upper.addLine(to: wingTip)
upper.addLine(to: fold)
upper.closeSubpath()

let tail = CGMutablePath()
tail.move(to: nose)
tail.addLine(to: fold)
tail.addLine(to: tailTip)
tail.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: color(0xB2380F, alpha: 0.22))
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.setLineWidth(26)
ctx.setStrokeColor(orange)
ctx.setFillColor(orange)
ctx.addPath(upper)
ctx.drawPath(using: .fillStroke)
ctx.addPath(tail)
ctx.drawPath(using: .fillStroke)
ctx.restoreGState()

// Crease: white seam from nose to fold, same as the reference mark.
ctx.setLineCap(.round)
ctx.setLineWidth(10)
ctx.setStrokeColor(color(0xFFFFFF))
ctx.move(to: nose)
ctx.addLine(to: fold)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

let master = assets.appendingPathComponent("AppIcon-1024.png")
try rep.representation(using: .png, properties: [:])!.write(to: master)
print("Wrote \(master.path)")
