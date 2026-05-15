import AppKit

struct ControlPanelState {
    let isRunning: Bool
    let displayMode: DisplayMode
    let primaryDisplaySelector: String?
    let interactive: Bool
    let renderFps: Int
    let matchDisplayRefresh: Bool
    let playbackRate: Float
    let fitMode: RenderFitMode
    let foregroundMode: ForegroundRenderMode
    let wallpaperRoot: URL?
    let wallpaperPath: String
    let bundleInfoText: String
    let bundlePreviewURL: URL?
    let availableBundles: [WallpaperBundleSummary]
    let displaySelectionOptions: [DisplaySelectionOption]
    let bundleDiagnosticsText: String
    let renderPlanText: String
    let telemetryText: String
    let statusText: String
}

protocol ControlPanelDelegate: AnyObject {
    var controlPanelState: ControlPanelState { get }
    var controlPanelTelemetryText: String { get }
    func controlPanelStart()
    func controlPanelStop()
    func controlPanelApply(
        displayMode: DisplayMode,
        primaryDisplaySelector: String?,
        interactive: Bool,
        renderFps: Int,
        matchDisplayRefresh: Bool,
        playbackRate: Float,
        fitMode: RenderFitMode,
        foregroundMode: ForegroundRenderMode
    )
    func controlPanelChooseWallpaperBundle(_ url: URL)
    func controlPanelImportWallpaperBundle(_ url: URL)
    func controlPanelQuit()
}

final class ControlPanelWindowController: NSWindowController {
    static let displayModeLabels = ["Primary+Policy", "All Full", "Primary Only"]
    static let fpsLabels = ["30", "60", "Display Hz"]

    weak var delegate: ControlPanelDelegate?

