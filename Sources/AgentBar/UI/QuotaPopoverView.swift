import AppKit
import SwiftUI

struct QuotaPopoverView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var updateCoordinator: AppUpdateCoordinator
    let onAbout: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AccountInfoHeader(
                account: store.currentAccount,
                fallbackPlanType: store.snapshot?.planType,
                accountErrorMessage: store.accountErrorMessage,
                isRefreshing: store.isLoading,
                onRefresh: store.refresh
            )
                .padding(.horizontal, QuotaPopoverLayout.horizontalPadding)
                .padding(.bottom, 10)
            Divider()
                .padding(.horizontal, QuotaPopoverLayout.horizontalPadding)

            content
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, QuotaPopoverLayout.horizontalPadding)
                .padding(.top, 4)
                .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, QuotaPopoverLayout.horizontalPadding)

            footer
                .padding(.top, 10)
        }
        .padding(.top, QuotaPopoverLayout.topPadding)
        .padding(.bottom, 16)
        .frame(width: 320)
        .frame(height: popoverHeight)
        .background(Color.clear)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = store.snapshot {
            VStack(spacing: 0) {
                ResetCreditsRow(
                    availableCount: snapshot.availableResetCredits,
                    credits: snapshot.resetCredits
                )
                Divider()
                    .padding(.top, 4)
                    .padding(.bottom, 10)

                VStack(spacing: 14) {
                    if displaysFiveHourQuota, let fiveHour = snapshot.fiveHour {
                        QuotaRow(window: fiveHour)
                        Divider()
                    }
                    QuotaRow(window: snapshot.weekly)
                }

                Divider()
                    .padding(.vertical, 10)

                TokenUsageSectionView(
                    snapshot: store.tokenUsageSnapshot,
                    errorMessage: store.tokenUsageErrorMessage,
                    isLoading: store.isLoading
                )
            }
        } else {
            LoadingStatusView(
                statusMessage: store.statusMessage,
                cliUpgradeMessage: store.cliUpgradeMessage
            )
            .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Text(I18n.current.lastRefreshPrefix)
                    .foregroundStyle(QuotaPopoverColors.mutedText)

                Spacer(minLength: 8)

                Text(lastRefreshValue)
                    .foregroundStyle(QuotaPopoverColors.mutedText)
                    .monospacedDigit()
            }
            .padding(.horizontal, QuotaPopoverLayout.horizontalPadding)

            Divider()
                .padding(.horizontal, QuotaPopoverLayout.horizontalPadding)

            VStack(spacing: 4) {
                FooterActionButton(title: I18n.current.aboutUs, action: onAbout) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }

                FooterSplitActionRow(
                    currentVersion: appVersionDisplayText,
                    updateState: updateCoordinator.state,
                    isUpdateActionEnabled: updateCoordinator.canPerformUserInitiatedCheck,
                    onQuit: onQuit,
                    onCheckForUpdates: updateCoordinator.checkForUpdates
                )
            }
            .padding(.horizontal, QuotaPopoverLayout.menuHighlightMargin)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var lastRefreshValue: String {
        if let lastUpdated = store.snapshot?.lastUpdated {
            return lastUpdated.formatted(.dateTime.hour().minute().locale(Locale(identifier: I18n.current.dateLocaleIdentifier)))
        }

        return store.isLoading ? I18n.current.loading : I18n.current.notRefreshed
    }

    private var appVersionDisplayText: String {
        let version = AppVersion.shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.lowercased().hasPrefix("v") {
            return version
        }

        return version.isEmpty ? "" : "v\(version)"
    }

    private var displaysFiveHourQuota: Bool {
        store.displaysFiveHourQuota
    }

    private var popoverHeight: CGFloat {
        displaysFiveHourQuota ? QuotaPopoverLayout.expandedHeight : QuotaPopoverLayout.compactHeight
    }
}

private enum QuotaPopoverLayout {
    static let compactHeight: CGFloat = 520
    static let expandedHeight: CGFloat = 624
    static let topPadding: CGFloat = 22
    static let horizontalPadding: CGFloat = 18
    static let menuHighlightMargin: CGFloat = 5
    static let menuItemHorizontalPadding: CGFloat = horizontalPadding - menuHighlightMargin
}

