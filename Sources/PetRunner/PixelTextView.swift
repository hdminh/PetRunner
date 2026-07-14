import AppKit
import PetRunnerCore

@MainActor
final class PixelTextView: NSView {
    var lines: [String] = [] { didSet { needsDisplay = true } }
    private let scale: CGFloat = 2
    private let characterSpacing: CGFloat = 2
    private let lineSpacing: CGFloat = 5

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        var y = bounds.maxY - 14
        for line in lines {
            var x = bounds.minX
            for character in line.uppercased() {
                let glyph = PixelGlyphs.glyph(for: character)
                for (row, bits) in glyph.enumerated() {
                    for column in 0..<5 where (bits & (1 << (4 - column))) != 0 {
                        NSBezierPath(rect: CGRect(x: x + CGFloat(column) * scale, y: y - CGFloat(row) * scale, width: scale, height: scale)).fill()
                    }
                }
                x += 5 * scale + characterSpacing
            }
            y -= 7 * scale + lineSpacing
        }
    }
}
