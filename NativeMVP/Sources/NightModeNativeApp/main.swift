import AppKit
import Foundation
import NightModeNativeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let engineController = AppEngineController()
    private var settingsWindowController: SettingsWindowController?
    private var refreshTimer: Timer?
    private var lastMenuStateSignature: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engineController.restorePersistedState()
        engineController.refreshDevicesAndMaybeAutoSwitch()
        engineController.startIfConfiguredOnLaunch()
        buildStatusItem()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.engineController.refreshDevicesAndMaybeAutoSwitch()
                if changed {
                    self.buildStatusItem()
                } else {
                    self.updateStatusButtonIfNeeded()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        engineController.stop()
    }

    private func buildStatusItem() {
        let signature = engineController.menuStateSignature
        if let statusItem {
            configureStatusButton(statusItem.button)
            if lastMenuStateSignature == signature {
                return
            }
            statusItem.menu = nil
        } else {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }

        guard let statusItem else { return }
        configureStatusButton(statusItem.button)

        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: engineController.isRunning ? "정지 (작동 중)" : "야간 모드 시작",
            action: #selector(toggleProcessing),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = engineController.isRunning ? .on : .off
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let statusMenuItem = NSMenuItem(title: engineController.statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        if let statusDetail = engineController.statusDetail {
            let detailItem = NSMenuItem(title: statusDetail, action: nil, keyEquivalent: "")
            detailItem.isEnabled = false
            menu.addItem(detailItem)
        }
        menu.addItem(.separator())

        let outputMenuItem = NSMenuItem(title: "출력 장치 선택", action: nil, keyEquivalent: "")
        let outputSubmenu = NSMenu()
        let autoTitle: String
        if let autoDevice = engineController.resolveAutoDevice() {
            autoTitle = "자동 출력 장치 (\(autoDevice.displayName))"
        } else {
            autoTitle = "자동 출력 장치"
        }

        let autoItem = NSMenuItem(title: autoTitle, action: #selector(selectAutoOutput), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = engineController.outputMode == .auto ? .on : .off
        outputSubmenu.addItem(autoItem)
        outputSubmenu.addItem(.separator())

        for device in engineController.availableOutputDevices() {
            let item = NSMenuItem(title: device.displayName, action: #selector(selectManualOutput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = engineController.outputMode == .manual && engineController.manualOutputUID == device.uid ? .on : .off
            outputSubmenu.addItem(item)
        }

        outputSubmenu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "목록 새로고침", action: #selector(refreshDevices), keyEquivalent: "r")
        refreshItem.target = self
        outputSubmenu.addItem(refreshItem)

        menu.setSubmenu(outputSubmenu, for: outputMenuItem)
        menu.addItem(outputMenuItem)

        let settingsItem = NSMenuItem(title: "설정 열기", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        lastMenuStateSignature = signature
    }

    private func updateStatusButtonIfNeeded() {
        guard let statusItem else { return }
        configureStatusButton(statusItem.button)
    }

    private func configureStatusButton(_ button: NSStatusBarButton?) {
        guard let button else { return }
        button.title = ""
        button.toolTip = "Night Mode Native"
        let imageName = engineController.isRunning ? "menu_icon_on.png" : "menu_icon.png"
        if let url = Bundle.module.url(forResource: imageName.replacingOccurrences(of: ".png", with: ""), withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            button.image = image
        } else {
            button.image = nil
            button.title = engineController.isRunning ? "On" : "Night"
        }
    }

    @objc
    private func toggleProcessing() {
        if engineController.isRunning {
            engineController.stop()
        } else {
            try? engineController.startForCurrentMode()
        }
        lastMenuStateSignature = nil
        buildStatusItem()
    }

    @objc
    private func selectAutoOutput() {
        engineController.setOutputMode(.auto)
        lastMenuStateSignature = nil
        buildStatusItem()
    }

    @objc
    private func selectManualOutput(_ sender: NSMenuItem) {
        guard let outputUID = sender.representedObject as? String else { return }
        engineController.selectManualOutput(uid: outputUID)
        lastMenuStateSignature = nil
        buildStatusItem()
    }

    @objc
    private func refreshDevices() {
        _ = engineController.refreshDevicesAndMaybeAutoSwitch(force: true)
        lastMenuStateSignature = nil
        buildStatusItem()
    }

    @objc
    private func openSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(engineController: engineController) { [weak self] in
                self?.buildStatusItem()
            }
        }
        settingsWindowController?.syncControls()
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func quitApp() {
        engineController.stop()
        NSApp.terminate(nil)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let engineController: AppEngineController
    private let onChange: () -> Void
    private var isSyncingControls = false

    private let outputModeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let thresholdControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gainControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let latencyControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoStartCheckbox = NSButton(checkboxWithTitle: "앱 시작 시 자동 시작", target: nil, action: nil)
    private let priorityScrollView = NSScrollView(frame: .zero)
    private let priorityTableView = NSTableView(frame: .zero)
    private let removeButton = NSButton(title: "제거", target: nil, action: nil)
    private let addButton = NSButton(title: "장치 추가", target: nil, action: nil)
    private let deviceContextLabel = NSTextField(labelWithString: "")
    private let activeDeviceContextLabel = NSTextField(labelWithString: "")
    private let editActiveButton = NSButton(title: "현재 장치 편집", target: nil, action: nil)
    private let applyAllButton = NSButton(title: "모든 장치에 적용", target: nil, action: nil)
    private let resetButton = NSButton(title: "선택 장치 리셋", target: nil, action: nil)
    private let inactiveEditWarningLabel = NSTextField(labelWithString: "⚠ 현재 이 장치로 듣고 있지 않습니다. 변경 사항이 지금 들리지 않을 수 있습니다.")
    private let prioritySectionLabel = NSTextField(labelWithString: "우선순위")
    private let priorityHintLabel = NSTextField(labelWithString: "위로 올릴수록 자동 전환 우선순위가 높습니다. 드래그해서 순서를 바꾸세요.")
    private let manualModeHintLabel = NSTextField(labelWithString: "수동 모드에서는 이 목록이 자동 전환에 사용되지 않습니다.")

    init(engineController: AppEngineController, onChange: @escaping () -> Void) {
        self.engineController = engineController
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Night Mode 설정"
        window.center()

        super.init(window: window)
        configureUI()
        syncControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func syncControls() {
        guard !isSyncingControls else { return }
        isSyncingControls = true
        defer { isSyncingControls = false }

        outputModeControl.selectItem(at: engineController.outputMode == .auto ? 0 : 1)

        switch engineController.editingThresholdDB {
        case -10.0: thresholdControl.selectItem(at: 0)
        case -30.0: thresholdControl.selectItem(at: 2)
        default: thresholdControl.selectItem(at: 1)
        }

        switch engineController.editingMakeupGainDB {
        case 0.0: gainControl.selectItem(at: 0)
        case 20.0: gainControl.selectItem(at: 2)
        default: gainControl.selectItem(at: 1)
        }

        let mode = engineController.editingLatencyMode
        latencyControl.selectItem(at: LatencyMode.allCases.firstIndex(of: mode) ?? 1)
        autoStartCheckbox.state = engineController.autoStartOnLaunch ? .on : .off
        deviceContextLabel.stringValue = engineController.editingDeviceSettingsTitle
        activeDeviceContextLabel.stringValue = engineController.activeDeviceTitle
        inactiveEditWarningLabel.isHidden = !engineController.isEditingInactiveDevice

        let known = engineController.knownDevicesDisplay()
        let selectedIndex = min(max(engineController.selectedKnownDeviceIndex, 0), max(known.count - 1, 0))
        priorityTableView.reloadData()
        if known.isEmpty {
            priorityTableView.deselectAll(nil)
        } else {
            priorityTableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }
        removeButton.isEnabled = selectedIndex >= 0 && !known.isEmpty
        addButton.isEnabled = !engineController.addableDevicesDisplay().isEmpty
        applyAllButton.isEnabled = engineController.editingDeviceUID != nil && !engineController.allConfigurableDeviceUIDs.isEmpty
        resetButton.isEnabled = engineController.editingDeviceUID != nil

        let autoModeEnabled = engineController.outputMode == .auto
        priorityTableView.alphaValue = 1.0
        priorityScrollView.alphaValue = 1.0
        prioritySectionLabel.alphaValue = 1.0
        priorityHintLabel.isHidden = !autoModeEnabled
        manualModeHintLabel.isHidden = autoModeEnabled
        editActiveButton.isEnabled = engineController.currentTargetUID != nil
    }

    private func configureUI() {
        guard let window else { return }

        outputModeControl.addItems(withTitles: OutputMode.allCases.map(\.title))
        outputModeControl.target = self
        outputModeControl.action = #selector(changeOutputMode)

        thresholdControl.addItems(withTitles: ["약하게 (-10dB)", "보통 (-20dB)", "강하게 (-30dB)"])
        thresholdControl.target = self
        thresholdControl.action = #selector(changeThreshold)

        gainControl.addItems(withTitles: ["낮게 (0dB)", "보통 (+10dB)", "높게 (+20dB)"])
        gainControl.target = self
        gainControl.action = #selector(changeGain)

        latencyControl.addItems(withTitles: LatencyMode.allCases.map(\.title))
        latencyControl.target = self
        latencyControl.action = #selector(changeLatencyMode)

        autoStartCheckbox.target = self
        autoStartCheckbox.action = #selector(toggleAutoStart)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("priority"))
        column.title = "장치 우선순위"
        column.width = 300
        priorityTableView.addTableColumn(column)
        priorityTableView.headerView = nil
        priorityTableView.rowHeight = 24
        priorityTableView.intercellSpacing = NSSize(width: 0, height: 4)
        priorityTableView.usesAlternatingRowBackgroundColors = true
        priorityTableView.allowsEmptySelection = true
        priorityTableView.delegate = self
        priorityTableView.dataSource = self
        priorityTableView.target = self
        priorityTableView.doubleAction = #selector(selectKnownDevice)
        priorityTableView.registerForDraggedTypes([.string])
        priorityTableView.setDraggingSourceOperationMask(.move, forLocal: true)

        priorityScrollView.documentView = priorityTableView
        priorityScrollView.hasVerticalScroller = false
        priorityScrollView.hasHorizontalScroller = false
        priorityScrollView.borderType = .bezelBorder
        removeButton.target = self
        removeButton.action = #selector(removeKnownDevice)
        addButton.target = self
        addButton.action = #selector(showAddDeviceMenu(_:))
        editActiveButton.target = self
        editActiveButton.action = #selector(selectActiveDeviceForEditing)
        applyAllButton.target = self
        applyAllButton.action = #selector(applyEditingSettingsToAllDevices)
        resetButton.target = self
        resetButton.action = #selector(resetEditingDeviceSettings)

        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        addSectionLabel("오디오 처리", to: contentView, x: 24, y: 424)
        configureSecondaryLabel(deviceContextLabel, x: 170, y: 426, width: 360)
        deviceContextLabel.alignment = .right
        contentView.addSubview(deviceContextLabel)
        configureSecondaryLabel(activeDeviceContextLabel, x: 170, y: 408, width: 360)
        activeDeviceContextLabel.alignment = .right
        contentView.addSubview(activeDeviceContextLabel)
        configureSecondaryLabel(inactiveEditWarningLabel, x: 170, y: 364, width: 386)
        inactiveEditWarningLabel.textColor = .systemOrange
        inactiveEditWarningLabel.alignment = .right
        contentView.addSubview(inactiveEditWarningLabel)
        editActiveButton.frame = NSRect(x: 452, y: 382, width: 104, height: 24)
        contentView.addSubview(editActiveButton)
        addLabel("압축 강도", to: contentView, x: 24, y: 388)
        thresholdControl.frame = NSRect(x: 170, y: 382, width: 220, height: 28)
        contentView.addSubview(thresholdControl)

        addLabel("볼륨 증폭", to: contentView, x: 24, y: 348)
        gainControl.frame = NSRect(x: 170, y: 342, width: 220, height: 28)
        contentView.addSubview(gainControl)

        addLabel("지연 모드", to: contentView, x: 24, y: 308)
        latencyControl.frame = NSRect(x: 170, y: 302, width: 220, height: 28)
        contentView.addSubview(latencyControl)
        applyAllButton.frame = NSRect(x: 170, y: 264, width: 110, height: 28)
        resetButton.frame = NSRect(x: 282, y: 264, width: 110, height: 28)
        contentView.addSubview(applyAllButton)
        contentView.addSubview(resetButton)

        addSectionLabel("출력 로직", to: contentView, x: 24, y: 256)
        addLabel("출력 장치 모드", to: contentView, x: 24, y: 220)
        outputModeControl.frame = NSRect(x: 170, y: 214, width: 220, height: 28)
        contentView.addSubview(outputModeControl)

        autoStartCheckbox.frame = NSRect(x: 24, y: 182, width: 220, height: 24)
        contentView.addSubview(autoStartCheckbox)

        configureSectionLabel(prioritySectionLabel, x: 24, y: 144)
        contentView.addSubview(prioritySectionLabel)
        configureSecondaryLabel(priorityHintLabel, x: 24, y: 122, width: 490)
        contentView.addSubview(priorityHintLabel)
        configureSecondaryLabel(manualModeHintLabel, x: 24, y: 122, width: 490)
        contentView.addSubview(manualModeHintLabel)
        priorityScrollView.frame = NSRect(x: 24, y: 24, width: 420, height: 86)
        contentView.addSubview(priorityScrollView)
        removeButton.frame = NSRect(x: 456, y: 66, width: 100, height: 28)
        addButton.frame = NSRect(x: 456, y: 28, width: 100, height: 28)
        contentView.addSubview(removeButton)
        contentView.addSubview(addButton)

        window.contentView = contentView
    }

    private func addSectionLabel(_ text: String, to view: NSView, x: CGFloat, y: CGFloat) {
        let label = NSTextField(labelWithString: text)
        configureSectionLabel(label, x: x, y: y)
        view.addSubview(label)
    }

    private func addLabel(_ text: String, to view: NSView, x: CGFloat, y: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: x, y: y, width: 120, height: 24)
        view.addSubview(label)
    }

    private func addSecondaryLabel(_ text: String, to view: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
        let label = NSTextField(labelWithString: text)
        configureSecondaryLabel(label, x: x, y: y, width: width)
        view.addSubview(label)
    }

    private func configureSectionLabel(_ label: NSTextField, x: CGFloat, y: CGFloat) {
        label.font = .boldSystemFont(ofSize: 13)
        label.frame = NSRect(x: x, y: y, width: 140, height: 22)
    }

    private func configureSecondaryLabel(_ label: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat) {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: x, y: y, width: width, height: 18)
    }

    @objc
    private func changeOutputMode() {
        let mode: OutputMode = outputModeControl.indexOfSelectedItem == 0 ? .auto : .manual
        engineController.setOutputMode(mode)
        syncControls()
        onChange()
    }

    @objc
    private func changeThreshold() {
        let value: Float
        switch thresholdControl.indexOfSelectedItem {
        case 0: value = -10.0
        case 2: value = -30.0
        default: value = -20.0
        }
        engineController.setEditingThreshold(value)
        syncControls()
        onChange()
    }

    @objc
    private func changeGain() {
        let value: Float
        switch gainControl.indexOfSelectedItem {
        case 0: value = 0.0
        case 2: value = 20.0
        default: value = 10.0
        }
        engineController.setEditingMakeupGain(value)
        syncControls()
        onChange()
    }

    @objc
    private func changeLatencyMode() {
        let mode = LatencyMode.allCases[max(0, latencyControl.indexOfSelectedItem)]
        engineController.setEditingLatencyMode(mode)
        syncControls()
        onChange()
    }

    @objc
    private func toggleAutoStart() {
        engineController.autoStartOnLaunch = autoStartCheckbox.state == .on
        syncControls()
        onChange()
    }

    @objc
    private func selectKnownDevice() {
        engineController.selectedKnownDeviceIndex = priorityTableView.selectedRow
        syncControls()
    }

    @objc
    private func removeKnownDevice() {
        engineController.removeSelectedKnownDevice()
        syncControls()
        onChange()
    }

    @objc
    private func showAddDeviceMenu(_ sender: NSButton) {
        let addable = engineController.addableDevicesDisplay()
        guard !addable.isEmpty else { return }

        let menu = NSMenu()
        for item in addable {
            let menuItem = NSMenuItem(title: item.title, action: #selector(addKnownDeviceFromMenu(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.uid
            menu.addItem(menuItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc
    private func addKnownDeviceFromMenu(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        engineController.addKnownDevice(uid: uid)
        syncControls()
        onChange()
    }

    @objc
    private func applyEditingSettingsToAllDevices() {
        let alert = NSAlert()
        alert.messageText = "모든 장치에 적용"
        alert.informativeText = "현재 편집 중인 장치의 압축 강도, 볼륨 증폭, 지연 모드를 다른 모든 알려진 장치에 덮어씁니다."
        alert.alertStyle = .warning
        let applyButton = alert.addButton(withTitle: "적용")
        alert.addButton(withTitle: "취소")
        if #available(macOS 11.0, *) {
            applyButton.hasDestructiveAction = true
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        engineController.applyEditingSettingsToAllDevices()
        syncControls()
        onChange()
    }

    @objc
    private func resetEditingDeviceSettings() {
        engineController.resetEditingDeviceSettings()
        syncControls()
        onChange()
    }

    @objc
    private func selectActiveDeviceForEditing() {
        engineController.selectCurrentTargetForEditing()
        syncControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        engineController.knownDevicesDisplay().count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = engineController.knownDevicesDisplay()[row]
        let identifier = NSUserInterfaceItemIdentifier("PriorityCell")
        let container: NSTableCellView

        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            container = cell
        } else {
            container = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
            container.identifier = identifier

            let grabber = NSTextField(labelWithString: "≡")
            grabber.identifier = NSUserInterfaceItemIdentifier("grabber")
            grabber.font = .systemFont(ofSize: 12, weight: .medium)
            grabber.textColor = .secondaryLabelColor
            grabber.alignment = .center
            grabber.frame = NSRect(x: 6, y: 3, width: 16, height: 18)
            container.addSubview(grabber)

            let iconView = NSImageView(frame: NSRect(x: 28, y: 3, width: 16, height: 16))
            iconView.identifier = NSUserInterfaceItemIdentifier("icon")
            container.addSubview(iconView)

            let textField = NSTextField(labelWithString: "")
            textField.identifier = NSUserInterfaceItemIdentifier("title")
            textField.lineBreakMode = .byTruncatingMiddle
            textField.frame = NSRect(x: 50, y: 2, width: 210, height: 18)
            container.addSubview(textField)

            let badgeField = NSTextField(labelWithString: "")
            badgeField.identifier = NSUserInterfaceItemIdentifier("badge")
            badgeField.font = .systemFont(ofSize: 10, weight: .semibold)
            badgeField.alignment = .center
            badgeField.textColor = .systemBlue
            badgeField.frame = NSRect(x: 264, y: 2, width: 62, height: 18)
            container.addSubview(badgeField)
        }

        let titleField = container.subviews.first { $0.identifier == NSUserInterfaceItemIdentifier("title") } as? NSTextField
        let iconView = container.subviews.first { $0.identifier == NSUserInterfaceItemIdentifier("icon") } as? NSImageView
        let badgeField = container.subviews.first { $0.identifier == NSUserInterfaceItemIdentifier("badge") } as? NSTextField
        let grabberField = container.subviews.first { $0.identifier == NSUserInterfaceItemIdentifier("grabber") } as? NSTextField

        titleField?.stringValue = "\(row + 1). \(item.title)"
        titleField?.textColor = item.title.hasSuffix("연결 안 됨") ? .secondaryLabelColor : .labelColor
        iconView?.image = iconImage(for: item.title)
        iconView?.contentTintColor = item.title.hasSuffix("연결 안 됨") ? .secondaryLabelColor : .tertiaryLabelColor
        grabberField?.textColor = engineController.outputMode == .auto ? .secondaryLabelColor : .quaternaryLabelColor
        let isActive = item.uid == engineController.currentTargetUID
        badgeField?.stringValue = isActive ? "사용 중" : ""
        badgeField?.isHidden = !isActive
        return container
    }

    private func iconImage(for title: String) -> NSImage? {
        let lowerTitle = title.lowercased()
        let symbolName: String
        if lowerTitle.contains("airpods") {
            symbolName = "airpods"
        } else if lowerTitle.contains("headphone") || lowerTitle.contains("헤드폰") || lowerTitle.contains("ear") {
            symbolName = "headphones"
        } else if lowerTitle.contains("display") || lowerTitle.contains("hdmi") {
            symbolName = "display"
        } else {
            symbolName = "speaker.wave.2"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingControls else { return }
        let known = engineController.knownDevicesDisplay()
        engineController.selectedKnownDeviceIndex = priorityTableView.selectedRow

        let selectedKnownIndex = priorityTableView.selectedRow
        removeButton.isEnabled = selectedKnownIndex >= 0 && !known.isEmpty
        addButton.isEnabled = !engineController.addableDevicesDisplay().isEmpty
        syncControls()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        NSString(string: String(row))
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard
            let value = info.draggingPasteboard.string(forType: .string),
            let fromIndex = Int(value)
        else {
            return false
        }

        let insertionIndex = row > fromIndex ? row - 1 : row
        guard engineController.moveKnownDevice(from: fromIndex, to: insertionIndex) else {
            return false
        }

        syncControls()
        onChange()
        return true
    }
}

@MainActor
final class AppEngineController {
    private enum DefaultsKey {
        static let manualOutputUID = "night_mode_native.manual_output_uid"
        static let outputMode = "night_mode_native.output_mode"
        static let latencyModes = "night_mode_native.latency_modes"
        static let outputVolumes = "night_mode_native.output_volumes"
        static let autoStartOnLaunch = "night_mode_native.auto_start_on_launch"
        static let thresholds = "night_mode_native.thresholds"
        static let makeupGains = "night_mode_native.makeup_gains"
        static let shouldAutoStartProcessing = "night_mode_native.should_auto_start_processing"
        static let recentConnected = "night_mode_native.recent_connected"
        static let lastSuccessUID = "night_mode_native.last_success_uid"
        static let knownDeviceOrder = "night_mode_native.known_device_order"
        static let excludedKnownDeviceOrder = "night_mode_native.excluded_known_device_order"
        static let knownDeviceNames = "night_mode_native.known_device_names"
    }

    private var engine: PassThroughEngine?
    private(set) var devices: [AudioDevice] = []
    private var previousAvailableUIDs: Set<String> = []
    private var recentConnected: [String] = []
    private var lastSuccessUID: String?
    private var knownDeviceOrder: [String] = []
    private var excludedKnownDeviceOrder: [String] = []
    private var knownDeviceNames: [String: String] = [:]
    var selectedKnownDeviceIndex: Int = 0

    private(set) var manualOutputUID: String? = UserDefaults.standard.string(forKey: DefaultsKey.manualOutputUID)
    private(set) var outputMode: OutputMode = OutputMode(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.outputMode) ?? "") ?? .auto
    private var latencyModesByOutputUID: [String: String] = UserDefaults.standard.dictionary(forKey: DefaultsKey.latencyModes) as? [String: String] ?? [:]
    private var outputVolumesByUID: [String: Float] = UserDefaults.standard.dictionary(forKey: DefaultsKey.outputVolumes) as? [String: Float] ?? [:]
    private var thresholdsByOutputUID: [String: Float] = UserDefaults.standard.dictionary(forKey: DefaultsKey.thresholds) as? [String: Float] ?? [:]
    private var makeupGainsByOutputUID: [String: Float] = UserDefaults.standard.dictionary(forKey: DefaultsKey.makeupGains) as? [String: Float] ?? [:]
    var autoStartOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.autoStartOnLaunch) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.autoStartOnLaunch) }
    }
    private var shouldAutoStartProcessing: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.shouldAutoStartProcessing)
    private(set) var statusDetail: String?

    var isRunning: Bool { engine != nil }

    var statusTitle: String {
        isRunning ? "상태: 작동 중" : "상태: 대기 중"
    }

    var currentLatencyMode: LatencyMode {
        if let uid = currentTargetUID {
            return latencyMode(for: uid)
        }
        return .balanced
    }

    var thresholdDB: Float {
        if let uid = currentTargetUID {
            return threshold(for: uid)
        }
        return -20.0
    }

    var makeupGainDB: Float {
        if let uid = currentTargetUID {
            return makeupGain(for: uid)
        }
        return 10.0
    }

    var currentTargetUID: String? {
        outputMode == .auto ? resolveAutoDevice()?.uid : manualOutputUID
    }

    var editingDeviceUID: String? {
        if selectedKnownDeviceIndex >= 0, selectedKnownDeviceIndex < knownDeviceOrder.count {
            return knownDeviceOrder[selectedKnownDeviceIndex]
        }
        return currentTargetUID
    }

    var editingLatencyMode: LatencyMode {
        if let uid = editingDeviceUID {
            return latencyMode(for: uid)
        }
        return .balanced
    }

    var editingThresholdDB: Float {
        if let uid = editingDeviceUID {
            return threshold(for: uid)
        }
        return -20.0
    }

    var editingMakeupGainDB: Float {
        if let uid = editingDeviceUID {
            return makeupGain(for: uid)
        }
        return 10.0
    }

    var editingDeviceSettingsTitle: String {
        if let device = getDevice(editingDeviceUID) {
            return "\(device.displayName) 설정"
        }
        if let uid = editingDeviceUID {
            return "\((knownDeviceNames[uid] ?? uid)) 설정"
        }
        return "편집 장치 없음"
    }

    var activeDeviceTitle: String {
        if let device = getDevice(currentTargetUID) {
            return "현재 사용: \(device.displayName)"
        }
        return "현재 사용 장치 없음"
    }

    var isEditingInactiveDevice: Bool {
        guard let editingUID = editingDeviceUID, let activeUID = currentTargetUID else { return false }
        return editingUID != activeUID
    }

    var allConfigurableDeviceUIDs: [String] {
        Array(Set(knownDeviceOrder + excludedKnownDeviceOrder)).sorted { lhs, rhs in
            let lhsName = knownDeviceNames[lhs] ?? lhs
            let rhsName = knownDeviceNames[rhs] ?? rhs
            return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
        }
    }

    var menuStateSignature: String {
        let devicePart = devices.map(\.uid).joined(separator: "|")
        return [
            isRunning ? "1" : "0",
            outputMode.rawValue,
            manualOutputUID ?? "",
            currentTargetUID ?? "",
            statusDetail ?? "",
            devicePart,
        ].joined(separator: "::")
    }

    func restorePersistedState() {
        recentConnected = UserDefaults.standard.stringArray(forKey: DefaultsKey.recentConnected) ?? []
        lastSuccessUID = UserDefaults.standard.string(forKey: DefaultsKey.lastSuccessUID)
        knownDeviceOrder = UserDefaults.standard.stringArray(forKey: DefaultsKey.knownDeviceOrder) ?? []
        excludedKnownDeviceOrder = UserDefaults.standard.stringArray(forKey: DefaultsKey.excludedKnownDeviceOrder) ?? []
        knownDeviceNames = UserDefaults.standard.dictionary(forKey: DefaultsKey.knownDeviceNames) as? [String: String] ?? [:]
        refreshDeviceCache()
        if manualOutputUID != nil && getDevice(manualOutputUID) == nil {
            manualOutputUID = nil
            UserDefaults.standard.removeObject(forKey: DefaultsKey.manualOutputUID)
        }
        statusDetail = currentTargetUID != nil ? "준비됨" : "사용 가능한 출력 장치 없음"
    }

    func availableOutputDevices() -> [AudioDevice] {
        devices
    }

    func resolveAutoDevice() -> AudioDevice? {
        guard !devices.isEmpty else { return nil }
        let byUID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })

        for uid in knownDeviceOrder {
            if let device = byUID[uid] { return device }
        }

        for uid in recentConnected {
            if let device = byUID[uid] { return device }
        }

        if let lastSuccessUID, let device = byUID[lastSuccessUID] {
            return device
        }

        if let builtIn = devices.first(where: \.isBuiltIn) {
            return builtIn
        }

        return devices.first
    }

    func getDevice(_ uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    func startIfConfiguredOnLaunch() {
        guard shouldAutoStartProcessing else { return }
        try? startForCurrentMode()
    }

    func startForCurrentMode() throws {
        switch outputMode {
        case .auto:
            guard let target = resolveAutoDevice() else {
                statusDetail = "자동 출력 장치 없음"
                return
            }
            try start(target: target)
        case .manual:
            guard let target = getDevice(manualOutputUID) else {
                statusDetail = "수동 출력 장치 없음"
                return
            }
            try start(target: target)
        }
    }

    func selectManualOutput(uid: String) {
        manualOutputUID = uid
        UserDefaults.standard.set(uid, forKey: DefaultsKey.manualOutputUID)
        setOutputMode(.manual)
        try? startForCurrentMode()
    }

    func setOutputMode(_ mode: OutputMode) {
        outputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.outputMode)
        if isRunning {
            try? startForCurrentMode()
        } else {
            statusDetail = mode == .auto ? "자동 모드" : "수동 모드"
        }
    }

    @discardableResult
    func refreshDevicesAndMaybeAutoSwitch(force: Bool = false) -> Bool {
        let previousSignature = menuStateSignature
        captureCurrentOutputVolume()
        refreshDeviceCache()
        _ = ensureBlackHoleAsSystemOutput()

        if outputMode == .auto, isRunning {
            let resolvedUID = resolveAutoDevice()?.uid
            if force || (resolvedUID != nil && resolvedUID != lastSuccessUID) {
                try? startForCurrentMode()
            }
        }

        if outputMode == .manual, isRunning, getDevice(manualOutputUID) == nil {
            stop()
            statusDetail = "선택한 장치가 사라져 중지됨"
        }
        return previousSignature != menuStateSignature
    }

    func stop() {
        captureCurrentOutputVolume()
        engine?.stop()
        engine = nil
        shouldAutoStartProcessing = false
        UserDefaults.standard.set(false, forKey: DefaultsKey.shouldAutoStartProcessing)
        statusDetail = "중지됨"
    }

    func latencyMode(for outputUID: String) -> LatencyMode {
        guard let raw = latencyModesByOutputUID[outputUID], let mode = LatencyMode(rawValue: raw) else {
            return .balanced
        }
        return mode
    }

    func threshold(for outputUID: String) -> Float {
        thresholdsByOutputUID[outputUID] ?? -20.0
    }

    func makeupGain(for outputUID: String) -> Float {
        makeupGainsByOutputUID[outputUID] ?? 10.0
    }

    func setEditingLatencyMode(_ mode: LatencyMode) {
        guard let uid = editingDeviceUID else { return }
        setLatencyMode(mode, for: uid)
        if isRunning, uid == currentTargetUID {
            try? startForCurrentMode()
        }
    }

    func setLatencyMode(_ mode: LatencyMode, for outputUID: String) {
        latencyModesByOutputUID[outputUID] = mode.rawValue
        UserDefaults.standard.set(latencyModesByOutputUID, forKey: DefaultsKey.latencyModes)
        statusDetail = "지연 모드: \(mode.title)"
    }

    func knownDevicesDisplay() -> [(uid: String, title: String)] {
        knownDeviceOrder.map { uid in
            let name = knownDeviceNames[uid] ?? uid
            let connected = getDevice(uid) != nil
            return (uid, "\(name) \(connected ? "연결됨" : "연결 안 됨")")
        }
    }

    func addableDevicesDisplay() -> [(uid: String, title: String)] {
        excludedKnownDeviceOrder.map { uid in
            let name = knownDeviceNames[uid] ?? uid
            let connected = getDevice(uid) != nil
            return (uid, "\(name) \(connected ? "연결됨" : "연결 안 됨")")
        }
    }

    @discardableResult
    func moveKnownDevice(from sourceIndex: Int, to destinationIndex: Int) -> Bool {
        guard
            sourceIndex >= 0,
            sourceIndex < knownDeviceOrder.count,
            destinationIndex >= 0,
            destinationIndex < knownDeviceOrder.count,
            sourceIndex != destinationIndex
        else {
            return false
        }

        let uid = knownDeviceOrder.remove(at: sourceIndex)
        knownDeviceOrder.insert(uid, at: destinationIndex)
        selectedKnownDeviceIndex = destinationIndex
        persistSelectorState()
        return true
    }

    func removeSelectedKnownDevice() {
        guard selectedKnownDeviceIndex >= 0, selectedKnownDeviceIndex < knownDeviceOrder.count else { return }
        let uid = knownDeviceOrder.remove(at: selectedKnownDeviceIndex)
        excludedKnownDeviceOrder.removeAll { $0 == uid }
        excludedKnownDeviceOrder.insert(uid, at: 0)
        if manualOutputUID == uid {
            manualOutputUID = nil
            UserDefaults.standard.removeObject(forKey: DefaultsKey.manualOutputUID)
        }
        selectedKnownDeviceIndex = min(selectedKnownDeviceIndex, max(knownDeviceOrder.count - 1, 0))
        persistSelectorState()
    }

    func addKnownDevice(uid: String) {
        guard let addIndex = excludedKnownDeviceOrder.firstIndex(of: uid) else { return }
        excludedKnownDeviceOrder.remove(at: addIndex)
        knownDeviceOrder.append(uid)
        selectedKnownDeviceIndex = max(knownDeviceOrder.count - 1, 0)
        persistSelectorState()
    }

    func selectCurrentTargetForEditing() {
        guard let uid = currentTargetUID else { return }
        if let index = knownDeviceOrder.firstIndex(of: uid) {
            selectedKnownDeviceIndex = index
        }
    }

    func setEditingThreshold(_ value: Float) {
        guard let uid = editingDeviceUID else { return }
        thresholdsByOutputUID[uid] = value
        UserDefaults.standard.set(thresholdsByOutputUID, forKey: DefaultsKey.thresholds)
        if uid == currentTargetUID {
            engine?.configureDynamics(thresholdDB: threshold(for: uid), makeupGainDB: makeupGain(for: uid), ratio: 4.0)
        }
        statusDetail = "압축 강도: \(Int(value))dB"
    }

    func setEditingMakeupGain(_ value: Float) {
        guard let uid = editingDeviceUID else { return }
        makeupGainsByOutputUID[uid] = value
        UserDefaults.standard.set(makeupGainsByOutputUID, forKey: DefaultsKey.makeupGains)
        if uid == currentTargetUID {
            engine?.configureDynamics(thresholdDB: threshold(for: uid), makeupGainDB: makeupGain(for: uid), ratio: 4.0)
        }
        statusDetail = "볼륨 증폭: \(Int(value))dB"
    }

    func applyEditingSettingsToAllDevices() {
        guard let sourceUID = editingDeviceUID else { return }
        let sourceLatency = latencyMode(for: sourceUID)
        let sourceThreshold = threshold(for: sourceUID)
        let sourceGain = makeupGain(for: sourceUID)

        for uid in allConfigurableDeviceUIDs {
            latencyModesByOutputUID[uid] = sourceLatency.rawValue
            thresholdsByOutputUID[uid] = sourceThreshold
            makeupGainsByOutputUID[uid] = sourceGain
        }

        UserDefaults.standard.set(latencyModesByOutputUID, forKey: DefaultsKey.latencyModes)
        UserDefaults.standard.set(thresholdsByOutputUID, forKey: DefaultsKey.thresholds)
        UserDefaults.standard.set(makeupGainsByOutputUID, forKey: DefaultsKey.makeupGains)

        if isRunning, let activeUID = currentTargetUID {
            engine?.configureDynamics(thresholdDB: threshold(for: activeUID), makeupGainDB: makeupGain(for: activeUID), ratio: 4.0)
            try? startForCurrentMode()
        }
        statusDetail = "현재 편집 설정을 모든 장치에 적용"
    }

    func resetEditingDeviceSettings() {
        guard let uid = editingDeviceUID else { return }
        latencyModesByOutputUID.removeValue(forKey: uid)
        thresholdsByOutputUID.removeValue(forKey: uid)
        makeupGainsByOutputUID.removeValue(forKey: uid)
        UserDefaults.standard.set(latencyModesByOutputUID, forKey: DefaultsKey.latencyModes)
        UserDefaults.standard.set(thresholdsByOutputUID, forKey: DefaultsKey.thresholds)
        UserDefaults.standard.set(makeupGainsByOutputUID, forKey: DefaultsKey.makeupGains)

        if isRunning, uid == currentTargetUID {
            engine?.configureDynamics(thresholdDB: threshold(for: uid), makeupGainDB: makeupGain(for: uid), ratio: 4.0)
            try? startForCurrentMode()
        }
        statusDetail = "선택 장치 설정 리셋"
    }

    private func start(target: AudioDevice) throws {
        captureCurrentOutputVolume()
        stopEngineOnly()
        guard let inputDevice = findBlackHoleDevice() else {
            throw PassThroughError.blackHoleMissing
        }
        let blackHoleRecovered = ensureBlackHoleAsSystemOutput()
        let engine = try PassThroughEngine(
            inputDeviceID: inputDevice.id,
            outputDeviceID: target.id,
            latencyMode: latencyMode(for: target.uid),
            thresholdDB: threshold(for: target.uid),
            makeupGainDB: makeupGain(for: target.uid)
        )
        try engine.start()
        self.engine = engine
        applyStoredOutputVolume(to: target)
        shouldAutoStartProcessing = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.shouldAutoStartProcessing)
        lastSuccessUID = target.uid
        noteConnected(target.uid)
        persistSelectorState()
        if blackHoleRecovered {
            statusDetail = "출력: \(target.displayName) / \(latencyMode(for: target.uid).title)"
        } else {
            statusDetail = "출력: \(target.displayName) / BlackHole 기본 출력 확인 필요"
        }
    }

    private func stopEngineOnly() {
        engine?.stop()
        engine = nil
    }

    private func refreshDeviceCache() {
        let outputs = listDevices()
            .filter { $0.hasOutput && !$0.isVirtual }
            .sorted { lhs, rhs in
                if lhs.isBuiltIn != rhs.isBuiltIn {
                    return lhs.isBuiltIn
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }

        let availableUIDs = Set(outputs.map(\.uid))
        let newUIDs = availableUIDs.subtracting(previousAvailableUIDs)
        for uid in newUIDs {
            noteConnected(uid)
        }
        previousAvailableUIDs = availableUIDs
        recentConnected.removeAll { !availableUIDs.contains($0) }
        if let lastSuccessUID, !availableUIDs.contains(lastSuccessUID) {
            self.lastSuccessUID = nil
        }
        for device in outputs {
            knownDeviceNames[device.uid] = device.displayName
            if !knownDeviceOrder.contains(device.uid) && !excludedKnownDeviceOrder.contains(device.uid) {
                knownDeviceOrder.append(device.uid)
            }
        }
        devices = outputs
        persistSelectorState()
    }

    private func noteConnected(_ uid: String) {
        recentConnected.removeAll { $0 == uid }
        recentConnected.insert(uid, at: 0)
        if recentConnected.count > 10 {
            recentConnected = Array(recentConnected.prefix(10))
        }
    }

    private func findBlackHoleDevice() -> AudioDevice? {
        listDevices().first { $0.hasInput && $0.hasOutput && $0.name.contains("BlackHole") }
    }

    @discardableResult
    private func ensureBlackHoleAsSystemOutput() -> Bool {
        guard isRunning || shouldAutoStartProcessing else { return true }
        guard let blackHole = findBlackHoleDevice() else {
            statusDetail = "BlackHole 장치를 찾지 못했습니다"
            return false
        }

        if readDefaultOutputDeviceID() == blackHole.id {
            return true
        }

        let restored = setDefaultOutputDeviceID(blackHole.id)
        if !restored {
            statusDetail = "시스템 출력을 BlackHole로 복구하지 못했습니다"
        }
        return restored
    }

    private func captureCurrentOutputVolume() {
        guard let uid = currentTargetUID, let device = getDevice(uid) else { return }
        guard let volume = readOutputVolumeScalar(deviceID: device.id) else { return }
        outputVolumesByUID[uid] = volume
        UserDefaults.standard.set(outputVolumesByUID, forKey: DefaultsKey.outputVolumes)
    }

    private func applyStoredOutputVolume(to device: AudioDevice) {
        if let storedVolume = outputVolumesByUID[device.uid] {
            _ = setOutputVolumeScalar(deviceID: device.id, value: storedVolume)
        } else if let currentVolume = readOutputVolumeScalar(deviceID: device.id) {
            outputVolumesByUID[device.uid] = currentVolume
            UserDefaults.standard.set(outputVolumesByUID, forKey: DefaultsKey.outputVolumes)
        }
    }

    private func persistSelectorState() {
        UserDefaults.standard.set(recentConnected, forKey: DefaultsKey.recentConnected)
        UserDefaults.standard.set(lastSuccessUID, forKey: DefaultsKey.lastSuccessUID)
        UserDefaults.standard.set(knownDeviceOrder, forKey: DefaultsKey.knownDeviceOrder)
        UserDefaults.standard.set(excludedKnownDeviceOrder, forKey: DefaultsKey.excludedKnownDeviceOrder)
        UserDefaults.standard.set(knownDeviceNames, forKey: DefaultsKey.knownDeviceNames)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
