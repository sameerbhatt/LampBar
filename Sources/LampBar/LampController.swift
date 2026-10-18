import Foundation
import Security
import SwiftUI

struct Preset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    var brightness: Int
    var colorTemp: Int

    static let defaults: [Preset] = [
        Preset(id: "reading", name: "Reading", symbol: "book", brightness: 100, colorTemp: 4000),
        Preset(id: "pc", name: "PC Mode", symbol: "desktopcomputer", brightness: 30, colorTemp: 2700),
        Preset(id: "custom", name: "Custom", symbol: "slider.horizontal.3", brightness: 70, colorTemp: 3200),
    ]
}

/// The Mi Desk Lamp 1S (yeelink.light.lamp4) normally answers Yeelight-style miIO
/// commands; newer firmware may only speak MIoT property calls. We detect which works.
private enum Dialect { case legacy, miot }

@MainActor
final class LampController: ObservableObject {
    static let ctRange = 2600...5000
    static let brightnessRange = 1...100

    @Published var isOn = false
    @Published var brightness: Double = 50
    @Published var colorTemp: Double = 4000
    @Published var status: String = "Not connected"
    @Published var lastError: String?
    @Published var isBusy = false
    @Published var connected = false

    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    @Published var presets: [Preset] { didSet { savePresets() } }

    // Automation (see SystemEvents).
    @Published var offWhenMacSleeps: Bool { didSet { UserDefaults.standard.set(offWhenMacSleeps, forKey: "offWhenMacSleeps") } }
    @Published var onWhenMacUnlocks: Bool { didSet { UserDefaults.standard.set(onWhenMacUnlocks, forKey: "onWhenMacUnlocks") } }

    private var client: MiIOClient?
    private var dialect: Dialect?
    private var pendingBrightness: Task<Void, Never>?
    private var pendingColorTemp: Task<Void, Never>?
    private var pollTimer: Timer?
    private var systemEvents: SystemEvents?
    // Last values known to be on the lamp; slider changes matching these aren't re-sent.
    private var deviceBrightness: Int?
    private var deviceColorTemp: Int?

    init() {
        host = UserDefaults.standard.string(forKey: "host") ?? "10.0.0.4"
        var loaded = Preset.defaults
        if let data = UserDefaults.standard.data(forKey: "presets"),
           let saved = try? JSONDecoder().decode([Preset].self, from: data) {
            loaded = saved
        }
        // v2: Reading and PC Mode values updated to match the user's Mi Home presets.
        let migrate = UserDefaults.standard.integer(forKey: "presetsVersion") < 2
        if migrate {
            for preset in Preset.defaults where preset.id != "custom" {
                if let i = loaded.firstIndex(where: { $0.id == preset.id }) { loaded[i] = preset }
            }
            UserDefaults.standard.set(2, forKey: "presetsVersion")
        }
        presets = loaded
        offWhenMacSleeps = UserDefaults.standard.bool(forKey: "offWhenMacSleeps")
        onWhenMacUnlocks = UserDefaults.standard.bool(forKey: "onWhenMacUnlocks")
        token = Keychain.read(account: "token") ?? ""
        if migrate { savePresets() }
        rebuildClient()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
        systemEvents = SystemEvents(lamp: self)
    }

    @Published private(set) var token: String = ""

    func setToken(_ value: String) {
        token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(token, account: "token")
        rebuildClient()
    }

    var hasToken: Bool { !token.isEmpty }

    func rebuildClient() {
        dialect = nil
        connected = false
        do {
            client = try MiIOClient(host: host.trimmingCharacters(in: .whitespaces), tokenHex: token)
            lastError = nil
            status = "Connecting…"
        } catch {
            client = nil
            status = hasToken ? "Invalid token" : "Token needed — open Settings"
        }
    }

    // MARK: - Reading state

    func refresh() async {
        guard let client else { return }
        do {
            let dialect = try await resolveDialect(client)
            switch dialect {
            case .legacy:
                let r = try await client.call("get_prop", ["power", "bright", "ct"]) as? [Any] ?? []
                isOn = (r[safe: 0] as? String) == "on"
                if let b = intValue(r[safe: 1]) { setFromDevice(brightness: b) }
                if let ct = intValue(r[safe: 2]) { setFromDevice(colorTemp: ct) }
            case .miot:
                let r = try await client.call("get_properties", [
                    ["did": "power", "siid": 2, "piid": 1],
                    ["did": "bright", "siid": 2, "piid": 2],
                    ["did": "ct", "siid": 2, "piid": 3],
                ]) as? [[String: Any]] ?? []
                for p in r {
                    switch p["did"] as? String {
                    case "power": isOn = p["value"] as? Bool ?? false
                    case "bright": if let v = intValue(p["value"]) { setFromDevice(brightness: v) }
                    case "ct": if let v = intValue(p["value"]) { setFromDevice(colorTemp: v) }
                    default: break
                    }
                }
            }
            succeed()
        } catch {
            fail(error)
        }
    }

