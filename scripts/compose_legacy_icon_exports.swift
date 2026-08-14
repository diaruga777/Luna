#!/usr/bin/swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Output {
    let filename: String
    let exportFilename: String
}

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: compose_legacy_icon_exports.swift <exports-dir> <opaque-master.png> <output-dir>\n", stderr)
    exit(64)
}

let exportsDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let masterURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)

let outputs = [
    Output(filename: "Luna Downloader-iOS-Default-20@2x.png", exportFilename: "Luna Downloader-iOS-Default-20@2x.png"),
    Output(filename: "Luna Downloader-iOS-Default-20@3x.png", exportFilename: "Luna Downloader-iOS-Default-20@3x.png"),
    Output(filename: "Luna Downloader-iOS-Default-29@2x.png", exportFilename: "Luna Downloader-iOS-Default-29@2x.png"),
    Output(filename: "Luna Downloader-iOS-Default-29@3x.png", exportFilename: "Luna Downloader-iOS-Default-29@3x.png"),
    Output(filename: "Luna Downloader-iOS-Default-40@2x.png", exportFilename: "Luna Downloader-iOS-Default-40@2x.png"),
    Output(filename: "Luna Downloader-iOS-Default-40@3x.png", exportFilename: "Luna Downloader-iOS-Default-40@3x.png"),
    Output(filename: "Luna Downloader-iOS-Default-60@2x.png", exportFilename: "Luna Downloader-iOS-Default-60@2x.png"),
    Output(filename: "Luna Downloader-iOS-Default-60@3x.png", exportFilename: "Luna Downloader-iOS-Default-60@3x.png"),
    Output(filename: "Luna Downloader-iOS-Default-20@1x.png", exportFilename: "Luna Downloader-iOS-Default-20@2x.png"),
    Output(filename: "Luna Downloader-iOS-Default-29@1x.png", exportFilename: "Luna Downloader-iOS-Default-29@2x.png"),
    Output(filename: "Luna Downloader-iOS-Default-40@1x.png", exportFilename: "Luna Downloader-iOS-Default-40@2x.png"),
    Output(filename: "Luna Downloader-iOS-Default-76@1x.png", exportFilename: "Luna Downloader-iOS-Default-76@2x.png"),
    Output(filename: "Luna Downloader-iOS-Default-76@2x.png", exportFilename: "Luna Downloader-iOS-Default-76@2x.png"),
    Output(filename: "Luna Downloader-iOS-Default-83.5@2x.png", exportFilename: "Luna Downloader-iOS-Default-83.5@2x.png"),
    Output(filename: "AppIconVideo-1024.png", exportFilename: "Luna Downloader-iOS-Default-1024@1x.png")
]

func image(at url: URL) -> NSImage {
    guard let image = NSImage(contentsOf: url) else {
        fputs("Could not load \(url.path)\n", stderr)
        exit(1)
    }
    return image
}

let master = image(at: masterURL)

func cgImage(from image: NSImage, named name: String) -> CGImage {
    guard let image = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fputs("Could not create a bitmap for \(name)\n", stderr)
        exit(1)
    }
    return image
}

let masterCGImage = cgImage(from: master, named: masterURL.lastPathComponent)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

for output in outputs {
    let export = image(at: exportsDirectory.appendingPathComponent(output.exportFilename))
    let pixels = export.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? .zero
    let targetSize: NSSize
    if output.filename.contains("@1x") && output.exportFilename.contains("@2x") {
        targetSize = NSSize(width: pixels.width / 2, height: pixels.height / 2)
    } else {
        targetSize = pixels
    }

    guard let context = CGContext(
        data: nil,
        width: Int(targetSize.width),
        height: Int(targetSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        fputs("Could not create an opaque bitmap for \(output.filename)\n", stderr)
        exit(1)
    }

    context.interpolationQuality = .high
    let rect = CGRect(origin: .zero, size: targetSize)
    context.draw(masterCGImage, in: rect)
    context.draw(cgImage(from: export, named: output.exportFilename), in: rect)

    guard let composedImage = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              outputDirectory.appendingPathComponent(output.filename) as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        fputs("Could not encode \(output.filename)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(destination, composedImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        fputs("Could not write \(output.filename)\n", stderr)
        exit(1)
    }
}
