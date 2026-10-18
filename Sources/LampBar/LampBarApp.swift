import AppKit
import SwiftUI

@main
struct LampBarApp: App {
    @StateObject private var lamp = LampController()

    var body: some Scene {
        MenuBarExtra {
            LampPanel()
                .environmentObject(lamp)
        } label: {
            Image(systemName: lamp.isOn ? "lamp.desk.fill" : "lamp.desk")
        }
        .menuBarExtraStyle(.window)

        Window("LampBar Settings", id: "settings") {
            SettingsView()
                .environmentObject(lamp)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Menu bar panel

struct LampPanel: View {
    @EnvironmentObject var lamp: LampController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if lamp.hasToken {
                controls.disabled(!lamp.isOn)
                presets
            } else {
                Text("Add your lamp's miIO token in Settings to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = lamp.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .task { await lamp.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: lamp.isOn ? "lamp.desk.fill" : "lamp.desk")
                .font(.title2)
                .foregroundStyle(lamp.isOn ? Color.yellow : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Desk Lamp 1S").font(.headline)
                HStack(spacing: 4) {
                    Circle()
                        .fill(lamp.connected ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(lamp.status).font(.caption).foregroundStyle(.secondary)
                    if lamp.isBusy { ProgressView().controlSize(.mini) }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { lamp.isOn }, set: { lamp.setPower($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!lamp.hasToken)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Brightness").font(.subheadline)
                    Spacer()
                    Text("\(Int(lamp.brightness))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: $lamp.brightness, in: 1...100)
                        .onChange(of: lamp.brightness) { lamp.brightnessChanged() }
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Color temperature").font(.subheadline)
                    Spacer()
                    Text("\(Int(lamp.colorTemp))K").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $lamp.colorTemp,
                       in: Double(LampController.ctRange.lowerBound)...Double(LampController.ctRange.upperBound))
                    .onChange(of: lamp.colorTemp) { lamp.colorTempChanged() }
                LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.4), .white, Color(red: 0.75, green: 0.87, blue: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 4)
                    .clipShape(Capsule())
                    .opacity(lamp.isOn ? 1 : 0.4)
            }
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.subheadline)
            HStack(spacing: 8) {
                ForEach(lamp.presets) { preset in
                    Button { lamp.apply(preset) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: preset.symbol).font(.title3)
                            Text(preset.name).font(.caption)
                            Text("\(preset.colorTemp)K · \(preset.brightness)%")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .help("Apply \(preset.name): \(preset.colorTemp)K at \(preset.brightness)%")
                }
            }
            Button("Save current as Custom") { lamp.saveCurrentAsCustom() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Label("Settings…", systemImage: "gearshape") }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var lamp: LampController
    @State private var host = ""
    @State private var token = ""
    @State private var testing = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Lamp IP address", text: $host)
                SecureField("Token (32 hex characters)", text: $token)
                HStack {
                    Button("Save & Connect") {
                        lamp.host = host.trimmingCharacters(in: .whitespaces)
                        lamp.setToken(token)
                        testing = true
                        Task {
                            await lamp.refresh()
                            testing = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(lamp.lastError ?? lamp.status)
                        .font(.caption)
                        .foregroundStyle(lamp.connected ? .green : .secondary)
                        .lineLimit(2)
                }
                Text("The token is stored in your Keychain. See README.md for how to get it from your Xiaomi account.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Automation") {
                Toggle("Turn lamp off when Mac sleeps", isOn: $lamp.offWhenMacSleeps)
                Toggle("Turn lamp on when I log in or unlock", isOn: $lamp.onWhenMacUnlocks)
                Toggle("Open LampBar at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        do {
                            try LaunchAtLogin.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                Text("Sleep includes closing the lid. Needs LampBar running, so keep “Open at login” on.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Presets") {
                ForEach($lamp.presets) { $preset in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(preset.name, systemImage: preset.symbol).font(.headline)
                        HStack {
                            Text("Brightness").frame(width: 80, alignment: .leading)
                            Slider(value: intBinding($preset.brightness), in: 1...100, step: 1)
                            Text("\(preset.brightness)%").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                        HStack {
                            Text("Color temp").frame(width: 80, alignment: .leading)
                            Slider(value: intBinding($preset.colorTemp),
                                   in: Double(LampController.ctRange.lowerBound)...Double(LampController.ctRange.upperBound),
                                   step: 100)
                            Text("\(preset.colorTemp)K").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button("Reset to defaults") { lamp.resetPresets() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            host = lamp.host
            token = lamp.token
        }
    }

    private func intBinding(_ binding: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) })
    }
}
