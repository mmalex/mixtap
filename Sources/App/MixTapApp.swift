import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// Lifecycle calls are serialized on controlQueue. Every property shared with the
// UI is an atomic scalar (or, for failure text, protected by a C++ mutex).
extension MTAudioRecorder: @unchecked Sendable {}

@main
struct MixTapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        MenuBarExtra {
            RecorderView(model: model)
        } label: {
            Label(model.recording ? "MixTap • Recording" : "MixTap", systemImage: model.recording ? "record.circle.fill" : "waveform")
                .symbolRenderingMode(.palette)
                .foregroundStyle(model.recording ? Color.red : Color.primary)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NotificationCenter.default.post(name: .mixtapWillQuit, object: nil)
        return .terminateNow
    }
}
extension Notification.Name { static let mixtapWillQuit = Notification.Name("MixTapWillQuit") }

@MainActor
final class RecorderModel: ObservableObject {
    @Published var devices: [MTInputDevice] = []
    @Published var selectedUID: String = UserDefaults.standard.string(forKey: "microphoneUID") ?? "" {
        didSet { UserDefaults.standard.set(selectedUID, forKey: "microphoneUID") }
    }
    @Published var desktopDB: Double = UserDefaults.standard.object(forKey: "desktopDB") as? Double ?? -6 {
        didSet { recorder.desktopDB = Float(desktopDB); UserDefaults.standard.set(desktopDB, forKey: "desktopDB") }
    }
    @Published var micDB: Double = UserDefaults.standard.object(forKey: "micDB") as? Double ?? -6 {
        didSet { recorder.microphoneDB = Float(micDB); UserDefaults.standard.set(micDB, forKey: "micDB") }
    }
    @Published var desktopMuted = false { didSet { recorder.desktopMuted = desktopMuted } }
    @Published var micMuted = false { didSet { recorder.microphoneMuted = micMuted } }
    @Published var recording = false
    @Published var busy = false
    @Published var message = "Choose an input, then record a short test."
    @Published var error: String?
    @Published var duration = 0.0
    @Published var desktopPeak: Float = 0
    @Published var micPeak: Float = 0
    @Published var mixPeak: Float = 0
    @Published var overload = false
    @Published var dropped: UInt64 = 0
    @Published var micMissing: UInt64 = 0
    @Published var desktopMissing: UInt64 = 0
    @Published var desktopReceiving = false
    @Published var lastFile: URL?
    private var recorder = MTAudioRecorder()
    private let controlQueue = DispatchQueue(label: "dev.mixtap.control", qos: .userInitiated)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pollCount = 0

