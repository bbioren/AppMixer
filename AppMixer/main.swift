import AppKit
import CoreAudio
import AudioToolbox
import CoreGraphics

// MARK: - Audio Process Discovery

struct AudioProcess: Identifiable, Hashable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?
    let isOutputting: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.pid == rhs.pid
    }
}

func getAudioProcesses() -> [AudioProcess] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size
    ) == noErr else { return [] }

    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var processIDs = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size, &processIDs
    ) == noErr else { return [] }

    return processIDs.compactMap { objectID in
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &pidAddr, 0, nil, &pidSize, &pid) == noErr else { return nil }

        var bundleAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleCF: Unmanaged<CFString>? = nil
        var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(objectID, &bundleAddr, 0, nil, &bundleSize, &bundleCF)
        let bundleID = bundleCF?.takeRetainedValue() as String? ?? ""

        var outputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isOutput: UInt32 = 0
        var outputSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(objectID, &outputAddr, 0, nil, &outputSize, &isOutput)

        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        ?? NSRunningApplication(processIdentifier: pid)

        let name = app?.localizedName ?? bundleID
        let icon = app?.icon

        if bundleID.isEmpty || name.isEmpty { return nil }

        return AudioProcess(
            id: objectID,
            pid: pid,
            bundleID: bundleID,
            name: name,
            icon: icon,
            isOutputting: isOutput != 0
        )
    }
}

// MARK: - Volume Persistence

class VolumeStore {
    static let shared = VolumeStore()
    private let defaults = UserDefaults.standard
    private let volumeKey = "AppMixer.volumes"
    private let muteKey = "AppMixer.muted"
    private let masterVolumeKey = "AppMixer.masterVolume"

    func saveVolume(for bundleID: String, gain: Float) {
        var volumes = defaults.dictionary(forKey: volumeKey) as? [String: Float] ?? [:]
        volumes[bundleID] = gain
        defaults.set(volumes, forKey: volumeKey)
    }

    func loadVolume(for bundleID: String) -> Float? {
        let volumes = defaults.dictionary(forKey: volumeKey) as? [String: Float] ?? [:]
        return volumes[bundleID]
    }

    func saveMuted(for bundleID: String, muted: Bool) {
        var mutedApps = defaults.dictionary(forKey: muteKey) as? [String: Bool] ?? [:]
        mutedApps[bundleID] = muted
        defaults.set(mutedApps, forKey: muteKey)
    }

    func loadMuted(for bundleID: String) -> Bool {
        let mutedApps = defaults.dictionary(forKey: muteKey) as? [String: Bool] ?? [:]
        return mutedApps[bundleID] ?? false
    }

    func saveMasterVolume(_ volume: Float) {
        defaults.set(volume, forKey: masterVolumeKey)
    }

    func loadMasterVolume() -> Float {
        if defaults.object(forKey: masterVolumeKey) != nil {
            return defaults.float(forKey: masterVolumeKey)
        }
        return 1.0
    }
}

// MARK: - Audio Tap Manager

@available(macOS 14.2, *)
class AppAudioTap {
    let process: AudioProcess
    var gain: Float = 1.0 {
        didSet {
            effectiveGain = isMuted ? 0.0 : gain * masterGain
        }
    }
    var masterGain: Float = 1.0 {
        didSet {
            effectiveGain = isMuted ? 0.0 : gain * masterGain
        }
    }
    var isMuted: Bool = false {
        didSet {
            effectiveGain = isMuted ? 0.0 : gain * masterGain
        }
    }
    private var effectiveGain: Float = 1.0
    var tapID: AudioObjectID = 0
    var aggregateID: AudioObjectID = 0
    var procID: AudioDeviceIOProcID?
    var isActive = false
    private let tapUUID = UUID()

