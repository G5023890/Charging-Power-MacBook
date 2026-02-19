import AppKit
import Foundation
import IOKit
import IOKit.ps
import ServiceManagement

@main
@MainActor
final class ChargingPowerMenuBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var currentChargeItem: NSMenuItem!
    private var maximumCapacityItem: NSMenuItem!
    private var conditionItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var currentTimerInterval: TimeInterval = 0
    private var cachedCurrentCapacityPercent: Int?
    private var cachedMaximumCapacityPercent: Double?
    private var cachedCondition: String = "Unknown"
    private var lastPercentRefreshAt: Date = .distantPast

    private let acPollInterval: TimeInterval = 2.0
    private let batteryPollInterval: TimeInterval = 20.0
    private let percentRefreshInterval: TimeInterval = 20.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        syncLaunchAtLoginMenuState()
        refreshStatus(forcePercentRefresh: true, refreshDetails: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusTitle("--w")
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        currentChargeItem = NSMenuItem(title: "Current Charge: --", action: #selector(noopMenuItem), keyEquivalent: "")
        currentChargeItem.target = self
        maximumCapacityItem = NSMenuItem(title: "Maximum Capacity: --", action: #selector(noopMenuItem), keyEquivalent: "")
        maximumCapacityItem.target = self
        conditionItem = NSMenuItem(title: "Condition: --", action: #selector(noopMenuItem), keyEquivalent: "")
        conditionItem.target = self
        menu.addItem(currentChargeItem)
        menu.addItem(maximumCapacityItem)
        menu.addItem(conditionItem)
        menu.addItem(.separator())
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Update now", action: #selector(updateNow), keyEquivalent: "u"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc
    private func updateNow() {
        syncLaunchAtLoginMenuState()
        refreshStatus(forcePercentRefresh: true, refreshDetails: true)
    }

    @objc
    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Failed to update Launch at Login setting: \(error.localizedDescription)")
        }

        syncLaunchAtLoginMenuState()
    }

    @objc
    private func timerTick() {
        refreshStatus()
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc
    private func noopMenuItem() {
    }

    private func syncLaunchAtLoginMenuState() {
        let status = SMAppService.mainApp.status
        launchAtLoginItem.state = (status == .enabled) ? .on : .off
    }

    private func refreshStatus(forcePercentRefresh: Bool = false, refreshDetails: Bool = false) {
        let liveMetrics = BatteryLiveMetrics.read()
        updatePollingInterval(for: liveMetrics.isOnACPower)

        let now = Date()
        let shouldRefreshPercent = forcePercentRefresh
            || cachedCurrentCapacityPercent == nil
            || now.timeIntervalSince(lastPercentRefreshAt) >= percentRefreshInterval
        if shouldRefreshPercent {
            cachedCurrentCapacityPercent = liveMetrics.currentCapacityPercent
            lastPercentRefreshAt = now
        }

        if refreshDetails {
            let details = BatteryDetailsMetrics.read()
            cachedMaximumCapacityPercent = details.maximumCapacityPercent
            cachedCondition = details.condition
        }

        updateBatteryIcon(
            isCharging: liveMetrics.isCharging,
            currentCapacityPercent: cachedCurrentCapacityPercent
        )
        updateDetailsMenu(
            currentCapacityPercent: cachedCurrentCapacityPercent,
            maximumCapacityPercent: cachedMaximumCapacityPercent,
            condition: cachedCondition
        )

        guard liveMetrics.isOnACPower else {
            if let currentCapacity = cachedCurrentCapacityPercent {
                setStatusTitle("\(currentCapacity)%")
            } else {
                setStatusTitle("")
            }
            return
        }

        if liveMetrics.isCharging, let watts = liveMetrics.watts {
            setStatusTitle(String(format: "%.0fw", watts))
        } else if let adapterWatts = liveMetrics.adapterWatts {
            setStatusTitle(String(format: "%.0fw", adapterWatts))
        } else {
            setStatusTitle("AC")
        }
    }

    private func setStatusTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        let baseFont = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let reducedFont = baseFont.withSize(max(10.0, baseFont.pointSize * 0.9))
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: reducedFont]
        )
    }

    private func updatePollingInterval(for isOnACPower: Bool) {
        let targetInterval = isOnACPower ? acPollInterval : batteryPollInterval
        guard timer == nil || currentTimerInterval != targetInterval else { return }

        timer?.invalidate()
        currentTimerInterval = targetInterval
        timer = Timer.scheduledTimer(
            timeInterval: targetInterval,
            target: self,
            selector: #selector(timerTick),
            userInfo: nil,
            repeats: true
        )

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updateDetailsMenu(currentCapacityPercent: Int?, maximumCapacityPercent: Double?, condition: String) {
        if let currentCapacity = currentCapacityPercent {
            currentChargeItem.title = "Current Charge: \(currentCapacity)%"
        } else {
            currentChargeItem.title = "Current Charge: --"
        }

        if let maximumCapacity = maximumCapacityPercent {
            maximumCapacityItem.title = String(format: "Maximum Capacity: %.0f%%", maximumCapacity)
        } else {
            maximumCapacityItem.title = "Maximum Capacity: --"
        }

        conditionItem.title = "Condition: \(condition)"
    }

    private func updateBatteryIcon(isCharging: Bool, currentCapacityPercent: Int?) {
        let fallbackSymbolName = batterySymbolName(
            currentCapacity: currentCapacityPercent,
            isCharging: isCharging
        )
        guard let fallbackSymbolName else {
            statusItem.button?.image = nil
            return
        }

        let fallbackImage = NSImage(systemSymbolName: fallbackSymbolName, accessibilityDescription: "Battery")
        fallbackImage?.isTemplate = true
        statusItem.button?.image = fallbackImage
    }

    private func batterySymbolName(currentCapacity: Int?, isCharging: Bool) -> String? {
        guard let currentCapacity else { return "battery.100" }
        let clamped = min(max(currentCapacity, 0), 100)

        let levelSymbol: String
        switch clamped {
        case 0:
            levelSymbol = "battery.0"
        case 1..<25:
            levelSymbol = "battery.25"
        case 25..<50:
            levelSymbol = "battery.50"
        case 50..<75:
            levelSymbol = "battery.75"
        case 75..<100:
            levelSymbol = "battery.100"
        default:
            levelSymbol = "battery.100"
        }

        if isCharging {
            switch levelSymbol {
            case "battery.0": return "battery.25.bolt"
            case "battery.25": return "battery.25.bolt"
            case "battery.50": return "battery.50.bolt"
            case "battery.75": return "battery.75.bolt"
            default: return "battery.100.bolt"
            }
        }

        return levelSymbol
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = ChargingPowerMenuBarApp()

        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

private struct BatteryLiveMetrics {
    let isOnACPower: Bool
    let isCharging: Bool
    let currentCapacityPercent: Int?
    let watts: Double?
    let adapterWatts: Double?

    static func read() -> BatteryLiveMetrics {
        let status = BatteryReader.readPowerSourceStatus()
        let smartBattery = BatteryReader.readSmartBatteryProperties()
        let batteryWatts = BatteryReader.readBatteryWatts(from: smartBattery)
        let adapterWatts = BatteryReader.readAdapterWatts()

        return BatteryLiveMetrics(
            isOnACPower: status.isOnACPower,
            isCharging: status.isCharging,
            currentCapacityPercent: status.currentCapacityPercent,
            watts: batteryWatts,
            adapterWatts: adapterWatts
        )
    }
}

private struct BatteryDetailsMetrics {
    let maximumCapacityPercent: Double?
    let condition: String

    static func read() -> BatteryDetailsMetrics {
        let smartBattery = BatteryReader.readSmartBatteryProperties()
        return BatteryDetailsMetrics(
            maximumCapacityPercent: BatteryReader.readMaximumCapacityPercent(from: smartBattery),
            condition: BatteryReader.readCondition(from: smartBattery)
        )
    }
}

private enum BatteryReader {
    static func readPowerSourceStatus() -> (isOnACPower: Bool, isCharging: Bool, currentCapacityPercent: Int?) {
        let psInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let powerSources = IOPSCopyPowerSourcesList(psInfo).takeRetainedValue() as Array

        var isOnACPower = false
        var isCharging = false
        var currentCapacityPercent: Int?

        if let source = powerSources.first,
           let description = IOPSGetPowerSourceDescription(psInfo, source)?.takeUnretainedValue() as? [String: Any] {
            if let state = description[kIOPSPowerSourceStateKey as String] as? String {
                isOnACPower = (state == kIOPSACPowerValue)
            }
            isCharging = (description[kIOPSIsChargingKey as String] as? Bool) ?? false
            currentCapacityPercent = description[kIOPSCurrentCapacityKey as String] as? Int
        }

        return (isOnACPower, isCharging, currentCapacityPercent)
    }

    static func readSmartBatteryProperties() -> [String: Any]? {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        return dict
    }

    static func readBatteryWatts(from dict: [String: Any]?) -> Double? {
        guard let dict,
              let amperage = dict["InstantAmperage"] as? Int,
              let voltage = dict["Voltage"] as? Int,
              voltage > 0 else {
            return nil
        }

        // InstantAmperage is in mA, Voltage in mV, so (mA * mV) / 1_000_000 = W.
        let watts = abs(Double(amperage) * Double(voltage)) / 1_000_000.0
        return watts > 0 ? watts : nil
    }

    static func readMaximumCapacityPercent(from dict: [String: Any]?) -> Double? {
        guard let dict,
              let designCapacity = dict["DesignCapacity"] as? Int,
              designCapacity > 0 else {
            return nil
        }

        if let rawMaxCapacity = dict["AppleRawMaxCapacity"] as? Int, rawMaxCapacity > 0 {
            return (Double(rawMaxCapacity) / Double(designCapacity)) * 100.0
        }

        if let nominalChargeCapacity = dict["NominalChargeCapacity"] as? Int, nominalChargeCapacity > 0 {
            return (Double(nominalChargeCapacity) / Double(designCapacity)) * 100.0
        }

        return nil
    }

    static func readCondition(from dict: [String: Any]?) -> String {
        guard let dict else { return "Unknown" }

        if let condition = dict["BatteryHealthCondition"] as? String, !condition.isEmpty {
            return condition
        }

        if let permanentFailureStatus = dict["PermanentFailureStatus"] as? Int, permanentFailureStatus != 0 {
            return "Service Recommended"
        }

        return "Normal"
    }

    static func readAdapterWatts() -> Double? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        if let watts = details["Watts"] as? Double {
            return watts
        }

        if let watts = details["Watts"] as? Int {
            return Double(watts)
        }

        return nil
    }
}