    private let statusValue = NSTextField(labelWithString: "")
    private let pathValue = NSTextField(labelWithString: "")
    private let bundleInfoValue = NSTextField(labelWithString: "")
    private let bundleDiagnosticsValue = NSTextField(labelWithString: "")
    private let renderPlanValue = NSTextField(labelWithString: "")
    private let telemetryValue = NSTextField(labelWithString: "")
    private let previewImageView = NSImageView(frame: .zero)
    private let displayModeControl = NSSegmentedControl(
        labels: ControlPanelWindowController.displayModeLabels,
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let primaryDisplayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let interactionToggle = NSButton(checkboxWithTitle: "Desktop interaction", target: nil, action: nil)
    private let fpsControl = NSSegmentedControl(
        labels: ControlPanelWindowController.fpsLabels,
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let speedControl = NSSegmentedControl(
        labels: ["0.85x", "1.00x", "1.15x"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let fitModeControl = NSSegmentedControl(
        labels: ["Contain", "Fill"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let foregroundModeControl = NSSegmentedControl(
        labels: ["Auto", "Composite", "Native Spine"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let startButton = NSButton(title: "START", target: nil, action: nil)
    private let stopButton = NSButton(title: "STOP", target: nil, action: nil)
    private let applyButton = NSButton(title: "APPLY SETTINGS", target: nil, action: nil)
    private let chooseBundleButton = NSButton(title: "SELECT BUNDLE", target: nil, action: nil)
    private let importBundleButton = NSButton(title: "IMPORT BUNDLE", target: nil, action: nil)
    private let quitButton = NSButton(title: "QUIT", target: nil, action: nil)
    private let bundlePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var availableBundles: [WallpaperBundleSummary] = []
    private var displaySelectionOptions: [DisplaySelectionOption] = []
    private var refreshTimer: Timer?

    init(delegate: ControlPanelDelegate) {
        self.delegate = delegate
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 860, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Wallpaper Engine"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopRefreshTimer()
    }

    func showPanel() {
        refresh()
        startRefreshTimer()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func refresh() {
        guard let state = delegate?.controlPanelState else { return }
        statusValue.stringValue = state.statusText
        pathValue.stringValue = state.wallpaperPath
        bundleInfoValue.stringValue = state.bundleInfoText
        updatePreviewImage(state.bundlePreviewURL)
        bundleDiagnosticsValue.stringValue = state.bundleDiagnosticsText
        bundleDiagnosticsValue.isHidden = state.bundleDiagnosticsText.isEmpty
        renderPlanValue.stringValue = state.renderPlanText
        telemetryValue.stringValue = state.telemetryText
        availableBundles = state.availableBundles
        displaySelectionOptions = state.displaySelectionOptions
        reloadBundlePopup(currentRoot: state.wallpaperRoot)
        reloadPrimaryDisplayPopup(selector: state.primaryDisplaySelector)
        displayModeControl.selectedSegment = segment(for: state.displayMode)
        interactionToggle.state = state.interactive ? .on : .off
        fpsControl.selectedSegment = segment(forFps: state.renderFps, matchDisplayRefresh: state.matchDisplayRefresh)
        speedControl.selectedSegment = segment(forPlaybackRate: state.playbackRate)
        fitModeControl.selectedSegment = segment(forFitMode: state.fitMode)
        foregroundModeControl.selectedSegment = segment(forForegroundMode: state.foregroundMode)
        startButton.isEnabled = state.isRunning == false
        stopButton.isEnabled = state.isRunning
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.white.cgColor

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        root.addArrangedSubview(heroBand())
        root.addArrangedSubview(contentArea())

        startButton.target = self
        startButton.action = #selector(startWallpaper)
        stopButton.target = self
        stopButton.action = #selector(stopWallpaper)
        applyButton.target = self
        applyButton.action = #selector(applySettings)
        chooseBundleButton.target = self
        chooseBundleButton.action = #selector(chooseBundle)
        importBundleButton.target = self
        importBundleButton.action = #selector(importBundle)
        bundlePopup.target = self
        bundlePopup.action = #selector(selectLibraryBundle)
        quitButton.target = self
        quitButton.action = #selector(quitApp)

        [startButton, applyButton].forEach(stylePrimaryButton)
        [stopButton, chooseBundleButton, importBundleButton, quitButton].forEach(styleSecondaryButton)
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshTelemetry()
        }
    }

    private func refreshTelemetry() {
        guard let text = delegate?.controlPanelTelemetryText else { return }
        telemetryValue.stringValue = text
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func heroBand() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(red: 0.102, green: 0.129, blue: 0.161, alpha: 1).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let title = NSTextField(labelWithString: "Mac Wallpaper Engine")
        title.font = .systemFont(ofSize: 36, weight: .bold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "Native Metal wallpaper runtime")
        subtitle.font = .systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = NSColor(white: 0.74, alpha: 1)
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(title)
        view.addSubview(subtitle)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 34),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12)
        ])
        return view
    }

    private func contentArea() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        stack.addArrangedSubview(infoRow(label: "STATUS", value: statusValue))
        stack.addArrangedSubview(bundleRow())
        stack.addArrangedSubview(bundlePreviewRow())
        stack.addArrangedSubview(renderPlanRow())
        stack.addArrangedSubview(infoRow(label: "TELEMETRY", value: telemetryValue))
        stack.addArrangedSubview(modeRow())
        stack.addArrangedSubview(foregroundRow())
        stack.addArrangedSubview(renderRow())
        stack.addArrangedSubview(buttonRow())

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)
        ])
        return view
    }

    private func infoRow(label: String, value: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.spacing = 8

        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = NSColor(red: 0.42, green: 0.42, blue: 0.42, alpha: 1)
        value.font = .systemFont(ofSize: 14, weight: .light)
        value.textColor = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
        value.lineBreakMode = .byTruncatingMiddle

        row.addArrangedSubview(caption)
        row.addArrangedSubview(value)
        return row
    }

    private func bundleRow() -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.spacing = 8

        let caption = NSTextField(labelWithString: "BUNDLE")
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = NSColor(red: 0.42, green: 0.42, blue: 0.42, alpha: 1)

        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 12

