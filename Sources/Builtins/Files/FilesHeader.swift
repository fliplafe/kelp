import AppKit
import KelpKit

/// The bar over the tree, as every inspector panel has one: the search field, New File, and the rest in ⋯.
extension FilesPanel {
    func header() -> NSView {
        let plus = barButton("plus", String(localized: "New File"), #selector(newFile))
        let more = barButton("ellipsis.circle", String(localized: "More"), #selector(showMore(_:)))
        let bar = NSStackView(views: [search, plus, more])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSBox()
        line.boxType = .separator
        let v = NSView()
        for x in [bar, line] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: v.topAnchor), bar.heightAnchor.constraint(equalToConstant: 36),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor), bar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            line.topAnchor.constraint(equalTo: bar.bottomAnchor), line.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: v.leadingAnchor), line.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        ])
        return v
    }

    private func barButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: .symbol(symbol, tip), target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.contentTintColor = .secondaryLabelColor
        b.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    @objc private func showMore(_ sender: NSButton) {
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "New Folder…"), action: #selector(newFolder), keyEquivalent: "").target = self
        m.addItem(withTitle: String(localized: "New from Template…"), action: #selector(newFromTemplate), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "Collapse All"), action: #selector(collapseAll), keyEquivalent: "").target = self
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }
}
