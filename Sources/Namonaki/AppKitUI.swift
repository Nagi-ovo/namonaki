import AppKit

@MainActor
enum AppKitUI {
    static func label(
        _ text: String = "",
        size: CGFloat = NSFont.systemFontSize,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        monospaced: Bool = false,
        wrapping: Bool = false
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
        label.maximumNumberOfLines = wrapping ? 0 : 1
        label.cell?.wraps = wrapping
        label.cell?.isScrollable = !wrapping
        if wrapping {
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return label
    }

    static func stack(
        _ views: [NSView] = [],
        orientation: NSUserInterfaceLayoutOrientation = .vertical,
        spacing: CGFloat = 8,
        alignment: NSLayoutConstraint.Attribute = .leading
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = spacing
        // NSStackView 没有「横向撑满」语义；垂直 stack 传 .width
        // 时要显式把每个 arranged view 约束到同宽，否则 AppKit 会把内容挤到右边。
        let stretchesWidth = orientation == .vertical && alignment == .width
        stack.alignment = stretchesWidth ? .leading : alignment
        stack.distribution = .fill
        if stretchesWidth {
            for view in views {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }

    static func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    static func symbolButton(
        _ symbol: String,
        accessibilityLabel: String,
        target: AnyObject?,
        action: Selector
    ) -> NSButton {
        let button = NSButton(
            image: NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: accessibilityLabel
            ) ?? NSImage(),
            target: target,
            action: action
        )
        button.bezelStyle = .rounded
        button.toolTip = accessibilityLabel
        return button
    }

    static func switchRow(
        title: String,
        detail: String,
        target: AnyObject?,
        action: Selector
    ) -> (view: NSView, control: NSSwitch) {
        let titleLabel = label(title, size: 13)
        let detailLabel = label(
            detail,
            size: 11,
            color: .secondaryLabelColor,
            wrapping: true
        )
        let copy = stack([titleLabel, detailLabel], spacing: 2)
        let toggle = NSSwitch()
        toggle.target = target
        toggle.action = action
        let row = stack([copy, toggle], orientation: .horizontal, spacing: 12, alignment: .centerY)
        copy.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        return (row, toggle)
    }

    static func installTopStack(
        _ stack: NSStackView,
        in view: NSView,
        insets: NSEdgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
    ) {
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: insets.top),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insets.left),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -insets.right),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension NSControl.StateValue {
    init(_ value: Bool) {
        self = value ? .on : .off
    }
}
