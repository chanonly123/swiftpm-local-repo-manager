import SwiftUI
import AppKit

// MARK: - NSTextView wrapper for multi-line diff rendering with selection

private extension NSAttributedString.Key {
    static let fileSeparator = NSAttributedString.Key("diffFileSeparator")
    static let lineHighlight = NSAttributedString.Key("diffLineHighlight")
}

// NSTextView that draws full-width row highlights behind the text and a horizontal
// rule above any line carrying .fileSeparator.
private final class DiffNSTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        // Full-width row highlights are drawn behind the text; the file separators
        // are drawn after (on top of) the glyphs.
        drawLineHighlights()
        super.draw(dirtyRect)
        drawFileSeparators()
    }

    private func drawLineHighlights() {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return }
        let inset = textContainerInset
        ts.enumerateAttribute(.lineHighlight, in: NSRange(location: 0, length: ts.length)) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            color.setFill()
            NSRect(x: 0, y: rect.minY + inset.height, width: bounds.width, height: rect.height).fill()
        }
    }

    private func drawFileSeparators() {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return }
        let inset = textContainerInset
        ts.enumerateAttribute(.fileSeparator, in: NSRange(location: 0, length: ts.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let height: CGFloat = 4
            let y = (rect.minY + inset.height - 12).rounded()
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: height).fill()
        }
    }
}

struct DiffTextView: NSViewRepresentable {
    let lines: [DiffLine]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize
        let textView = DiffNSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: contentSize.width,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let attrString = NSMutableAttributedString()
        for line in lines {
            if line.kind == .fileHeader {
                let para = NSMutableParagraphStyle()
                para.paragraphSpacingBefore = line.showSeparator ? 100 : 2
                para.paragraphSpacing = 4
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: para
                ]
                if line.showSeparator { attrs[.fileSeparator] = true }
                attrString.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
                continue
            }
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 2
            para.lineHeightMultiple = 1.15
            // Hang-indent wrapped portions of long lines past the +/- gutter
            para.headIndent = 14
            let (fg, highlight) = nsColors(line.kind)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: line.kind == .hunk ? .semibold : .regular),
                .foregroundColor: fg,
                .paragraphStyle: para
            ]
            if let highlight { attrs[.lineHighlight] = highlight }
            attrString.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
        }
        textView.textStorage?.setAttributedString(attrString)
        textView.needsDisplay = true
    }

    // Returns the text color and an optional full-width row-highlight color.
    private func nsColors(_ kind: DiffLine.Kind) -> (NSColor, NSColor?) {
        switch kind {
        case .added:      return (.systemGreen, NSColor.systemGreen.withAlphaComponent(0.13))
        case .removed:    return (.systemRed, NSColor.systemRed.withAlphaComponent(0.13))
        case .hunk:       return (.secondaryLabelColor, NSColor.systemBlue.withAlphaComponent(0.10))
        case .meta:       return (.secondaryLabelColor, nil)
        case .context:    return (.labelColor, nil)
        case .fileHeader: return (.labelColor, nil)
        }
    }
}