    init(process: AudioProcess) {
        self.process = process
        if let savedGain = VolumeStore.shared.loadVolume(for: process.bundleID) {
            self.gain = savedGain
        }
        self.isMuted = VolumeStore.shared.loadMuted(for: process.bundleID)
        self.masterGain = VolumeStore.shared.loadMasterVolume()
        self.effectiveGain = isMuted ? 0.0 : gain * masterGain
    }

    func start() -> Bool {
        guard !isActive else { return true }

        guard let outputDeviceUID = getDefaultOutputDeviceUID() else {
            print("Failed to get output device UID")
            return false
        }

        let processObjectID = process.id

        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDesc.uuid = tapUUID
        tapDesc.muteBehavior = .mutedWhenTapped
        tapDesc.name = "AppMixer-\(process.name)"
        tapDesc.isPrivate = true

        var newTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard tapStatus == noErr else {
            print("Failed to create tap for \(process.name): \(tapStatus)")
            return false
        }
        tapID = newTapID

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AppMixer-\(process.name)",
            kAudioAggregateDeviceUIDKey as String: "AppMixer-\(tapUUID.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey as String: true
        ]

        var newAggID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard aggStatus == noErr else {
            print("Failed to create aggregate device for \(process.name): \(aggStatus)")
            AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        aggregateID = newAggID

        var newProcID: AudioDeviceIOProcID?
        let tap = self
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil) {
            _, inInputData, _, outOutputData, _ in

            let currentGain = tap.effectiveGain
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)

            for i in 0..<output.count {
                guard let outData = output[i].mData else { continue }
                let outSamples = outData.assumingMemoryBound(to: Float.self)
                let outSampleCount = Int(output[i].mDataByteSize) / MemoryLayout<Float>.size

                if i < input.count, let inData = input[i].mData {
                    let inSamples = inData.assumingMemoryBound(to: Float.self)
                    let inSampleCount = Int(input[i].mDataByteSize) / MemoryLayout<Float>.size
                    let count = min(inSampleCount, outSampleCount)
                    for j in 0..<count {
                        outSamples[j] = inSamples[j] * currentGain
                    }
                    for j in count..<outSampleCount {
                        outSamples[j] = 0
                    }
                } else if input.count > 0, let inData = input[0].mData {
                    let inSamples = inData.assumingMemoryBound(to: Float.self)
                    let inSampleCount = Int(input[0].mDataByteSize) / MemoryLayout<Float>.size
                    let inChannels = Int(input[0].mNumberChannels)
                    let outChannelsPerBuf = Int(output[i].mNumberChannels)

                    if inChannels >= 2 && outChannelsPerBuf == 1 {
                        let frames = min(inSampleCount / inChannels, outSampleCount)
                        let ch = i % inChannels
                        for j in 0..<frames {
                            outSamples[j] = inSamples[j * inChannels + ch] * currentGain
                        }
                    } else {
                        let count = min(inSampleCount, outSampleCount)
                        for j in 0..<count {
                            outSamples[j] = inSamples[j] * currentGain
                        }
                    }
                    for j in min(inSampleCount, outSampleCount)..<outSampleCount {
                        outSamples[j] = 0
                    }
                } else {
                    for j in 0..<outSampleCount {
                        outSamples[j] = 0
                    }
                }
            }
        }

        guard ioStatus == noErr, let procID = newProcID else {
            print("Failed to create IO proc for \(process.name): \(ioStatus)")
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        self.procID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            print("Failed to start device for \(process.name): \(startStatus)")
            cleanup()
            return false
        }

        isActive = true
        print("Tap active for \(process.name)")
        return true
    }

    func cleanup() {
        if let procID = procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
        isActive = false
        procID = nil
        tapID = 0
        aggregateID = 0
    }

    deinit {
        cleanup()
    }
}

func getDefaultOutputDeviceUID() -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size, &deviceID
    ) == noErr else { return nil }

    var uidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>? = nil
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(
        deviceID, &uidAddress, 0, nil, &uidSize, &uid
    ) == noErr else { return nil }

    return uid?.takeRetainedValue() as String?
}