private struct FooterActionButton<Trailing: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)

                Spacer(minLength: 8)

                trailing()
                    .foregroundStyle(trailingColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, QuotaPopoverLayout.menuItemHorizontalPadding)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? QuotaPopoverColors.menuSelectionBackground : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.08), value: isHovering)
    }

    private var textColor: Color {
        isHovering ? QuotaPopoverColors.menuSelectionText : QuotaPopoverColors.primaryText
    }

    private var trailingColor: Color {
        isHovering ? QuotaPopoverColors.menuSelectionText : QuotaPopoverColors.scaleText
    }
}

private struct FooterSplitActionRow: View {
    let currentVersion: String
    let updateState: AppUpdateState
    let isUpdateActionEnabled: Bool
    let onQuit: () -> Void
    let onCheckForUpdates: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FooterCompactActionButton(title: I18n.current.quit, action: onQuit)

            Spacer(minLength: 8)

            AppUpdateFooterButton(
                currentVersion: currentVersion,
                state: updateState,
                isEnabled: isUpdateActionEnabled,
                action: onCheckForUpdates
            )
        }
        .padding(.horizontal, QuotaPopoverLayout.menuItemHorizontalPadding - 7)
    }
}

private struct FooterCompactActionButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? QuotaPopoverColors.menuSelectionText : QuotaPopoverColors.primaryText)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? QuotaPopoverColors.menuSelectionBackground : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.08), value: isHovering)
    }
}

private struct AppUpdateFooterButton: View {
    let currentVersion: String
    let state: AppUpdateState
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                statusContent

                if isHovering, hoverActionIsVisible {
                    HStack(spacing: 3) {
                        Image(systemName: hoverActionSystemImage)
                            .font(.system(size: 9, weight: .semibold))

                        Text(hoverActionTitle)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.75)
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(foregroundColor)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering && isEnabled ? QuotaPopoverColors.menuSelectionBackground : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering && isEnabled
        }
        .help(I18n.current.checkForUpdates)
        .accessibilityLabel(accessibilityLabel)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.easeOut(duration: 0.14), value: state)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state {
        case .unavailable, .idle:
            versionText(currentVersion)
        case .checking:
            ProgressView()
                .controlSize(.small)
            Text(I18n.current.checkingForUpdates)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(I18n.current.updateCheckUpToDate)
            versionText(currentVersion)
        case let .available(item):
            versionText(formattedVersion(item.displayVersion))
            Text(I18n.current.updateAvailable)
        case let .downloading(item):
            ProgressView()
                .controlSize(.small)
            versionText(formattedVersion(item.displayVersion))
            Text(I18n.current.downloadingUpdate)
        case let .ready(item):
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 10, weight: .semibold))
            versionText(formattedVersion(item.displayVersion))
            Text(I18n.current.updateDownloaded)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(I18n.current.updateCheckFailed)
        }
    }

    private var hoverActionIsVisible: Bool {
        switch state {
        case .checking, .upToDate, .downloading, .unavailable:
            return false
        case .idle, .available, .ready, .failed:
            return true
        }
    }

    private var hoverActionTitle: String {
        if case .ready = state {
            return I18n.current.installUpdate
        }

        return I18n.current.checkForUpdates
    }

    private var hoverActionSystemImage: String {
        if case .ready = state {
            return "arrow.down.circle"
        }

        return "arrow.triangle.2.circlepath"
    }

    private var foregroundColor: Color {
        if isHovering && isEnabled {
            return QuotaPopoverColors.menuSelectionText
        }

        switch state {
        case .available, .ready:
            return .accentColor
        case .failed:
            return Color(nsColor: .systemRed)
        case .unavailable, .idle, .checking, .upToDate, .downloading:
            return QuotaPopoverColors.scaleText
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .checking:
            return I18n.current.checkingForUpdates
        case .upToDate:
            return "\(I18n.current.updateCheckUpToDate), \(currentVersion)"
        case let .available(item):
            return "\(formattedVersion(item.displayVersion)), \(I18n.current.updateAvailable)"
        case let .downloading(item):
            return "\(formattedVersion(item.displayVersion)), \(I18n.current.downloadingUpdate)"
        case let .ready(item):
            return "\(formattedVersion(item.displayVersion)), \(I18n.current.updateDownloaded)"
        case .failed:
            return I18n.current.updateCheckFailed
        case .unavailable, .idle:
            return "\(currentVersion), \(I18n.current.checkForUpdates)"
        }
    }

    private func versionText(_ version: String) -> some View {
        Text(version)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
    }

    private func formattedVersion(_ version: String) -> String {
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedVersion.lowercased().hasPrefix("v") {
            return trimmedVersion
        }

        return trimmedVersion.isEmpty ? "" : "v\(trimmedVersion)"
    }
}

