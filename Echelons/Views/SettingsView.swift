import SwiftUI

struct SettingsView: View {
    @Environment(ActivitySessionController.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = session.settings
        NavigationStack {
            Form {
                Section("Unit") {
                    Picker("Unit", selection: $settings.unit) {
                        ForEach(SpeedUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.unit) { old, new in
                        settings.minSpeed = new.reexpress(settings.minSpeed, from: old)
                        settings.maxSpeed = new.reexpress(settings.maxSpeed, from: old)
                    }
                }

                Section("Pace Range") {
                    Stepper(
                        "Min: \(String(format: "%.1f", settings.minSpeed)) \(settings.unit.label)",
                        value: $settings.minSpeed,
                        in: 0...(settings.maxSpeed - 0.5),
                        step: 0.5
                    )
                    Stepper(
                        "Max: \(String(format: "%.1f", settings.maxSpeed)) \(settings.unit.label)",
                        value: $settings.maxSpeed,
                        in: (settings.minSpeed + 0.5)...50,
                        step: 0.5
                    )
                }

                Section("Speed") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Average speed over \(Int(settings.speedWindow)) s")
                        Slider(value: $settings.speedWindow, in: 2...30, step: 1)
                        // Not labelled as a GPS sampling rate: CLLocationUpdate.liveUpdates
                        // exposes no rate knob, so this is purely a client-side window.
                        Text("Longer is steadier but slower to react to pace changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Alerts") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Alert every \(Int(settings.checkInterval)) s")
                        Slider(value: $settings.checkInterval, in: 5...120, step: 5)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
