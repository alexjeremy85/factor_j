// make_icon.swift — gera assets/AppIcon.icns desenhando com AppKit.
// Uso: swift scripts/make_icon.swift   (a partir da raiz do repositório)
//
// Conceito: discreto de propósito — "J" branco sobre fundo quase preto,
// sem nenhuma alusão visual a gravação de áudio.

import AppKit

let iconsetDir = URL(fileURLWithPath: "assets/AppIcon.iconset")
let icnsPath = "assets/AppIcon.icns"

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let S = CGFloat(pixels)

    // Grade do macOS: conteúdo ocupa ~824/1024 com margem transparente.
    let inset = S * 0.098
    let rect = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let squircle = NSBezierPath(
        roundedRect: rect,
        xRadius: rect.width * 0.2237,
        yRadius: rect.width * 0.2237
    )

    // Fundo quase preto com leve profundidade (preto puro fica chapado).
    let gradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.04, alpha: 1.0),
        NSColor(calibratedWhite: 0.13, alpha: 1.0),
    ])!
    gradient.draw(in: squircle, angle: 90)

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()

    // "J" gigante em SF Rounded, centralizado.
    let fontSize = S * 0.60
    let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let font = baseFont.fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: fontSize) } ?? baseFont

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -S * 0.012)
    shadow.shadowBlurRadius = S * 0.03

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .shadow: shadow,
    ]
    let letter = NSAttributedString(string: "J", attributes: attributes)
    let textSize = letter.size()
    letter.draw(at: NSPoint(
        x: rect.midX - textSize.width / 2,
        y: rect.midY - textSize.height / 2 + rect.height * 0.04
    ))

    NSGraphicsContext.current?.restoreGraphicsState()
    return rep
}

// Gera o iconset completo.
let fm = FileManager.default
try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let rep = drawIcon(pixels: points * scale)
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG falhou para \(name)")
    }
    try png.write(to: iconsetDir.appendingPathComponent(name))
}

// Converte para .icns.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsPath]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil falhou") }
try? fm.removeItem(at: iconsetDir)
print("✅ \(icnsPath)")
