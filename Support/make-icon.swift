#!/usr/bin/env swift
import AppKit

// AppIcon.svg를 .iconset의 PNG들로 굽는다. rsvg나 ImageMagick 없이 되는 이유는
// macOS의 NSImage가 SVG를 직접 읽기 때문이다(_NSSVGImageRep). 원본이 벡터라
// 크기마다 다시 그리므로 16px에서도 흐려지지 않는다.
//
//   swift Support/make-icon.swift            # .build/AppIcon.iconset 생성
//   iconutil -c icns -o Support/AppIcon.icns .build/AppIcon.iconset

let source = URL(fileURLWithPath: "Support/AppIcon.svg")
let output = URL(fileURLWithPath: ".build/AppIcon.iconset", isDirectory: true)

guard let vector = NSImage(contentsOf: source) else {
    FileHandle.standardError.write(Data("[-] cannot read \(source.path)\n".utf8))
    exit(1)
}

/// `iconutil`이 요구하는 이름과 픽셀 크기. 이름이 하나라도 틀리면 굽지 않는다.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for variant in variants {
    let size = NSSize(width: variant.pixels, height: variant.pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: variant.pixels,
        pixelsHigh: variant.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { continue }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    vector.draw(
        in: NSRect(origin: .zero, size: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let file = output.appendingPathComponent("\(variant.name).png")
    do {
        try data.write(to: file, options: .atomic)
        print("[+] \(variant.name).png \(variant.pixels)px")
    } catch {
        FileHandle.standardError.write(Data("[-] \(variant.name): \(error)\n".utf8))
        exit(1)
    }
}