private struct AccountInfoHeader: View {
    let account: CodexAccount?
    let fallbackPlanType: String?
    let accountErrorMessage: String?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(QuotaPopoverColors.scaleText)

                Text(displayEmail)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(QuotaPopoverColors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if let accountErrorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("\(I18n.current.accountInfoUnavailable): \(accountErrorMessage)")
                    .accessibilityLabel(I18n.current.accountInfoUnavailable)
                    .accessibilityHint(accountErrorMessage)
            }

            RefreshButton(isRefreshing: isRefreshing, action: onRefresh)

            RoleBadge(role: displayRole)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayEmail: String {
        displayValue(account?.email)
    }

    private var displayRole: String {
        capitalizedFirstLetter(displayValue(account?.planType ?? fallbackPlanType))
    }

    private func displayValue(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return "--"
        }

        return value
    }

    private func capitalizedFirstLetter(_ value: String) -> String {
        guard let first = value.first, first.isLetter else {
            return value
        }

        return first.uppercased() + value.dropFirst().lowercased()
    }
}

private struct RefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? QuotaPopoverColors.menuSelectionText : QuotaPopoverColors.scaleText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovering ? QuotaPopoverColors.menuSelectionBackground : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .disabled(isRefreshing)
        .opacity(isRefreshing ? 0.55 : 1)
        .help(I18n.current.refreshNow)
        .accessibilityLabel(I18n.current.refreshNow)
        .animation(.easeOut(duration: 0.08), value: isHovering)
    }
}

private struct RoleBadge: View {
    let role: String

    var body: some View {
        let style = BadgeStyle(role: role)

        Text(role)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(style.text)
            .padding(.horizontal, style.hasContainer ? 8 : 0)
            .padding(.vertical, style.hasContainer ? 3 : 0)
            .background {
                if style.hasContainer {
                    Capsule()
                        .fill(style.background)
                }
            }
            .overlay {
                if style.hasContainer {
                    Capsule()
                        .stroke(style.border, lineWidth: 1)
                }
            }
    }
}

private struct ResetCreditsRow: View {
    let availableCount: Int?
    let credits: [RateLimitResetCredit]?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(I18n.current.availableResetCredits)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(titleColor)

            Spacer(minLength: 8)

            ResetCreditsBadge(text: displayCount, isHighlighted: isHovering)
                .fixedSize()

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(trailingColor)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? QuotaPopoverColors.menuSelectionBackground : Color.clear)
                .padding(.horizontal, -10)
        }
        .contentShape(Rectangle())
        .overlay {
            ResetCreditsHoverMenuPresenter(
                availableCount: availableCount,
                credits: credits,
                isHovering: $isHovering
            )
            .padding(.horizontal, -10)
        }
        .animation(.easeOut(duration: 0.08), value: isHovering)
    }

    private var displayCount: String {
        availableCount.map(String.init) ?? "--"
    }

    private var titleColor: Color {
        isHovering ? QuotaPopoverColors.menuSelectionText : QuotaPopoverColors.titleText
    }

    private var trailingColor: Color {
        isHovering ? QuotaPopoverColors.menuSelectionText : QuotaPopoverColors.scaleText
    }
}

