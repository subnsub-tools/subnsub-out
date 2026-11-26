import Foundation

/// Which of its own protocols a recognition service speaks for a model, and the wire for it.
public extension Platform {
    enum Own: Sendable { case live, file }

    /// How this platform's recognition takes a model when it is not spoken to in one of the common
    /// ways: over its live socket, or with the finished recording. Nil for every other platform
    /// and model (OpenAI, Qwen over Model Studio's realtime socket, this Mac, uploads to
    /// `/audio/transcriptions`).
    func own(model: String) -> Own? {
        switch id {
        case Platform.alibaba.id: return FunASRWire.models.contains(model) || model.hasPrefix("fun-asr") ? .live : nil
        case Platform.gemini.id: return GeminiLiveWire.models.contains(model) || model.hasSuffix("-live") ? .live : .file
        case Platform.azure.id: return .file
        default: return wire == .own ? .live : nil
        }
    }

    /// A new live wire for one session with this model; `base` is the platform's address as set
    /// (Model Studio's host comes from it).
    @MainActor func liveWire(model: String, base: URL) -> (any LiveWire)? {
        guard own(model: model) == .live else { return nil }
        switch id {
        case Platform.alibaba.id: return FunASRWire(host: base.host ?? "dashscope-intl.aliyuncs.com")
        case Platform.assemblyAI.id: return AssemblyAIWire()
        case Platform.baidu.id: return BaiduWire()
        case Platform.cartesia.id: return CartesiaWire()
        case Platform.deepgram.id: return DeepgramWire()
        case Platform.elevenLabs.id: return ElevenLabsWire()
        case Platform.gemini.id: return GeminiLiveWire()
        case Platform.gladia.id: return GladiaWire()
        case Platform.iFlytek.id: return IFlytekWire()
        case Platform.mistral.id: return MistralWire()
        case Platform.soniox.id: return SonioxWire()
        case Platform.speechmatics.id: return SpeechmaticsWire()
        case Platform.tencent.id: return TencentWire()
        case Platform.volcano.id: return VolcengineWire()
        default: return nil
        }
    }

    /// A new file wire for this model.
    @MainActor func fileWire(model: String) -> (any FileWire)? {
        guard own(model: model) == .file else { return nil }
        switch id {
        case Platform.gemini.id: return GeminiWire()
        case Platform.azure.id: return AzureWire()
        default: return nil
        }
    }
}
