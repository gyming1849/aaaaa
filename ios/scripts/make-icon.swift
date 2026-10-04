#!/usr/bin/env swift
// Renders NutriLog/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
// from the web favicon (web2 §3.1, aaaaa/web/public/favicon.svg):
//   64×64 box, fill #1f6f50; leaf #f6f5f1 `M20 40c0-11 8-20 20-22-1 12-8 21-20 22z`;
//   vein #1f6f50, 3 px, round cap, (20,40)→(32,28); dot (44,44) r 5 #f6f5f1.
// iOS applies its own rounded mask and rejects icons with alpha, so the background is
// drawn full-bleed and the bitmap has no alpha channel.
//
// Usage (from ios/):  xcrun swift scripts/make-icon.swift [output.png]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let unit = CGFloat(side) / 64 // SVG user unit → pixels

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

let green = rgb(0x1f6f50)
let paper = rgb(0xf6f5f1)

let outPath: String = {
    let args = CommandLine.arguments
    if args.count > 1 { return args[1] }
    let scriptDir = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
    return scriptDir
        .appendingPathComponent("../NutriLog/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
        .standardizedFileURL.path
}()

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
          data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
else {
    FileHandle.standardError.write(Data("make-icon: cannot create bitmap context\n".utf8))
    exit(1)
}

// SVG has y pointing down; flip so that drawing uses SVG coordinates in 0…64.
ctx.translateBy(x: 0, y: CGFloat(side))
ctx.scaleBy(x: unit, y: -unit)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// Background (full bleed; the system applies the rounded-rect mask).
ctx.setFillColor(green)
ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))

// Leaf: M20 40 c0-11 8-20 20-22 -1 12-8 21-20 22 z (relative cubic curves).
let leaf = CGMutablePath()
leaf.move(to: CGPoint(x: 20, y: 40))
leaf.addCurve(to: CGPoint(x: 40, y: 18), control1: CGPoint(x: 20, y: 29), control2: CGPoint(x: 28, y: 20))
leaf.addCurve(to: CGPoint(x: 20, y: 40), control1: CGPoint(x: 39, y: 30), control2: CGPoint(x: 32, y: 39))
leaf.closeSubpath()
ctx.addPath(leaf)
ctx.setFillColor(paper)
ctx.fillPath()

// Vein.
ctx.setStrokeColor(green)
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 20, y: 40))
ctx.addLine(to: CGPoint(x: 32, y: 28))
ctx.strokePath()

// Dot.
ctx.setFillColor(paper)
ctx.fillEllipse(in: CGRect(x: 44 - 5, y: 44 - 5, width: 10, height: 10))

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("make-icon: cannot render image\n".utf8))
    exit(1)
}
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("make-icon: cannot open \(outPath)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("make-icon: cannot write \(outPath)\n".utf8))
    exit(1)
}
print("make-icon: wrote \(outPath) (\(side)×\(side), no alpha)")
