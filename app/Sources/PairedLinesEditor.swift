// Two text boxes side by side whose lines pair up: line 1 on the left goes with line 1 on the right (an example's typed text and
// its continuation, a test case's text and what comes next). Same height, scrolled together, line numbers on both, the current line
// highlighted in both, no wrapping (a wrapped line would break the pairing). Spaces at the start or end of a line are shaded,
// because they matter ("Buy milk and " vs "Buy milk and").
import AppKit
import SwiftUI

private let lineHeight: CGFloat = 20
private let inset = NSSize(width: 4, height: 4)

final class PairedTextView: NSTextView {
    var highlight = -1 { didSet { if highlight != oldValue { needsDisplay = true } } }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlight >= 0 else { return }
        let r = NSRect(x: 0, y: inset.height + CGFloat(highlight) * lineHeight, width: max(bounds.width, 2000), height: lineHeight)
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
        r.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: r.maxY - 1, width: r.width, height: 1).fill()           // an underline under the current line
    }

    func line(at index: Int) -> Int {
        let s = string as NSString
        let end = min(index, s.length)
        var n = 0
        for i in 0..<end where s.character(at: i) == 10 { n += 1 }
        return n
    }

    var lineCount: Int { string.isEmpty ? 1 : string.components(separatedBy: "\n").count }

    /// Shade leading and trailing spaces of every line.
    func markSpaces() {
        guard let lm = layoutManager else { return }
        let s = string as NSString
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: s.length))
        var start = 0
        for lineText in string.components(separatedBy: "\n") {
            let ns = lineText as NSString
            let lead = lineText.prefix(while: { $0 == " " }).utf16.count
            let trail = lineText.reversed().prefix(while: { $0 == " " }).count
            let color = NSColor.systemOrange.withAlphaComponent(0.35)
            if lineText.trimmingCharacters(in: .whitespaces).isEmpty == false {
                if lead > 0 { lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: NSRange(location: start, length: lead)) }
                if trail > 0 { lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: NSRange(location: start + ns.length - trail, length: trail)) }
            }
            start += ns.length + 1
        }
    }
}

/// Line numbers beside a box, following its vertical scroll; the current line's number in the accent color.
final class LineGutter: NSView {
    var offset: CGFloat = 0 { didSet { needsDisplay = true } }
    var highlight = -1 { didSet { needsDisplay = true } }
    var count = 1 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        let first = max(0, Int((offset - inset.height) / lineHeight))
        let last = min(count - 1, Int((offset + bounds.height) / lineHeight) + 1)
        guard first <= last else { return }
        for i in first...last {
            let current = i == highlight
            let s = NSAttributedString(string: "\(i + 1)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: current ? .bold : .regular),
                .foregroundColor: current ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor])
            let y = inset.height + CGFloat(i) * lineHeight - offset + (lineHeight - s.size().height) / 2
            s.draw(at: NSPoint(x: bounds.width - s.size().width - 6, y: y))
        }
    }
}