private struct ResetCreditsBadge: View {
    let text: String
    let isHighlighted: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(isHighlighted ? QuotaPopoverColors.menuSelectionText : QuotaPopoverColors.indigoText)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(isHighlighted ? Color.white.opacity(0.18) : QuotaPopoverColors.indigoBackground)
            }
            .overlay {
                Capsule()
                    .stroke(
                        isHighlighted ? Color.white.opacity(0.5) : QuotaPopoverColors.indigoBorder,
                        lineWidth: 1
                    )
            }
    }
}

private struct ResetCreditsHoverMenuPresenter: NSViewRepresentable {
    let availableCount: Int?
    let credits: [RateLimitResetCredit]?
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> ResetCreditsHoverAnchorView {
        let view = ResetCreditsHoverAnchorView()
        view.onHoverChanged = { hovering in
            isHovering = hovering
        }
        return view
    }

    func updateNSView(_ nsView: ResetCreditsHoverAnchorView, context: Context) {
        nsView.configure(availableCount: availableCount, credits: credits)
        nsView.onHoverChanged = { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
    }

    static func dismantleNSView(_ nsView: ResetCreditsHoverAnchorView, coordinator: ()) {
        nsView.dismissMenu()
        nsView.onHoverChanged = nil
    }
}

private final class ResetCreditsHoverAnchorView: NSView {
    var availableCount: Int?
    var credits: [RateLimitResetCredit]?
    var onHoverChanged: ((Bool) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?
    private var presentedMenu: NSMenu?
    private var pointerTrackingTimer: Timer?
    private var pointerOutsideSince: Date?
    private var isSchedulingPresentation = false
    private var presentationWorkItem: DispatchWorkItem?
    private var scheduledPresentationRequiresPointerInside = true
    private var scheduledPresentationTracksPointer = true

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(I18n.current.availableResetCredits)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            dismissMenu()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func configure(availableCount: Int?, credits: [RateLimitResetCredit]?) {
        self.availableCount = availableCount
        self.credits = credits
        setAccessibilityValue(availableCount.map(String.init) ?? "--")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        pointerOutsideSince = nil
        onHoverChanged?(true)
        scheduleMenuPresentation(requiresPointerInside: true, tracksPointer: true)
    }

    override func mouseDown(with event: NSEvent) {
        scheduleMenuPresentation(requiresPointerInside: false, tracksPointer: true)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            scheduleMenuPresentation(requiresPointerInside: false, tracksPointer: false)
            return
        }

        super.keyDown(with: event)
    }

    private func scheduleMenuPresentation(requiresPointerInside: Bool, tracksPointer: Bool) {
        guard presentedMenu == nil, !isSchedulingPresentation else {
            return
        }

        isSchedulingPresentation = true
        scheduledPresentationRequiresPointerInside = requiresPointerInside
        scheduledPresentationTracksPointer = tracksPointer
        let delay = requiresPointerInside ? 0.12 : 0
        let workItem = DispatchWorkItem { [weak self] in
            self?.presentMenuIfPointerIsStillInside()
        }
        presentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    func dismissMenu() {
        presentationWorkItem?.cancel()
        presentationWorkItem = nil
        isSchedulingPresentation = false
        stopPointerMonitoring()
        presentedMenu?.cancelTrackingWithoutAnimation()
        presentedMenu = nil
    }

    private func presentMenuIfPointerIsStillInside() {
        presentationWorkItem = nil
        isSchedulingPresentation = false

        guard window != nil, !scheduledPresentationRequiresPointerInside || isPointerInside else {
            onHoverChanged?(false)
            return
        }

        let menu = makeDetailsMenu()
        presentedMenu = menu
        if scheduledPresentationTracksPointer {
            startPointerMonitoring()
        }

        _ = menu.popUp(
            positioning: nil,
            at: NSPoint(x: bounds.maxX - 2, y: bounds.minY),
            in: self
        )

        stopPointerMonitoring()
        presentedMenu = nil
        onHoverChanged?(isPointerInside)
    }

    private func startPointerMonitoring() {
        stopPointerMonitoring()
        pointerOutsideSince = nil

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPointerLocation()
            }
        }
        pointerTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPointerMonitoring() {
        pointerTrackingTimer?.invalidate()
        pointerTrackingTimer = nil
        pointerOutsideSince = nil
    }

