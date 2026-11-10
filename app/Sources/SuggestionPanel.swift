// The pop-up that shows the suggestion next to the caret: a borderless panel that never takes focus or clicks. The next word
// (what Tab inserts) is highlighted, the rest dimmed.
import AppKit

final class SuggestionPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private(set) var visible = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 24), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.masksToBounds = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        panel.contentView = bg
    }

    /// `word`: the next word as it will read after Tab (the unfinished word completed); `rest`: the words after it.
    func show(word: String, rest: String, caret: CGRect?, field: CGRect?, beside: Bool) {
        let size = NSFont.systemFontSize
        let s = NSMutableAttributedString(string: word, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                                                     .foregroundColor: NSColor.controlAccentColor])
        if !rest.isEmpty {
            s.append(NSAttributedString(string: " " + rest, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        s.append(NSAttributedString(string: "   ⇥", attributes: [.font: NSFont.systemFont(ofSize: size - 2), .foregroundColor: NSColor.tertiaryLabelColor]))
        label.attributedStringValue = s
        let w = min(ceil(s.size().width) + 18, 520), h = ceil(s.size().height) + 8
        // anchor: the caret, else the bottom left of the text field
        let anchor = AX.toCocoa(caret ?? field.map { CGRect(x: $0.minX + 4, y: $0.maxY - 20, width: 1, height: 18) } ?? .zero)
        var origin = beside ? CGPoint(x: anchor.maxX + 6, y: anchor.midY - h / 2) : CGPoint(x: anchor.minX - 8, y: anchor.minY - h - 4)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if origin.y < vf.minY { origin.y = anchor.maxY + 4 }          // no room below: above the caret
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - w - 4)
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
        visible = true
    }

    func hide() {
        guard visible else { return }
        panel.orderOut(nil)
        visible = false
    }
}
