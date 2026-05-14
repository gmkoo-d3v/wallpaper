import AppKit

struct ControlPanelState {
    let isRunning: Bool
    let displayMode: DisplayMode
    let interactive: Bool
    let renderFps: Int
    let playbackRate: Float
    let fitMode: RenderFitMode
    let foregroundMode: ForegroundRenderMode
    let wallpaperPath: String
    let statusText: String
}

protocol ControlPanelDelegate: AnyObject {
    var controlPanelState: ControlPanelState { get }
    func controlPanelStart()
    func controlPanelStop()
    func controlPanelApply(
        displayMode: DisplayMode,
        interactive: Bool,
        renderFps: Int,
        playbackRate: Float,
        fitMode: RenderFitMode,
        foregroundMode: ForegroundRenderMode
    )
    func controlPanelQuit()
}

final class ControlPanelWindowController: NSWindowController {
    weak var delegate: ControlPanelDelegate?

    private let statusValue = NSTextField(labelWithString: "")
    private let pathValue = NSTextField(labelWithString: "")
    private let displayModeControl = NSSegmentedControl(
        labels: ["Primary", "All", "Only"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let interactionToggle = NSButton(checkboxWithTitle: "Desktop interaction", target: nil, action: nil)
    private let fpsControl = NSSegmentedControl(
        labels: ["30", "60", "120"],
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
        labels: ["Composite", "Native WIP"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let startButton = NSButton(title: "START", target: nil, action: nil)
    private let stopButton = NSButton(title: "STOP", target: nil, action: nil)
    private let applyButton = NSButton(title: "APPLY SETTINGS", target: nil, action: nil)
    private let quitButton = NSButton(title: "QUIT", target: nil, action: nil)

    init(delegate: ControlPanelDelegate) {
        self.delegate = delegate
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Wallpaper Engine"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.center()
        super.init(window: window)
        buildInterface()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPanel() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func refresh() {
        guard let state = delegate?.controlPanelState else { return }
        statusValue.stringValue = state.statusText
        pathValue.stringValue = state.wallpaperPath
        displayModeControl.selectedSegment = segment(for: state.displayMode)
        interactionToggle.state = state.interactive ? .on : .off
        fpsControl.selectedSegment = segment(forFps: state.renderFps)
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
        quitButton.target = self
        quitButton.action = #selector(quitApp)

        [startButton, applyButton].forEach(stylePrimaryButton)
        [stopButton, quitButton].forEach(styleSecondaryButton)
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
        stack.addArrangedSubview(infoRow(label: "BUNDLE", value: pathValue))
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

        row.addArrangedSubview(caption)
        row.addArrangedSubview(displayModeControl)
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

    private func segment(forFps fps: Int) -> Int {
        switch fps {
        case 30:
            return 0
        case 120:
            return 2
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
        foregroundMode == .nativeSpine ? 1 : 0
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

    private func selectedFps() -> Int {
        switch fpsControl.selectedSegment {
        case 0:
            return 30
        case 2:
            return 120
        default:
            return 60
        }
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
        foregroundModeControl.selectedSegment == 1 ? .nativeSpine : .compositeVideo
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
            interactive: interactionToggle.state == .on,
            renderFps: selectedFps(),
            playbackRate: selectedPlaybackRate(),
            fitMode: selectedFitMode(),
            foregroundMode: selectedForegroundMode()
        )
        refresh()
    }

    @objc private func quitApp() {
        delegate?.controlPanelQuit()
    }
}
