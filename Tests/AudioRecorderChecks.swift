import AppKit
import AudioCapture
import AVFoundation
import QingyanCore

// Real-device regression check, run with tools/check-audio.sh. Captured audio stays in memory;
// nothing is saved or sent to a service. Pass device UIDs or "default" to test their transitions.
@main
struct AudioRecorderChecks {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            print("FAIL microphone permission denied"); exit(2)
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        let microphones = arguments.isEmpty ? ["default", "default"] : arguments
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(microphones.count) * 12 + 10) {
            print("FAIL capture watchdog"); exit(3)
        }
        do {
            try await rejectsIncompatibleFormat()
            print("SYSTEM_INPUT \(Microphone.systemDefault()?.name ?? "unavailable")")
            let recorder = AudioRecorder()
            defer { recorder.stop() }
            for selected in microphones {
                var levels = 0
                var invalidLevel = false
                let stream = try await recorder.start(microphone: selected == "default" ? "" : selected) { level in
                    levels += 1
                    if !level.isFinite || level < 0 { invalidLevel = true }
                }
                let start = Date()
                let stopper = Task { @MainActor in
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    recorder.stop()
                }
                defer { stopper.cancel() }
                var bytes = 0
                var chunks = 0
                for try await chunk in stream {
                    guard !chunk.isEmpty, chunk.count.isMultiple(of: 2) else { throw VoiceError("Invalid PCM chunk") }
                    bytes += chunk.count
                    chunks += 1
                }
                _ = try await stopper.value
                let wall = Date().timeIntervalSince(start)
                let audio = Double(bytes) / 48000
                guard chunks > 0, levels > 0, !invalidLevel, audio > 1, audio < wall + 0.5 else {
                    throw VoiceError("Unexpected PCM: bytes=\(bytes) chunks=\(chunks) levels=\(levels) wall=\(wall) audio=\(audio)")
                }
                print(String(format: "PASS microphone=%@ bytes=%d chunks=%d levels=%d audio_seconds=%.3f wall_seconds=%.3f",
                             selected, bytes, chunks, levels, audio, wall))
                recorder.stop()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            print("PASS all \(microphones.count) captures")
        } catch {
            print("FAIL \(error.localizedDescription)"); exit(1)
        }
    }

    @MainActor private static func rejectsIncompatibleFormat() async throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Let the hardware finish initial configuration, so this exercises the exception path
        // rather than AVFAudio's temporary "configuration change pending" rejection.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let incompatible = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: hardware.sampleRate == 44100 ? 48000 : 44100,
                channels: hardware.channelCount, interleaved: false) else {
            throw VoiceError("No usable microphone for the device check")
        }
        var error: NSError?
        let started = QYStartAudioCapture(engine, incompatible, { _, _ in }, &error)
        if started {
            engine.stop(); input.removeTap(onBus: 0)
            throw VoiceError("Incompatible capture reported success")
        }
        guard error != nil, !engine.isRunning else { throw VoiceError("Failed capture did not return an error and stop") }
        print("PASS incompatible hardware format returns an error without crashing")
    }
}
