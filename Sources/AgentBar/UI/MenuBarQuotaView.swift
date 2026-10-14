import AppKit

final class MenuBarQuotaView: NSControl {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 6
        static let iconSize: CGFloat = 18
        static let iconSpacing: CGFloat = 5
        static let textSpacing: CGFloat = 5
    }

    private let iconView = NSImageView()
    private let fiveHourPrefixLabel = NSTextField(labelWithString: "5h")
    private let fiveHourPercentLabel = NSTextField(labelWithString: "--")
    private let weekPrefixLabel = NSTextField(labelWithString: I18n.current.shortWeek)
    private let weekPercentLabel = NSTextField(labelWithString: "--")
    private let quotaStack = NSStackView()
    private var fiveHourRow: NSStackView?
    private var displaysFiveHourQuota = false

    var preferredWidth: CGFloat {
        let fiveHourWidth = fiveHourPrefixLabel.intrinsicContentSize.width
            + Metrics.textSpacing
            + fiveHourPercentLabel.intrinsicContentSize.width
        let weekWidth = weekPrefixLabel.intrinsicContentSize.width
            + Metrics.textSpacing
            + weekPercentLabel.intrinsicContentSize.width
        let quotaWidth = displaysFiveHourQuota ? max(fiveHourWidth, weekWidth) : weekWidth

        return ceil(
            Metrics.horizontalPadding * 2
                + Metrics.iconSize
                + Metrics.iconSpacing
                + quotaWidth
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: NSStatusBar.system.thickness)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(snapshot: QuotaSnapshot?, displaysFiveHourQuota: Bool, statusMessage: String) {
        toolTip = statusMessage
        self.displaysFiveHourQuota = displaysFiveHourQuota
        fiveHourRow?.isHidden = !displaysFiveHourQuota

        if let snapshot {
            fiveHourPrefixLabel.stringValue = snapshot.fiveHour?.shortTitle ?? "5h"
            fiveHourPercentLabel.stringValue = snapshot.fiveHour
                .map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--"
            fiveHourPercentLabel.textColor = snapshot.fiveHour
                .map { quotaColor(forRemainingPercent: $0.remainingPercent) } ?? .secondaryLabelColor
            weekPrefixLabel.stringValue = snapshot.weekly.shortTitle
            weekPercentLabel.stringValue = "\(Int(snapshot.weekly.remainingPercent.rounded()))%"
            weekPercentLabel.textColor = quotaColor(forRemainingPercent: snapshot.weekly.remainingPercent)
        } else {
            fiveHourPrefixLabel.stringValue = "5h"
            fiveHourPercentLabel.stringValue = "--"
            fiveHourPercentLabel.textColor = .secondaryLabelColor
            weekPrefixLabel.stringValue = I18n.current.shortWeek
            weekPercentLabel.stringValue = "--"
            weekPercentLabel.textColor = .secondaryLabelColor
        }

        invalidateIntrinsicContentSize()
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    private func setup() {
        wantsLayer = true
        toolTip = I18n.current.codexQuota
        let quotaFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)

        if let image = AppIcon.menuBarImage() {
            iconView.image = image
            iconView.contentTintColor = nil
        } else {
            iconView.image = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: I18n.current.codexQuota)
            iconView.contentTintColor = .labelColor
        }
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        [fiveHourPrefixLabel, fiveHourPercentLabel, weekPrefixLabel, weekPercentLabel].forEach { label in
            label.font = quotaFont
            label.alignment = .left
            label.lineBreakMode = .byClipping
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        fiveHourPrefixLabel.textColor = .labelColor
        weekPrefixLabel.textColor = .labelColor
        fiveHourPercentLabel.textColor = .secondaryLabelColor
        weekPercentLabel.textColor = .secondaryLabelColor

        let fiveHourRow = makeTextRow(prefix: fiveHourPrefixLabel, percent: fiveHourPercentLabel)
        self.fiveHourRow = fiveHourRow
        let weekRow = makeTextRow(prefix: weekPrefixLabel, percent: weekPercentLabel)

        quotaStack.orientation = .vertical
        quotaStack.alignment = .leading
        quotaStack.distribution = .fillEqually
        quotaStack.spacing = -1
        quotaStack.translatesAutoresizingMaskIntoConstraints = false
        quotaStack.addArrangedSubview(fiveHourRow)
        quotaStack.addArrangedSubview(weekRow)

        NSLayoutConstraint.activate([
            fiveHourRow.widthAnchor.constraint(equalTo: quotaStack.widthAnchor),
            weekRow.widthAnchor.constraint(equalTo: quotaStack.widthAnchor),
        ])

        addSubview(iconView)
        addSubview(quotaStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            quotaStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Metrics.iconSpacing),
            quotaStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            quotaStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            quotaStack.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func makeTextRow(prefix: NSTextField, percent: NSTextField) -> NSStackView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        percent.alignment = .right

        let row = NSStackView(views: [prefix, spacer, percent])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false

        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.textSpacing).isActive = true

        return row
    }

    private func quotaColor(forRemainingPercent percent: Double) -> NSColor {
        switch percent {
        case ...20:
            return .systemRed
        case ...50:
            return QuotaPalette.warningNSColor
        default:
            return .systemGreen
        }
    }
}
