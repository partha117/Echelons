import SwiftUI
import CoreLocation

struct ActivityView: View {
    @Environment(ActivitySessionController.self) private var session
    @State private var showSettings = false
    @State private var selectedKind: ActivityKind = .run

    var body: some View {
        NavigationStack {
            Group {
                if session.authorizationStatus == .denied || session.authorizationStatus == .restricted {
                    permissionDeniedView
                } else {
                    mainContent
                }
            }
            .navigationTitle("Echelons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(session)
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 24) {
            Picker("Activity", selection: $selectedKind) {
                ForEach(ActivityKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 4) {
                Text(speedText)
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: speedText)
                Text(session.settings.unit.label)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            statusPill

            if let signalDetail {
                Text(signalDetail)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            Text("Target: \(formattedMin) – \(formattedMax) \(session.settings.unit.label)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(elapsedText)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                if session.isRunning { session.stop() } else { session.start(kind: selectedKind) }
            } label: {
                Text(session.isRunning ? "STOP" : "START")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(session.isRunning ? Color.red : Color.green)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .animation(.easeInOut(duration: 0.3), value: session.status)
        .animation(.easeInOut(duration: 0.3), value: session.signal)
    }

    private var statusPill: some View {
        Text(statusLabel)
            .font(.caption.bold())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(statusColor, lineWidth: 1))
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Location Access Required")
                .font(.title2.bold())
            Text("Open Settings to allow location while using the app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var speedText: String { String(format: "%.1f", session.currentSpeed) }
    private var formattedMin: String { String(format: "%.1f", session.settings.minSpeed) }
    private var formattedMax: String { String(format: "%.1f", session.settings.maxSpeed) }

    private var elapsedText: String {
        let total = Int(session.elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private var statusLabel: String {
        switch session.signal {
        case .live, .weak: paceLabel
        case .acquiring:        "ACQUIRING"
        case .stationary:       "STATIONARY"
        case .noSignal:         "NO GPS SIGNAL"
        case .notInUse:         "BACKGROUND UNAVAILABLE"
        case .accuracyLimited:  "PRECISE LOCATION REQUIRED"
        case .denied:           "LOCATION ACCESS REQUIRED"
        }
    }

    private var paceLabel: String {
        switch session.status {
        case .acquiring: "ACQUIRING"
        case .inRange:   "ON PACE"
        case .tooSlow:   "TOO SLOW"
        case .tooFast:   "TOO FAST"
        }
    }

    private var statusColor: Color {
        switch session.signal {
        case .live, .weak: paceColor
        case .acquiring, .stationary: .gray
        case .noSignal, .notInUse, .accuracyLimited, .denied: .red
        }
    }

    private var paceColor: Color {
        switch session.status {
        case .acquiring: .gray
        case .inRange:   .green
        case .tooSlow:   .blue
        case .tooFast:   .orange
        }
    }

    /// Shown under the pill when the pipeline needs the user to do something.
    private var signalDetail: String? {
        switch session.signal {
        case .live, .weak, .acquiring: nil
        case .stationary:      "Waiting for movement."
        case .noSignal:        "No usable GPS fix. Move to open sky."
        case .notInUse:        "Background tracking is not active. Restart the run from the foreground."
        case .accuracyLimited: "Enable Precise Location in Settings so speed can be measured."
        case let .denied(reason): reason.message
        }
    }
}
