#!/usr/bin/env swift
//
// RenderAppIcon.swift
//
// Renders the Agents macOS app icon PNGs and the AppIcon.appiconset
// Contents.json that references them.
//
// Usage:
//   swift design/icon/RenderAppIcon.swift [--appearance light|dark] [--out DIR]
//
// No SwiftPM package, no third-party dependencies — plain top-level script
// using AppKit / CoreGraphics / ImageIO / UniformTypeIdentifiers.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Failure helper

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("Error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - CLI

enum Appearance: String {
    case light
    case dark
}

struct Options {
    var appearance: Appearance = .light
    var outDir: URL
}

func parseOptions(arguments: [String], defaultOutDir: URL) -> Options {
    var appearance: Appearance = .light
    var outDir = defaultOutDir

    var i = 0
    while i < arguments.count {
        switch arguments[i] {
        case "--appearance":
            i += 1
            guard i < arguments.count, let value = Appearance(rawValue: arguments[i]) else {
                fail("--appearance requires 'light' or 'dark'")
            }
            appearance = value
        case "--out":
            i += 1
            guard i < arguments.count else {
                fail("--out requires a directory path")
            }
            outDir = URL(fileURLWithPath: arguments[i])
        default:
            fail("unknown argument: \(arguments[i])")
        }
        i += 1
    }

    return Options(appearance: appearance, outDir: outDir)
}

// MARK: - Color helpers

typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)

func hexRGB(_ hex: String) -> RGB {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else {
        fail("bad hex color: \(hex)")
    }
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return (r, g, b)
}

func cgColor(_ rgb: RGB, alpha: CGFloat, space: CGColorSpace) -> CGColor {
    guard let color = CGColor(colorSpace: space, components: [rgb.r, rgb.g, rgb.b, alpha]) else {
        fail("could not build CGColor from \(rgb) alpha \(alpha)")
    }
    return color
}

// MARK: - Squircle path

// A superellipse sampled as a closed polyline, in the 1024x1024, y-down
// canvas coordinate space described in the spec.
func squirclePath() -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0..<steps {
        let t = (Double(i) / Double(steps)) * 2 * Double.pi
        let c = cos(t)
        let s = sin(t)
        let x = copysign(pow(abs(c), 2.0 / 4.6), c)
        let y = copysign(pow(abs(s), 2.0 / 4.6), s)
        let px = CGFloat((x + 1) / 2 * 1024)
        let py = CGFloat((y + 1) / 2 * 1024)
        if i == 0 {
            path.move(to: CGPoint(x: px, y: py))
        } else {
            path.addLine(to: CGPoint(x: px, y: py))
        }
    }
    path.closeSubpath()
    return path
}

// MARK: - Elliptical radial highlight

// CoreGraphics radial gradients are circular, so an elliptical one is drawn
// by scaling the coordinate space non-uniformly around the ellipse's center
// and then drawing a plain circular gradient of radius 1 in that distorted
// space.
func drawEllipticalHighlight(
    ctx: CGContext,
    colorSpace: CGColorSpace,
    center: CGPoint,
    rx: CGFloat,
    ry: CGFloat,
    centerAlpha: CGFloat,
    fadeLocation: CGFloat
) {
    let white: RGB = (1, 1, 1)
    let colors: [CGColor] = [
        cgColor(white, alpha: centerAlpha, space: colorSpace),
        cgColor(white, alpha: 0.0, space: colorSpace),
    ]
    guard let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: colors as CFArray,
        locations: [0.0, fadeLocation]
    ) else {
        fail("could not create highlight gradient")
    }

    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: rx, y: ry)
    ctx.drawRadialGradient(
        gradient,
        startCenter: .zero,
        startRadius: 0,
        endCenter: .zero,
        endRadius: 1,
        options: []
    )
    ctx.restoreGState()
}

// MARK: - Full icon drawing

func drawIcon(ctx: CGContext, colorSpace: CGColorSpace, appearance: Appearance) {
    // 1. Squircle clip — nothing may paint outside it.
    ctx.addPath(squirclePath())
    ctx.clip()

    // 2. Ground: linear gradient.
    let groundColors: [CGColor]
    switch appearance {
    case .light:
        groundColors = [
            cgColor(hexRGB("#008EA6"), alpha: 1.0, space: colorSpace),
            cgColor(hexRGB("#00606F"), alpha: 1.0, space: colorSpace),
        ]
    case .dark:
        groundColors = [
            cgColor(hexRGB("#0A2B33"), alpha: 1.0, space: colorSpace),
            cgColor(hexRGB("#04161B"), alpha: 1.0, space: colorSpace),
        ]
    }
    guard let groundGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: groundColors as CFArray,
        locations: [0.0, 1.0]
    ) else {
        fail("could not create ground gradient")
    }
    ctx.drawLinearGradient(
        groundGradient,
        start: CGPoint(x: 262.3, y: -105.9),
        end: CGPoint(x: 761.7, y: 1129.9),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // 3. Specular highlights.
    drawEllipticalHighlight(
        ctx: ctx, colorSpace: colorSpace,
        center: CGPoint(x: 266.2, y: 41.0), rx: 1280.0, ry: 901.1,
        centerAlpha: 0.26, fadeLocation: 0.56
    )
    drawEllipticalHighlight(
        ctx: ctx, colorSpace: colorSpace,
        center: CGPoint(x: 512.0, y: 1105.9), rx: 1024.0, ry: 614.4,
        centerAlpha: 0.10, fadeLocation: 0.60
    )

    // 4. The mark.
    let markRGB: RGB
    switch appearance {
    case .light: markRGB = hexRGB("#EDF3F4")
    case .dark: markRGB = hexRGB("#64D1DD")
    }

    ctx.setLineWidth(86)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Recessed chevron, drawn first so the front chevron overlaps it.
    let recessed = CGMutablePath()
    recessed.move(to: CGPoint(x: 252, y: 288))
    recessed.addLine(to: CGPoint(x: 444, y: 448))
    recessed.addLine(to: CGPoint(x: 252, y: 608))
    ctx.setStrokeColor(cgColor(markRGB, alpha: 0.38, space: colorSpace))
    ctx.addPath(recessed)
    ctx.strokePath()

    // Front chevron.
    let front = CGMutablePath()
    front.move(to: CGPoint(x: 440, y: 268))
    front.addLine(to: CGPoint(x: 664, y: 448))
    front.addLine(to: CGPoint(x: 440, y: 628))
    ctx.setStrokeColor(cgColor(markRGB, alpha: 1.0, space: colorSpace))
    ctx.addPath(front)
    ctx.strokePath()

    // Cursor block.
    let cursorRect = CGRect(x: 386, y: 716, width: 300, height: 86)
    let cursorPath = CGPath(roundedRect: cursorRect, cornerWidth: 43, cornerHeight: 43, transform: nil)
    ctx.setFillColor(cgColor(markRGB, alpha: 1.0, space: colorSpace))
    ctx.addPath(cursorPath)
    ctx.fillPath()
}