// MARK: - Menu Bar App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var taps: [pid_t: AppAudioTap] = [:]
    var pollTimer: Timer?
    var masterVolume: Float = 1.0
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAudioPermission()

        masterVolume = VolumeStore.shared.loadMasterVolume()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "App Mixer")
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 420)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = MixerViewController(masterVolume: masterVolume)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshProcesses()
        }
        refreshProcesses()
    }

    func checkAudioPermission() {
        if #available(macOS 15.0, *) {
            CGPreflightScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
            }
        } else {
            CGPreflightScreenCaptureAccess()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent

        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshProcesses()
            if let vc = popover.contentViewController as? MixerViewController {
                vc.updateUI(taps: taps)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func showContextMenu() {
        let menu = NSMenu()

        let resetItem = NSMenuItem(title: "Reset All Volumes", action: #selector(resetAllVolumes), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit AppMixer", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func resetAllVolumes() {
        masterVolume = 1.0
        VolumeStore.shared.saveMasterVolume(1.0)
        for (_, tap) in taps {
            tap.gain = 1.0
            tap.isMuted = false
            tap.masterGain = 1.0
            VolumeStore.shared.saveVolume(for: tap.process.bundleID, gain: 1.0)
            VolumeStore.shared.saveMuted(for: tap.process.bundleID, muted: false)
        }
        if let vc = popover.contentViewController as? MixerViewController {
            vc.masterSlider?.doubleValue = 100
            vc.masterPercentLabel?.stringValue = "100%"
            vc.updateUI(taps: taps)
        }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func refreshProcesses() {
        let processes = getAudioProcesses().filter { $0.isOutputting }

        let activePIDs = Set(processes.map { $0.pid })
        for pid in taps.keys {
            if !activePIDs.contains(pid) {
                taps[pid]?.cleanup()
                taps.removeValue(forKey: pid)
            }
        }

        for process in processes {
            if taps[process.pid] == nil {
                let tap = AppAudioTap(process: process)
                tap.masterGain = masterVolume
                if tap.start() {
                    taps[process.pid] = tap
                }
            }
        }

        if popover.isShown, let vc = popover.contentViewController as? MixerViewController {
            vc.updateUI(taps: taps)
        }
    }

    func updateMasterVolume(_ volume: Float) {
        masterVolume = volume
        VolumeStore.shared.saveMasterVolume(volume)
        for (_, tap) in taps {
            tap.masterGain = volume
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        for (_, tap) in taps {
            tap.cleanup()
        }
        taps.removeAll()
    }
}

// MARK: - Hover-tracking View

class HoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

// MARK: - Mixer UI

class MixerViewController: NSViewController {
    var stackView: NSStackView!
    var scrollView: NSScrollView!
    var sliderRows: [pid_t: SliderRow] = [:]
    var masterSlider: NSSlider?
    var masterPercentLabel: NSTextField?
    var masterMuteButton: NSButton?
    private var masterVolume: Float
    private var isMasterMuted = false
    private var preMuteMasterVolume: Float = 1.0

    struct SliderRow {
        let container: NSView
        let slider: NSSlider
        let label: NSTextField
        let percentLabel: NSTextField
        let muteButton: NSButton
        let pid: pid_t
    }

    init(masterVolume: Float) {
        self.masterVolume = masterVolume
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.masterVolume = 1.0
        super.init(coder: coder)
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
        container.wantsLayer = true

        let titleLabel = NSTextField(labelWithString: "App Mixer")
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let masterRow = createMasterRow()
        masterRow.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.alignment = .leading

        let clipView = NSClipView()
        clipView.documentView = stackView
        clipView.drawsBackground = false

        scrollView = NSScrollView()
        scrollView.contentView = clipView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let emptyLabel = NSTextField(labelWithString: "No apps playing audio")
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.tag = 999
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(masterRow)
        container.addSubview(divider)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            masterRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            masterRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            masterRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider.topAnchor.constraint(equalTo: masterRow.bottomAnchor, constant: 6),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        self.view = container
    }

    func createMasterRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Master Volume")
        iconView.contentTintColor = .controlAccentColor
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let nameLabel = NSTextField(labelWithString: "Master")
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let muteBtn = NSButton()
        muteBtn.bezelStyle = .inline
        muteBtn.isBordered = false
        muteBtn.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Mute")
        muteBtn.imagePosition = .imageOnly
        muteBtn.target = self
        muteBtn.action = #selector(masterMuteToggled(_:))
        muteBtn.translatesAutoresizingMaskIntoConstraints = false
        muteBtn.contentTintColor = .secondaryLabelColor
        self.masterMuteButton = muteBtn

        let slider = NSSlider(value: Double(masterVolume * 100), minValue: 0, maxValue: 200, target: self, action: #selector(masterSliderChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.isContinuous = true
        self.masterSlider = slider

        let percentLabel = NSTextField(labelWithString: "\(Int(masterVolume * 100))%")
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        self.masterPercentLabel = percentLabel

        row.addSubview(muteBtn)
        row.addSubview(iconView)
        row.addSubview(nameLabel)
        row.addSubview(slider)
        row.addSubview(percentLabel)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 50),

            muteBtn.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            muteBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            muteBtn.widthAnchor.constraint(equalToConstant: 22),
            muteBtn.heightAnchor.constraint(equalToConstant: 22),

            iconView.leadingAnchor.constraint(equalTo: muteBtn.trailingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -8),

            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            slider.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            slider.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -8),

            percentLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            percentLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 42),
        ])

        return row
    }

    @objc func masterSliderChanged(_ sender: NSSlider) {
        let value = Float(sender.doubleValue / 100.0)
        masterVolume = value
        masterPercentLabel?.stringValue = "\(Int(sender.doubleValue))%"

        if isMasterMuted {
            isMasterMuted = false
            masterMuteButton?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Mute")
            masterMuteButton?.contentTintColor = .secondaryLabelColor
        }

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.updateMasterVolume(value)
        }
    }

    @objc func masterMuteToggled(_ sender: NSButton) {
        isMasterMuted.toggle()

        if isMasterMuted {
            preMuteMasterVolume = masterVolume
            masterSlider?.doubleValue = 0
            masterPercentLabel?.stringValue = "0%"
            masterMuteButton?.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Unmute")
            masterMuteButton?.contentTintColor = .systemRed
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.updateMasterVolume(0)
            }
        } else {
            masterSlider?.doubleValue = Double(preMuteMasterVolume * 100)
            masterPercentLabel?.stringValue = "\(Int(preMuteMasterVolume * 100))%"
            masterMuteButton?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Mute")
            masterMuteButton?.contentTintColor = .secondaryLabelColor
            masterVolume = preMuteMasterVolume
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.updateMasterVolume(preMuteMasterVolume)
            }
        }
    }

    func updateUI(taps: [pid_t: AppAudioTap]) {
        let emptyLabel = view.viewWithTag(999)
        emptyLabel?.isHidden = !taps.isEmpty
        scrollView.isHidden = taps.isEmpty

        let currentPIDs = Set(taps.keys)
        for pid in sliderRows.keys {
            if !currentPIDs.contains(pid) {
                if let row = sliderRows[pid] {
                    stackView.removeArrangedSubview(row.container)
                    row.container.removeFromSuperview()
                }
                sliderRows.removeValue(forKey: pid)
            }
        }

        for (pid, tap) in taps.sorted(by: { $0.value.process.name < $1.value.process.name }) {
            if sliderRows[pid] == nil {
                let row = createSliderRow(for: tap)
                stackView.addArrangedSubview(row.container)
                sliderRows[pid] = row
            } else if let row = sliderRows[pid] {
                row.slider.doubleValue = Double(tap.gain * 100)
                row.percentLabel.stringValue = "\(Int(tap.gain * 100))%"
                updateMuteButtonAppearance(row.muteButton, muted: tap.isMuted)
            }
        }

        let totalHeight = min(420.0, CGFloat(80 + taps.count * 52 + 10))
        if let popover = (NSApp.delegate as? AppDelegate)?.popover {
            popover.contentSize = NSSize(width: 300, height: totalHeight)
        }
    }

    func createSliderRow(for tap: AppAudioTap) -> SliderRow {
        let container = HoverView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 6

        container.onHover = { hovering in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                container.layer?.backgroundColor = hovering
                    ? NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
                    : NSColor.clear.cgColor
            }
        }

        let muteBtn = NSButton()
        muteBtn.bezelStyle = .inline
        muteBtn.isBordered = false
        muteBtn.imagePosition = .imageOnly
        muteBtn.target = self
        muteBtn.action = #selector(muteToggled(_:))
        muteBtn.tag = Int(tap.process.pid)
        muteBtn.translatesAutoresizingMaskIntoConstraints = false
        updateMuteButtonAppearance(muteBtn, muted: tap.isMuted)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = tap.process.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let nameLabel = NSTextField(labelWithString: tap.process.name)
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(value: Double(tap.gain * 100), minValue: 0, maxValue: 200, target: self, action: #selector(sliderChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.tag = Int(tap.process.pid)
        slider.isContinuous = true

        let percentLabel = NSTextField(labelWithString: "\(Int(tap.gain * 100))%")
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(muteBtn)
        container.addSubview(iconView)
        container.addSubview(nameLabel)
        container.addSubview(slider)
        container.addSubview(percentLabel)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 52),

            muteBtn.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            muteBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            muteBtn.widthAnchor.constraint(equalToConstant: 22),
            muteBtn.heightAnchor.constraint(equalToConstant: 22),

            iconView.leadingAnchor.constraint(equalTo: muteBtn.trailingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -8),

            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            slider.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            slider.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -8),

            percentLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            percentLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 42),
        ])

        return SliderRow(container: container, slider: slider, label: nameLabel, percentLabel: percentLabel, muteButton: muteBtn, pid: tap.process.pid)
    }

    func updateMuteButtonAppearance(_ button: NSButton, muted: Bool) {
        if muted {
            button.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Unmute")
            button.contentTintColor = .systemRed
        } else {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Mute")
            button.contentTintColor = .secondaryLabelColor
        }
    }

    @objc func muteToggled(_ sender: NSButton) {
        let pid = pid_t(sender.tag)

        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let tap = appDelegate.taps[pid] else { return }

        tap.isMuted.toggle()
        VolumeStore.shared.saveMuted(for: tap.process.bundleID, muted: tap.isMuted)
        updateMuteButtonAppearance(sender, muted: tap.isMuted)

        if let row = sliderRows[pid] {
            if tap.isMuted {
                row.slider.isEnabled = false
                row.percentLabel.stringValue = "Muted"
                row.percentLabel.textColor = .systemRed
            } else {
                row.slider.isEnabled = true
                row.percentLabel.stringValue = "\(Int(tap.gain * 100))%"
                row.percentLabel.textColor = .secondaryLabelColor
            }
        }
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        let pid = pid_t(sender.tag)
        let gain = Float(sender.doubleValue / 100.0)

        if let appDelegate = NSApp.delegate as? AppDelegate,
           let tap = appDelegate.taps[pid] {
            tap.gain = gain
            VolumeStore.shared.saveVolume(for: tap.process.bundleID, gain: gain)

            if tap.isMuted {
                tap.isMuted = false
                VolumeStore.shared.saveMuted(for: tap.process.bundleID, muted: false)
                if let row = sliderRows[pid] {
                    updateMuteButtonAppearance(row.muteButton, muted: false)
                    row.slider.isEnabled = true
                    row.percentLabel.textColor = .secondaryLabelColor
                }
            }
        }

        if let row = sliderRows[pid] {
            row.percentLabel.stringValue = "\(Int(sender.doubleValue))%"
        }
    }
}

// MARK: - Main Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