        pathValue.font = .systemFont(ofSize: 14, weight: .light)
        pathValue.textColor = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
        pathValue.lineBreakMode = .byTruncatingMiddle
        pathValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bundleDiagnosticsValue.font = .systemFont(ofSize: 12, weight: .light)
        bundleDiagnosticsValue.textColor = NSColor(red: 0.65, green: 0.12, blue: 0.12, alpha: 1)
        bundleDiagnosticsValue.lineBreakMode = .byTruncatingMiddle
        bundleDiagnosticsValue.maximumNumberOfLines = 2
        bundlePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        chooseBundleButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        importBundleButton.widthAnchor.constraint(equalToConstant: 150).isActive = true

        line.addArrangedSubview(bundlePopup)
        line.addArrangedSubview(pathValue)
        line.addArrangedSubview(chooseBundleButton)
        line.addArrangedSubview(importBundleButton)
        row.addArrangedSubview(caption)
        row.addArrangedSubview(line)
        row.addArrangedSubview(bundleDiagnosticsValue)
        return row
    }

    private func bundlePreviewRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16

        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.backgroundColor = NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1).cgColor
        previewImageView.layer?.borderColor = NSColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1).cgColor
        previewImageView.layer?.borderWidth = 1
        previewImageView.widthAnchor.constraint(equalToConstant: 160).isActive = true
        previewImageView.heightAnchor.constraint(equalToConstant: 90).isActive = true

        let infoStack = NSStackView()
        infoStack.orientation = .vertical
        infoStack.spacing = 8

        let caption = self.caption("BUNDLE INFO")
        bundleInfoValue.font = .systemFont(ofSize: 13, weight: .light)
        bundleInfoValue.textColor = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
        bundleInfoValue.lineBreakMode = .byTruncatingTail
        bundleInfoValue.maximumNumberOfLines = 4
        bundleInfoValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        infoStack.addArrangedSubview(caption)
        infoStack.addArrangedSubview(bundleInfoValue)

        row.addArrangedSubview(previewImageView)
        row.addArrangedSubview(infoStack)
        return row
    }

    private func renderPlanRow() -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.spacing = 8

        let caption = self.caption("RENDER PLAN")
        renderPlanValue.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        renderPlanValue.textColor = NSColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1)
        renderPlanValue.lineBreakMode = .byTruncatingTail
        renderPlanValue.maximumNumberOfLines = 7

        row.addArrangedSubview(caption)
        row.addArrangedSubview(renderPlanValue)
        return row
    }

    private func modeRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18

        let caption = NSTextField(labelWithString: "DISPLAY MODE")
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = NSColor(red: 0.42, green: 0.42, blue: 0.42, alpha: 1)

        interactionToggle.font = .systemFont(ofSize: 13, weight: .regular)
        displayModeControl.segmentStyle = .texturedSquare
        displayModeControl.setToolTip("Primary display is full; secondary displays follow the manifest secondary policy.", forSegment: 0)
        displayModeControl.setToolTip("All displays render the full wallpaper; secondary displays remain passive.", forSegment: 1)
        displayModeControl.setToolTip("Only the primary display gets a wallpaper window.", forSegment: 2)
        primaryDisplayPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let primaryCaption = self.caption("PRIMARY")

        row.addArrangedSubview(caption)
        row.addArrangedSubview(displayModeControl)
        row.addArrangedSubview(primaryCaption)
        row.addArrangedSubview(primaryDisplayPopup)
        row.addArrangedSubview(interactionToggle)
        return row
    }

    private func foregroundRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18

        let foregroundCaption = caption("FOREGROUND")
        foregroundModeControl.segmentStyle = .texturedSquare

        row.addArrangedSubview(foregroundCaption)
        row.addArrangedSubview(foregroundModeControl)
        return row
    }

    private func renderRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18

        let fpsCaption = caption("FPS")
        let speedCaption = caption("SPEED")
        let fitCaption = caption("FIT")

        [fpsControl, speedControl, fitModeControl].forEach { control in
            control.segmentStyle = .texturedSquare
        }
        fpsControl.setToolTip("Render at fixed 30 FPS.", forSegment: 0)
        fpsControl.setToolTip("Render at fixed 60 FPS.", forSegment: 1)
        fpsControl.setToolTip("Match each monitor refresh rate for high-refresh displays.", forSegment: 2)

        row.addArrangedSubview(fpsCaption)
        row.addArrangedSubview(fpsControl)
        row.addArrangedSubview(speedCaption)
        row.addArrangedSubview(speedControl)
        row.addArrangedSubview(fitCaption)
        row.addArrangedSubview(fitModeControl)
        return row
    }

    private func buttonRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.addArrangedSubview(startButton)
        row.addArrangedSubview(stopButton)
        row.addArrangedSubview(applyButton)
        row.addArrangedSubview(quitButton)
        return row
    }

    private func stylePrimaryButton(_ button: NSButton) {
        button.bezelStyle = .regularSquare
        button.isBordered = true
        button.contentTintColor = NSColor(red: 0.11, green: 0.41, blue: 0.83, alpha: 1)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func styleSecondaryButton(_ button: NSButton) {
        button.bezelStyle = .regularSquare
        button.isBordered = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func segment(for mode: DisplayMode) -> Int {
        switch mode {
        case .primaryAnimated:
            return 0
        case .all:
            return 1
        case .primaryOnly:
            return 2
        }
    }

    private func segment(forFps fps: Int, matchDisplayRefresh: Bool) -> Int {
        if matchDisplayRefresh {
            return 2
        }
        switch fps {
        case 30:
            return 0
        default:
            return 1
        }
    }

    private func segment(forPlaybackRate playbackRate: Float) -> Int {
        if playbackRate < 0.93 {
            return 0
        }
        if playbackRate > 1.07 {
            return 2
        }
        return 1
    }

    private func segment(forFitMode fitMode: RenderFitMode) -> Int {
        fitMode == .fill ? 1 : 0
    }

    private func segment(forForegroundMode foregroundMode: ForegroundRenderMode) -> Int {
        switch foregroundMode {
        case .automatic:
            return 0
        case .compositeVideo:
            return 1
        case .nativeSpine:
            return 2
        }
    }

    private func reloadBundlePopup(currentRoot: URL?) {
        let selectedPath = currentRoot?.standardizedFileURL.resolvingSymlinksInPath().path
        bundlePopup.removeAllItems()

        guard availableBundles.isEmpty == false else {
            bundlePopup.addItem(withTitle: "No validated bundles")
            bundlePopup.isEnabled = false
            return
        }

        bundlePopup.isEnabled = true
        for bundle in availableBundles {
            bundlePopup.addItem(withTitle: "\(bundle.displayName) [\(bundle.capabilities.nativeSpineStatus)/\(bundle.capabilities.qualityStatus)]")
            bundlePopup.lastItem?.representedObject = bundle.root.path
        }

        if let selectedPath,
           let selectedItem = bundlePopup.itemArray.first(where: {
               guard let path = $0.representedObject as? String else { return false }
               return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == selectedPath
           }) {
            bundlePopup.select(selectedItem)
        }
    }

    private func reloadPrimaryDisplayPopup(selector: String?) {
        primaryDisplayPopup.removeAllItems()
        guard displaySelectionOptions.isEmpty == false else {
            primaryDisplayPopup.addItem(withTitle: "No displays")
            primaryDisplayPopup.isEnabled = false
            return
        }

        primaryDisplayPopup.isEnabled = true
        for option in displaySelectionOptions {
            primaryDisplayPopup.addItem(withTitle: option.title)
            primaryDisplayPopup.lastItem?.representedObject = option.selector
        }

        let normalizedSelector = selector?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let selectedItem = primaryDisplayPopup.itemArray.first(where: {
            guard let optionSelector = $0.representedObject as? String else {
                return normalizedSelector == nil || normalizedSelector?.isEmpty == true
            }
            return optionSelector.lowercased() == normalizedSelector
        }) {
            primaryDisplayPopup.select(selectedItem)
        } else if let selector,
                  selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            primaryDisplayPopup.addItem(withTitle: "Configured display unavailable: \(selector)")
            primaryDisplayPopup.lastItem?.representedObject = selector
            primaryDisplayPopup.select(primaryDisplayPopup.lastItem)
        } else {
            primaryDisplayPopup.selectItem(at: 0)
        }
    }

    private func updatePreviewImage(_ url: URL?) {
        guard let url, let image = NSImage(contentsOf: url) else {
            previewImageView.image = nil
            return
        }
        previewImageView.image = image
    }

    private func selectedDisplayMode() -> DisplayMode {
        switch displayModeControl.selectedSegment {
        case 1:
            return .all
        case 2:
            return .primaryOnly
        default:
            return .primaryAnimated
        }
    }

    private func selectedPrimaryDisplaySelector() -> String? {
        guard let selector = primaryDisplayPopup.selectedItem?.representedObject as? String else {
            return nil
        }
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func selectedFps() -> Int {
        switch fpsControl.selectedSegment {
        case 0:
            return 30
        default:
            return 60
        }
    }

    private func selectedMatchDisplayRefresh() -> Bool {
        fpsControl.selectedSegment == 2
    }

    private func selectedPlaybackRate() -> Float {
        switch speedControl.selectedSegment {
        case 0:
            return 0.85
        case 2:
            return 1.15
        default:
            return 1.0
        }
    }

    private func selectedFitMode() -> RenderFitMode {
        fitModeControl.selectedSegment == 1 ? .fill : .contain
    }

    private func selectedForegroundMode() -> ForegroundRenderMode {
        switch foregroundModeControl.selectedSegment {
        case 1:
            return .compositeVideo
        case 2:
            return .nativeSpine
        default:
            return .automatic
        }
    }

    private func caption(_ text: String) -> NSTextField {
        let caption = NSTextField(labelWithString: text)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = NSColor(red: 0.42, green: 0.42, blue: 0.42, alpha: 1)
        return caption
    }

    @objc private func startWallpaper() {
        delegate?.controlPanelStart()
        refresh()
    }

    @objc private func stopWallpaper() {
        delegate?.controlPanelStop()
        refresh()
    }

    @objc private func applySettings() {
        delegate?.controlPanelApply(
            displayMode: selectedDisplayMode(),
            primaryDisplaySelector: selectedPrimaryDisplaySelector(),
            interactive: interactionToggle.state == .on,
            renderFps: selectedFps(),
            matchDisplayRefresh: selectedMatchDisplayRefresh(),
            playbackRate: selectedPlaybackRate(),
            fitMode: selectedFitMode(),
            foregroundMode: selectedForegroundMode()
        )
        refresh()
    }

    @objc private func chooseBundle() {
        let panel = NSOpenPanel()
        panel.title = "Select Wallpaper Bundle"
        panel.message = "Choose a folder containing wallpaper.native.json"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            delegate?.controlPanelChooseWallpaperBundle(url)
        }
        refresh()
    }

    @objc private func importBundle() {
        let panel = NSOpenPanel()
        panel.title = "Import Wallpaper Bundle"
        panel.message = "Choose a bundle to copy into the user wallpaper library"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            delegate?.controlPanelImportWallpaperBundle(url)
        }
        refresh()
    }

    @objc private func selectLibraryBundle() {
        guard let path = bundlePopup.selectedItem?.representedObject as? String else { return }
        delegate?.controlPanelChooseWallpaperBundle(URL(fileURLWithPath: path))
        refresh()
    }

    @objc private func quitApp() {
        delegate?.controlPanelQuit()
    }
}

extension ControlPanelWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopRefreshTimer()
    }
}
