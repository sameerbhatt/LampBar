import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import ServiceManagement

/// Turns the lamp off when the Mac sleeps and on when the user logs in / unlocks,
/// according to the toggles on `LampController`.
@MainActor
final class SystemEvents {
    private let lamp: LampController
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var observers: [NSObjectProtocol] = []

    init(lamp: LampController) {
        self.lamp = lamp
        registerForSleep()

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.didWake() }
        })
        // Fast user switching back into this account.
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.userIsBack() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.userIsBack() }
        })

        // Launched as a login item right after boot/login counts as "logged in".
        if ProcessInfo.processInfo.systemUptime < 300 {
            Task { await userIsBack() }
        }
    }

    private func userIsBack() async {
        guard lamp.onWhenMacUnlocks else { return }
        await lamp.setPowerForSystemEvent(true, attempts: 8)
    }

    /// After waking without a password prompt there is no unlock event, so handle it here.
    private func didWake() async {
        guard lamp.onWhenMacUnlocks else { return }
        try? await Task.sleep(for: .seconds(3))
        if !Self.screenIsLocked { await userIsBack() }
    }

    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: - Sleep (IOKit, so sleep waits for the lamp command)

    private func registerForSleep() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let events = Unmanaged<SystemEvents>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { events.handlePower(messageType, argument) }
        }, &notifier)
        if rootPort != 0, let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
        }
    }

    // iokit_common_msg() values from IOKit/IOMessage.h; the C macros aren't imported into Swift.
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280

    private func handlePower(_ messageType: natural_t, _ argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemWillSleep:
            guard lamp.offWhenMacSleeps else {
                IOAllowPowerChange(rootPort, notificationID)
                return
            }
            // Hold sleep until the lamp is off, but never more than 8s.
            var allowed = false
            let allow = { [rootPort] in
                guard !allowed else { return }
                allowed = true
                IOAllowPowerChange(rootPort, notificationID)
            }
            Task {
                await lamp.setPowerForSystemEvent(false, attempts: 1)
                allow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { allow() }
        default:
            break
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