    init() {
        refreshDevices()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop(reason: "Recording saved before sleep.") }
            })
        observers.append(NotificationCenter.default.addObserver(forName: .mixtapWillQuit, object: nil, queue: .main) { [weak self] _ in
            // Termination must wait for the writer to close the WAV and release capture.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.controlQueue.sync { _ = self.recorder.stop() }
            }
        })
    }

    func refreshDevices() {
        guard !recording && !busy else { return }
        devices = MTAudioRecorder.inputDevices()
    }

    func begin() {
        guard !recording && !busy else { return }
        guard let device = devices.first(where: { $0.uid == selectedUID }) else {
            error = "Choose an available microphone first."
            return
        }
        busy = true
        error = nil
        Task { [self] in
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else {
                error = "Allow MixTap in System Settings → Privacy & Security → Microphone, then try again."
                busy = false
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.wav]
            panel.canCreateDirectories = true
            panel.title = "Save MixTap recording"
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            panel.nameFieldStringValue = "MixTap \(formatter.string(from: Date())).wav"
            guard panel.runModal() == .OK, let url = panel.url else { busy = false; return }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                error = "Please choose a new filename. MixTap keeps existing recordings intact."
                busy = false
                return
            }
            // A new recorder gives every recording fresh rings, clocks, and diagnostics.
            let engine = MTAudioRecorder()
            engine.desktopDB = Float(desktopDB)
            engine.microphoneDB = Float(micDB)
            engine.desktopMuted = desktopMuted
            engine.microphoneMuted = micMuted
            recorder = engine
            duration = 0; desktopPeak = 0; micPeak = 0; mixPeak = 0
            overload = false; dropped = 0; micMissing = 0; desktopMissing = 0
            message = "Starting… approve system audio access if macOS asks."
            let deviceID = device.deviceID
            controlQueue.async { [weak self] in
                do {
                    try engine.start(withInput: deviceID, url: url)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.lastFile = url
                        self.recording = true
                        self.busy = false
                        self.message = "Recording desktop + microphone"
                    }
                } catch {
                    _ = engine.stop()
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.busy = false
                        self.error = error.localizedDescription
                        self.message = "Could not start recording."
                    }
                }
            }
        }
    }

    func stop(reason: String? = nil) {
        guard recording && !busy else { return }
        busy = true
        let engine = recorder
        controlQueue.async { [weak self] in
            let failure = engine.stop()
            DispatchQueue.main.async {
                guard let self else { return }
                self.duration = engine.duration
                self.recording = false
                self.busy = false
                self.desktopPeak = 0; self.micPeak = 0; self.mixPeak = 0
                self.message = reason ?? "Saved \(self.lastFile?.lastPathComponent ?? "recording")."
                if let failure { self.error = failure }
                self.refreshDevices()
            }
        }
    }

    private func poll() {
        pollCount += 1
        guard recording && !busy else {
            if pollCount % 30 == 0 { refreshDevices() }
            return
        }
        duration = recorder.duration
        desktopPeak = recorder.desktopPeak
        micPeak = recorder.microphonePeak
        mixPeak = recorder.mixPeak
        overload = overload || mixPeak > 1
        dropped = recorder.droppedPackets
        micMissing = recorder.microphoneMissingFrames
        desktopMissing = recorder.desktopMissingFrames
        desktopReceiving = recorder.desktopReceiving
        if let failure = recorder.failure { stop(reason: failure) }
    }

    func reveal() {
        if let lastFile { NSWorkspace.shared.activateFileViewerSelecting([lastFile]) }
    }
    func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(url) }
    }
    var elapsed: String {
        let seconds = Int(duration)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MixTap").font(.title2.weight(.semibold))
                    Text("Desktop + microphone").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.elapsed).font(.system(.body, design: .monospaced)).foregroundStyle(model.recording ? .red : .secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("Microphone / input").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Microphone", selection: $model.selectedUID) {
                    if !model.devices.contains(where: { $0.uid == model.selectedUID }) {
                        Text(model.selectedUID.isEmpty ? "Choose an input…" : "Saved input unavailable").tag(model.selectedUID)
                    }
                    ForEach(model.devices, id: \.uid) { device in Text(device.name).tag(device.uid) }
                }
                .labelsHidden()
                .disabled(model.recording || model.busy)
                Text("Input channel 1 • centered in stereo").font(.caption2).foregroundStyle(.secondary)
            }
            GainControl(title: "Desktop", db: $model.desktopDB, muted: $model.desktopMuted, peak: model.desktopPeak)
            GainControl(title: "Microphone", db: $model.micDB, muted: $model.micMuted, peak: model.micPeak)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Stereo mix").font(.caption.weight(.semibold))
                    Spacer()
                    Text(dbText(model.mixPeak)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                LevelMeter(peak: model.mixPeak)
                if model.overload {
                    Text("Mix exceeded 0 dBFS. Lower a level to avoid distorted playback.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Divider()
            Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.recording && model.duration > 3 && !model.desktopReceiving {
                Text("No desktop audio buffers yet. Play some audio; if the meter stays empty, check system audio permission.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.dropped > 0 {
                Text("\(model.dropped) capture buffers dropped. This recording may contain gaps.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open privacy settings", action: model.openPrivacy).font(.caption)
            }
            HStack {
                Button {
                    if model.recording { model.stop() } else { model.begin() }
                } label: {
                    Label(model.busy ? "Please wait…" : model.recording ? "Stop & save" : "Record WAV…",
                          systemImage: model.recording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.recording ? .red : .accentColor)
                .disabled(model.busy || (!model.recording && !model.devices.contains(where: { $0.uid == model.selectedUID })))
            }
            HStack {
                Text("48 kHz · stereo · 32-bit float WAV").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Show file", action: model.reveal).disabled(model.lastFile == nil)
            }
            HStack {
                Text("Playback stays on your normal output.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.disabled(model.busy)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private func dbText(_ peak: Float) -> String {
    peak > 0.000001 ? String(format: "%.1f dBFS", 20 * log10(peak)) : "−∞ dBFS"
}
struct GainControl: View {
    let title: String
    @Binding var db: Double
    @Binding var muted: Bool
    let peak: Float
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.body.weight(.medium))
                Spacer()
                Text(muted ? "Muted" : String(format: "%+.1f dB", db)).font(.system(.caption, design: .monospaced))
                Button { muted.toggle() } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18)
                }.buttonStyle(.borderless).help(muted ? "Unmute \(title)" : "Mute \(title)")
                    .accessibilityLabel(muted ? "Unmute \(title)" : "Mute \(title)")
            }
            Slider(value: $db, in: -60...12, step: 0.5).accessibilityLabel("\(title) gain in decibels")
            LevelMeter(peak: peak)
            HStack {
                Text("−60 dB")
                Spacer()
                Button("0 dB") { db = 0 }.buttonStyle(.plain).help("Reset \(title) to unity gain")
                Spacer()
                Text("+12 dB")
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}
struct LevelMeter: View {
    let peak: Float
    var body: some View {
        GeometryReader { geometry in
            let level = peak > 0 ? max(0, min(1, (20 * log10(Double(peak)) + 60) / 60)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(peak > 1 ? Color.red : peak > 0.8 ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * level)
            }
        }
        .frame(height: 5)
        .accessibilityLabel("Peak level \(dbText(peak))")
    }
}
