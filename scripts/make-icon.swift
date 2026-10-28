import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

// macOS icon grid: 824 pt body centered in 1024, corner radius about 185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(color(0.1, 0.1, 0.25)); ctx.fillPath()
ctx.restoreGState()

// Night sky gradient.
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let sky = CGGradient(colorsSpace: cs, colors: [color(0.33, 0.27, 0.78), color(0.09, 0.08, 0.30)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// A few stars.
for (x, y, r) in [(250.0, 780.0, 7.0), (330.0, 690.0, 4.5), (420.0, 820.0, 5.0), (200.0, 600.0, 4.0), (560.0, 760.0, 3.5)] {
    ctx.setFillColor(color(1, 1, 1, 0.85)); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// Crescent moon: a disc with an offset disc cut out.
ctx.saveGState()
let moon = CGRect(x: 560, y: 560, width: 250, height: 250)
ctx.setShadow(offset: .zero, blur: 40, color: color(1, 0.9, 0.55, 0.55))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(1.0, 0.86, 0.45)); ctx.fillEllipse(in: moon)
ctx.setBlendMode(.clear)
ctx.fillEllipse(in: moon.offsetBy(dx: -78, dy: 52))
ctx.endTransparencyLayer()
ctx.restoreGState()

// Battery outline with a low, red charge level.
let battery = CGRect(x: 230, y: 250, width: 500, height: 240)
let shell = CGPath(roundedRect: battery, cornerWidth: 62, cornerHeight: 62, transform: nil)
ctx.addPath(shell); ctx.setStrokeColor(color(1, 1, 1)); ctx.setLineWidth(30); ctx.strokePath()
let cap = CGRect(x: battery.maxX + 26, y: battery.midY - 50, width: 36, height: 100)
let capPath = CGPath(roundedRect: cap, cornerWidth: 18, cornerHeight: 18, transform: nil)
ctx.addPath(capPath); ctx.setFillColor(color(1, 1, 1)); ctx.fillPath()
let level = CGRect(x: battery.minX + 38, y: battery.minY + 38, width: 92, height: battery.height - 76)
ctx.addPath(CGPath(roundedRect: level, cornerWidth: 28, cornerHeight: 28, transform: nil))
ctx.setFillColor(color(1.0, 0.33, 0.30)); ctx.fillPath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