final class PairedLinesView: NSView, NSTextViewDelegate {
    let left = PairedTextView(), right = PairedTextView()
    private let leftScroll = NSScrollView(), rightScroll = NSScrollView()
    private let leftGutter = LineGutter(), rightGutter = LineGutter()
    private var syncing = false
    var onChange: ((String, String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (tv, sv, g) in [(left, leftScroll, leftGutter), (right, rightScroll, rightGutter)] {
            setUp(tv, sv)
            addSubview(sv)
            addSubview(g)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setUp(_ tv: PairedTextView, _ sv: NSScrollView) {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = font
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [.font: font, .paragraphStyle: para, .foregroundColor: NSColor.textColor]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = inset
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.delegate = self
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: sv.contentView)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let gap: CGFloat = 8, g: CGFloat = 30, w = (bounds.width - gap) / 2
        leftGutter.frame = NSRect(x: 0, y: 0, width: g, height: bounds.height)
        leftScroll.frame = NSRect(x: g, y: 0, width: w - g, height: bounds.height)
        rightGutter.frame = NSRect(x: w + gap, y: 0, width: g, height: bounds.height)
        rightScroll.frame = NSRect(x: w + gap + g, y: 0, width: w - g, height: bounds.height)
        for v in [leftGutter, rightGutter] { v.wantsLayer = true; v.layer?.cornerRadius = 0 }
    }

    override func draw(_ dirty: NSRect) {                      // a frame around each box (gutter + text)
        NSColor.separatorColor.setStroke()
        for (g, sv) in [(leftGutter, leftScroll), (rightGutter, rightScroll)] {
            let r = g.frame.union(sv.frame).insetBy(dx: 0.5, dy: 0.5)
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).stroke()
        }
    }

    /// Keep both boxes at the same vertical scroll position, so paired lines stay side by side.
    @objc private func scrolled(_ n: Notification) {
        guard !syncing, let clip = n.object as? NSClipView else { return }
        syncing = true
        let other = clip === leftScroll.contentView ? rightScroll : leftScroll
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.origin.x, y: clip.bounds.origin.y))
        other.reflectScrolledClipView(other.contentView)
        refreshRulers()
        syncing = false
    }

    func set(_ l: String, _ r: String) {
        if left.string.isEmpty && right.string.isEmpty,     // for development: `-pairedHighlight 2` shows line 3 as current
           let n = UserDefaults(suiteName: UserDefaults.argumentDomain)?.object(forKey: "pairedHighlight") as? String, let i = Int(n) {
            left.highlight = i
            right.highlight = i
        }
        if left.string != l { left.string = l; left.markSpaces() }
        if right.string != r { right.string = r; right.markSpaces() }
        refreshRulers()
    }

    private func refreshRulers() {
        let count = max(left.lineCount, right.lineCount, max(left.highlight, right.highlight) + 1)
        for (g, sv, tv) in [(leftGutter, leftScroll, left), (rightGutter, rightScroll, right)] {
            g.count = count
            g.highlight = tv.highlight
            g.offset = sv.contentView.bounds.origin.y
        }
    }

    func textDidChange(_ n: Notification) {
        (n.object as? PairedTextView)?.markSpaces()
        refreshRulers()
        onChange?(left.string, right.string)
    }

    func textViewDidChangeSelection(_ n: Notification) {
        guard let tv = n.object as? PairedTextView, tv.window?.firstResponder === tv else { return }
        let line = tv.line(at: tv.selectedRange().location)
        left.highlight = line
        right.highlight = line
        refreshRulers()
    }
}

/// The SwiftUI face of PairedLinesView, bound to the two texts.
struct PairedLinesEditor: NSViewRepresentable {
    @Binding var left: String
    @Binding var right: String

    func makeNSView(context: Context) -> PairedLinesView {
        let v = PairedLinesView()
        v.set(left, right)
        v.onChange = { l, r in
            DispatchQueue.main.async {
                if left != l { left = l }
                if right != r { right = r }
            }
        }
        return v
    }

    func updateNSView(_ v: PairedLinesView, context: Context) {
        v.set(left, right)
    }
}

/// Pairs from two line-paired texts, and the line numbers where only one side is filled.
enum LinePairs {
    static func split(_ l: String, _ r: String) -> (pairs: [(String, String)], incomplete: [Int]) {
        let a = l.components(separatedBy: "\n"), b = r.components(separatedBy: "\n")
        var pairs: [(String, String)] = [], incomplete: [Int] = []
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "", y = i < b.count ? b[i] : ""
            let ex = !x.trimmingCharacters(in: .whitespaces).isEmpty, ey = !y.trimmingCharacters(in: .whitespaces).isEmpty
            if ex && ey { pairs.append((x, y)) } else if ex != ey { incomplete.append(i + 1) }
        }
        return (pairs, incomplete)
    }
}