    private func pollPointerLocation() {
        let pointerIsInsideAnchor = isPointerInside
        onHoverChanged?(pointerIsInsideAnchor)

        if pointerIsInsideAnchor || isPointerInsidePresentedMenu {
            pointerOutsideSince = nil
            return
        }

        let now = Date()
        guard let pointerOutsideSince else {
            self.pointerOutsideSince = now
            return
        }

        guard now.timeIntervalSince(pointerOutsideSince) >= 0.12 else {
            return
        }

        presentedMenu?.cancelTrackingWithoutAnimation()
    }

    private var isPointerInside: Bool {
        guard let window else {
            return false
        }

        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInView = convert(pointInWindow, from: nil)
        return bounds.contains(pointInView)
    }

    private var isPointerInsidePresentedMenu: Bool {
        guard
            let menuWindow = presentedMenu?.items
                .compactMap({ $0.view?.window })
                .first
        else {
            return false
        }

        return menuWindow.frame.contains(NSEvent.mouseLocation)
    }

    private func makeDetailsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = ResetCreditsMenuLayout.width

        let item = NSMenuItem()
        let rootView = ResetCreditsDetailMenuView(
            availableCount: availableCount,
            credits: credits
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: ResetCreditsMenuLayout.width,
            height: ResetCreditsMenuLayout.height(
                availableCount: availableCount,
                credits: credits
            )
        )
        item.view = hostingView
        menu.addItem(item)

        return menu
    }
}

private enum ResetCreditsMenuLayout {
    static let width: CGFloat = 210
    static let rowHeight: CGFloat = 28
    static let maxVisibleRows = 6

    static func height(
        availableCount: Int?,
        credits: [RateLimitResetCredit]?
    ) -> CGFloat {
        let detailCount = credits?.count ?? 0
        let expectedCount = max(availableCount ?? detailCount, detailCount)
        let missingDetailCount = max(0, expectedCount - detailCount)
        let rowCount = max(1, detailCount + (missingDetailCount > 0 ? 1 : 0))
        return rowHeight * CGFloat(min(rowCount, maxVisibleRows))
    }
}

private struct ResetCreditMenuRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
}

private struct ResetCreditsDetailMenuView: View {
    let availableCount: Int?
    let credits: [RateLimitResetCredit]?

    private static let fullResetTitle = "Full reset"

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    ResetCreditDetailRow(row: row)

                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(
            width: ResetCreditsMenuLayout.width,
            height: ResetCreditsMenuLayout.height(
                availableCount: availableCount,
                credits: credits
            )
        )
        .background(Color.clear)
    }

    private var rows: [ResetCreditMenuRow] {
        guard let credits else {
            return [missingDetailsRow(count: availableCount)]
        }

        var rows = credits.map { credit in
            ResetCreditMenuRow(
                id: credit.id,
                title: Self.fullResetTitle,
                subtitle: credit.expiresAt.map(expirationText) ?? I18n.current.resetCreditNeverExpires
            )
        }

        let missingDetailCount = max(0, (availableCount ?? credits.count) - credits.count)
        if missingDetailCount > 0 {
            rows.append(missingDetailsRow(count: missingDetailCount))
        }

        if rows.isEmpty {
            rows.append(
                ResetCreditMenuRow(
                    id: "no-reset-credits",
                    title: I18n.current.noAvailableResetCredits,
                    subtitle: nil
                )
            )
        }

        return rows
    }

    private func missingDetailsRow(count: Int?) -> ResetCreditMenuRow {
        let title: String
        let subtitle: String?

        switch count {
        case let count? where count > 0:
            title = I18n.current.additionalResetCredits(count)
            subtitle = I18n.current.resetCreditDetailsUnavailable
        case 0?:
            title = I18n.current.noAvailableResetCredits
            subtitle = nil
        case nil:
            title = I18n.current.resetCreditDetailsUnavailable
            subtitle = nil
        default:
            title = I18n.current.resetCreditDetailsUnavailable
            subtitle = nil
        }

        return ResetCreditMenuRow(
            id: "missing-reset-credit-details-\(count ?? 0)",
            title: title,
            subtitle: subtitle
        )
    }

    private func expirationText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.current.dateLocaleIdentifier)
        formatter.dateFormat = "M/d"
        return I18n.current.resetCreditExpiresOn(formatter.string(from: date))
    }
}