    private func setFromDevice(brightness b: Int? = nil, colorTemp ct: Int? = nil) {
        if let b {
            deviceBrightness = b
            brightness = Double(b)
        }
        if let ct {
            deviceColorTemp = ct
            colorTemp = Double(ct)
        }
    }

    private func resolveDialect(_ client: MiIOClient) async throws -> Dialect {
        if let dialect { return dialect }
        if let r = try? await client.call("get_prop", ["power", "bright", "ct"]) as? [Any],
           let power = r.first as? String, power == "on" || power == "off" {
            dialect = .legacy
            return .legacy
        }
        // Throws a meaningful error (e.g. timeout) if MIoT doesn't work either.
        _ = try await client.call("get_properties", [["did": "power", "siid": 2, "piid": 1]])
        dialect = .miot
        return .miot
    }

    // MARK: - Commands

    func setPower(_ on: Bool) {
        isOn = on
        send { client, dialect in try await Self.powerCommand(on, client, dialect) }
    }

    /// Used by system events: awaits the result and retries, since Wi-Fi may still be
    /// reconnecting right after wake/unlock.
    func setPowerForSystemEvent(_ on: Bool, attempts: Int) async {
        guard let client else { return }
        client.resetSession()
        for attempt in 1...attempts {
            do {
                let dialect = try await resolveDialect(client)
                try await Self.powerCommand(on, client, dialect)
                isOn = on
                succeed()
                return
            } catch {
                fail(error)
                if attempt < attempts { try? await Task.sleep(for: .seconds(2)) }
            }
        }
    }

    private static func powerCommand(_ on: Bool, _ client: MiIOClient, _ dialect: Dialect) async throws {
        switch dialect {
        case .legacy: _ = try await client.call("set_power", [on ? "on" : "off", "smooth", 300])
        case .miot: _ = try await client.call("set_properties", [["did": "power", "siid": 2, "piid": 1, "value": on]])
        }
    }

    /// Called continuously while the slider is dragged; debounced so the lamp isn't flooded.
    func brightnessChanged() {
        guard Int(brightness.rounded()) != deviceBrightness else { return }
        pendingBrightness?.cancel()
        pendingBrightness = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            applyBrightness(Int(brightness.rounded()))
        }
    }

    func colorTempChanged() {
        guard Int(colorTemp.rounded()) != deviceColorTemp else { return }
        pendingColorTemp?.cancel()
        pendingColorTemp = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            applyColorTemp(Int(colorTemp.rounded()))
        }
    }

    func apply(_ preset: Preset) {
        pendingBrightness?.cancel()
        pendingColorTemp?.cancel()
        setFromDevice(brightness: preset.brightness, colorTemp: preset.colorTemp)
        isOn = true
        send { client, dialect in
            switch dialect {
            case .legacy:
                // set_scene ct sets power, colour temperature and brightness in one call.
                if (try? await client.call("set_scene", ["ct", preset.colorTemp, preset.brightness])) == nil {
                    _ = try await client.call("set_power", ["on", "smooth", 300])
                    _ = try await client.call("set_ct_abx", [preset.colorTemp, "smooth", 300])
                    _ = try await client.call("set_bright", [preset.brightness, "smooth", 300])
                }
            case .miot:
                _ = try await client.call("set_properties", [
                    ["did": "power", "siid": 2, "piid": 1, "value": true],
                    ["did": "bright", "siid": 2, "piid": 2, "value": preset.brightness],
                    ["did": "ct", "siid": 2, "piid": 3, "value": preset.colorTemp],
                ])
            }
        }
    }

    func saveCurrentAsCustom() {
        guard let i = presets.firstIndex(where: { $0.id == "custom" }) else { return }
        presets[i].brightness = Int(brightness.rounded())
        presets[i].colorTemp = Int(colorTemp.rounded())
    }

    func resetPresets() { presets = Preset.defaults }

    private func applyBrightness(_ value: Int) {
        let v = value.clamped(to: Self.brightnessRange)
        deviceBrightness = v
        send { client, dialect in
            switch dialect {
            case .legacy: _ = try await client.call("set_bright", [v, "smooth", 200])
            case .miot: _ = try await client.call("set_properties", [["did": "bright", "siid": 2, "piid": 2, "value": v]])
            }
        }
    }

    private func applyColorTemp(_ value: Int) {
        let v = value.clamped(to: Self.ctRange)
        deviceColorTemp = v
        send { client, dialect in
            switch dialect {
            case .legacy: _ = try await client.call("set_ct_abx", [v, "smooth", 200])
            case .miot: _ = try await client.call("set_properties", [["did": "ct", "siid": 2, "piid": 3, "value": v]])
            }
        }
    }

    private func send(_ action: @escaping (MiIOClient, Dialect) async throws -> Void) {
        guard let client else {
            lastError = status
            return
        }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let dialect = try await resolveDialect(client)
                try await action(client, dialect)
                succeed()
            } catch {
                fail(error)
            }
        }
    }

    private func succeed() {
        connected = true
        lastError = nil
        status = "Connected · \(host)"
    }

    private func fail(_ error: Error) {
        connected = false
        lastError = error.localizedDescription
        status = "Offline"
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: "presets")
        }
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "LampBar"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