func renderIcon(pixelSize: Int, appearance: Appearance) -> CGImage {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        fail("could not create sRGB color space")
    }
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fail("could not create bitmap context for size \(pixelSize)")
    }

    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    ctx.translateBy(x: 0, y: CGFloat(pixelSize))
    ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: CGFloat(pixelSize) / 1024.0, y: CGFloat(pixelSize) / 1024.0)

    drawIcon(ctx: ctx, colorSpace: colorSpace, appearance: appearance)

    guard let image = ctx.makeImage() else {
        fail("could not create image for size \(pixelSize)")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        fail("could not create PNG destination for \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("could not write PNG to \(url.path)")
    }
}

// MARK: - Icon set specification

struct IconSpec {
    let filename: String
    let pixelSize: Int
    let sizeString: String
    let scale: String
}

let iconSpecs: [IconSpec] = [
    IconSpec(filename: "icon_16x16.png", pixelSize: 16, sizeString: "16x16", scale: "1x"),
    IconSpec(filename: "icon_16x16@2x.png", pixelSize: 32, sizeString: "16x16", scale: "2x"),
    IconSpec(filename: "icon_32x32.png", pixelSize: 32, sizeString: "32x32", scale: "1x"),
    IconSpec(filename: "icon_32x32@2x.png", pixelSize: 64, sizeString: "32x32", scale: "2x"),
    IconSpec(filename: "icon_128x128.png", pixelSize: 128, sizeString: "128x128", scale: "1x"),
    IconSpec(filename: "icon_128x128@2x.png", pixelSize: 256, sizeString: "128x128", scale: "2x"),
    IconSpec(filename: "icon_256x256.png", pixelSize: 256, sizeString: "256x256", scale: "1x"),
    IconSpec(filename: "icon_256x256@2x.png", pixelSize: 512, sizeString: "256x256", scale: "2x"),
    IconSpec(filename: "icon_512x512.png", pixelSize: 512, sizeString: "512x512", scale: "1x"),
    IconSpec(filename: "icon_512x512@2x.png", pixelSize: 1024, sizeString: "512x512", scale: "2x"),
]

func writeAppIconContentsJSON(to url: URL, specs: [IconSpec]) {
    var lines: [String] = []
    lines.append("{")
    lines.append("  \"images\" : [")
    for (index, spec) in specs.enumerated() {
        let comma = index < specs.count - 1 ? "," : ""
        lines.append("    {")
        lines.append("      \"filename\" : \"\(spec.filename)\",")
        lines.append("      \"idiom\" : \"mac\",")
        lines.append("      \"scale\" : \"\(spec.scale)\",")
        lines.append("      \"size\" : \"\(spec.sizeString)\"")
        lines.append("    }\(comma)")
    }
    lines.append("  ],")
    lines.append("  \"info\" : {")
    lines.append("    \"author\" : \"xcode\",")
    lines.append("    \"version\" : 1")
    lines.append("  }")
    lines.append("}")
    let content = lines.joined(separator: "\n") + "\n"
    do {
        try content.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        fail("could not write \(url.path): \(error)")
    }
}

// MARK: - Repo root resolution

// #filePath is design/icon/RenderAppIcon.swift. Strip the filename, then go
// up two directories (icon/ -> design/ -> repo root) to find the repo root,
// independent of the current working directory the script is invoked from.
func resolveRepoRoot() -> URL {
    let scriptURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    return scriptURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

// MARK: - Main

let repoRoot = resolveRepoRoot()
let defaultOutDir = repoRoot
    .appendingPathComponent("macapp")
    .appendingPathComponent("Agents")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

let options = parseOptions(arguments: Array(CommandLine.arguments.dropFirst()), defaultOutDir: defaultOutDir)

do {
    try FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
} catch {
    fail("could not create output directory \(options.outDir.path): \(error)")
}

var filesWritten = 0

for spec in iconSpecs {
    let image = renderIcon(pixelSize: spec.pixelSize, appearance: options.appearance)
    let fileURL = options.outDir.appendingPathComponent(spec.filename)
    writePNG(image, to: fileURL)
    print("Wrote \(fileURL.path)")
    filesWritten += 1
}

let contentsURL = options.outDir.appendingPathComponent("Contents.json")
writeAppIconContentsJSON(to: contentsURL, specs: iconSpecs)
print("Wrote \(contentsURL.path)")
filesWritten += 1

print("Rendered \(filesWritten) files (\(options.appearance.rawValue) appearance) into \(options.outDir.path)")