private struct ResetCreditDetailRow: View {
    let row: ResetCreditMenuRow

    var body: some View {
        HStack(spacing: 8) {
            Text(row.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(QuotaPopoverColors.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(QuotaPopoverColors.mutedText)
                    .lineLimit(1)
                    .monospacedDigit()
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: ResetCreditsMenuLayout.rowHeight)
        .padding(.horizontal, 16)
    }
}

private struct LoadingStatusView: View {
    let statusMessage: String
    let cliUpgradeMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Text(statusMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(QuotaPopoverColors.mutedText)

            if let cliUpgradeMessage {
                Text(cliUpgradeMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct BadgeStyle {
    let role: String

    var hasContainer: Bool {
        switch normalizedRole {
        case "go", "plus", "pro":
            return true
        default:
            return false
        }
    }

    var text: Color {
        switch normalizedRole {
        case "go":
            return Color(nsColor: .systemBlue)
        case "plus":
            return Color(nsColor: .systemGreen)
        case "pro":
            return Color(nsColor: .systemPurple)
        case "free":
            return QuotaPopoverColors.mutedText
        default:
            return QuotaPopoverColors.primaryText
        }
    }

    var background: Color {
        switch normalizedRole {
        case "go":
            return Color(nsColor: .systemBlue).opacity(0.12)
        case "plus":
            return Color(nsColor: .systemGreen).opacity(0.13)
        case "pro":
            return Color(nsColor: .systemPurple).opacity(0.13)
        default:
            return Color.clear
        }
    }

    var border: Color {
        switch normalizedRole {
        case "go":
            return Color(nsColor: .systemBlue).opacity(0.45)
        case "plus":
            return Color(nsColor: .systemGreen).opacity(0.5)
        case "pro":
            return Color(nsColor: .systemPurple).opacity(0.5)
        default:
            return Color.clear
        }
    }

    private var normalizedRole: String {
        role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct QuotaRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QuotaPopoverColors.titleText)

                Spacer(minLength: 12)

                Label(resetText, systemImage: "clock")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(QuotaPopoverColors.mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(displayPercent)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(QuotaPopoverColors.primaryText)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(QuotaPopoverColors.titleText)
            }

            QuotaScaleLabels()

            QuotaScaleTrack(value: window.usedPercent, color: progressColor)
        }
    }

    private var displayTitle: String {
        switch window.windowDurationMins {
        case 10080:
            return I18n.current.recentWeek
        case let duration?:
            return I18n.current.durationTitle(minutes: duration)
        default:
            return window.title
        }
    }

    private var displayPercent: Int {
        Int(window.usedPercent.rounded())
    }

    private var progressColor: Color {
        switch window.remainingPercent {
        case ...20:
            return Color(nsColor: .systemRed)
        case ...50:
            return QuotaPalette.warningColor
        default:
            return Color(nsColor: .systemGreen)
        }
    }

    private var resetText: String {
        guard let resetsAt = window.resetsAt else {
            return I18n.current.resetTimeUnavailable
        }

        if window.windowDurationMins == 300 {
            return I18n.current.refreshAt(Self.timeFormatter().string(from: resetsAt))
        }

        if window.windowDurationMins == 10080 {
            return I18n.current.refreshAt(Self.dateFormatter().string(from: resetsAt))
        }

        let minutesUntilReset = Int(ceil(max(0, resetsAt.timeIntervalSinceNow) / 60))
        guard minutesUntilReset > 0 else {
            return I18n.current.resetSoon
        }

        let days = minutesUntilReset / 1_440
        let hours = (minutesUntilReset % 1_440) / 60
        let minutes = minutesUntilReset % 60

        if days > 0 {
            return I18n.current.resetIn(days: days, hours: Self.twoDigit(hours), minutes: Self.twoDigit(minutes))
        }

        return I18n.current.resetIn(days: days, hours: Self.twoDigit(hours), minutes: Self.twoDigit(minutes))
    }

    private static func twoDigit(_ value: Int) -> String {
        String(format: "%02d", value)
    }

    private static func timeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.current.dateLocaleIdentifier)
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.current.dateLocaleIdentifier)
        formatter.dateFormat = I18n.current.dateFormat
        return formatter
    }
}

private struct QuotaScaleLabels: View {
    private let ticks: [ScaleTick] = [
        ScaleTick(value: 0, label: "0%"),
        ScaleTick(value: 0.5, label: "50%"),
        ScaleTick(value: 0.9, label: "90%"),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(ticks) { tick in
                    Text(tick.label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(tick.value == 0.9 ? QuotaPopoverColors.mutedText : QuotaPopoverColors.scaleText)
                        .monospacedDigit()
                        .position(x: xPosition(for: tick.value, in: proxy.size.width), y: 8)
                }
            }
        }
        .frame(height: 16)
    }

    private func xPosition(for value: Double, in width: CGFloat) -> CGFloat {
        let edgeInset: CGFloat = 16
        return min(max(width * CGFloat(value), edgeInset), max(edgeInset, width - edgeInset))
    }
}

private struct QuotaScaleTrack: View {
    let value: Double
    let color: Color

    private let markerValue = 0.9

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            let tickWidth: CGFloat = 2
            let tickHeight: CGFloat = 7
            let tickSpacing: CGFloat = 5
            let corner = CGSize(width: 1, height: 1)
            let clampedValue = min(max(value, 0), 100)
            let activeWidth = size.width * CGFloat(clampedValue / 100)

            var x: CGFloat = 0
            while x <= size.width {
                let tickRect = CGRect(
                    x: x,
                    y: centerY - tickHeight / 2,
                    width: tickWidth,
                    height: tickHeight
                )
                context.fill(
                    Path(roundedRect: tickRect, cornerSize: corner),
                    with: .color(QuotaPopoverColors.track)
                )
                x += tickSpacing
            }

            if activeWidth > 0 {
                let activeRect = CGRect(
                    x: 0,
                    y: centerY - tickHeight / 2,
                    width: activeWidth,
                    height: tickHeight
                )
                context.fill(
                    Path(roundedRect: activeRect, cornerSize: CGSize(width: tickHeight / 2, height: tickHeight / 2)),
                    with: .color(color)
                )
            }

            let markerX = size.width * CGFloat(markerValue)
            let markerRect = CGRect(x: markerX - 1.5, y: centerY - 8, width: 3, height: 16)
            context.fill(
                Path(roundedRect: markerRect, cornerSize: CGSize(width: 1.5, height: 1.5)),
                with: .color(QuotaPopoverColors.marker)
            )
        }
        .frame(height: 18)
    }
}

private struct ScaleTick: Identifiable {
    let value: Double
    let label: String

    var id: Double {
        value
    }
}

enum QuotaPopoverColors {
    static let primaryText = Color(nsColor: .labelColor)
    static let titleText = Color(nsColor: .labelColor)
    static let mutedText = Color(nsColor: .secondaryLabelColor)
    static let scaleText = Color(nsColor: .tertiaryLabelColor)
    static let track = Color(nsColor: .tertiaryLabelColor).opacity(0.26)
    static let marker = Color(nsColor: .secondaryLabelColor)
    static let indigoText = Color.indigo
    static let indigoBackground = Color.indigo.opacity(0.13)
    static let indigoBorder = Color.indigo.opacity(0.5)
    static let menuSelectionBackground = Color.accentColor
    static let menuSelectionText = Color.white
}
