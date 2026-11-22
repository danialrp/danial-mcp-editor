import EditorCore
import EditorKit
import Foundation

/// Everything one editor process runs, wired once: the editor, the media
/// engine, the player, the keymap and the full tool list. The app and the
/// windowless `dme` both use it, so they offer exactly the same tools.
@MainActor
public final class EditorRuntime {
    public let editor: Editor
    public let media: MediaContext
    public let player: PlayerController
    public let keymap: KeymapStore
    public let jobs = JobCenter()
    public let browser: BrowserHost
    public let voice = VoiceRecorder()
    public private(set) var tools: [Tool] = []

    public init(settings: UserSettingsStore) {
        editor = Editor(settings: settings, prober: AVMediaProber())
        media = MediaContext(editor: editor)
        player = PlayerController(media: media)
        keymap = KeymapStore(settings: settings)
        browser = BrowserHost(settings: settings)
        EffectCatalog.shared.configure(userFolder: settings.directory.appendingPathComponent("effects", isDirectory: true))
        let base = ToolCatalog.all + MediaTools.make(media) + MediaTools.playerTools(player)
            + jobs.toolsSync() + AnalysisTools.make(media)
            + AnalysisTools.transcriptTools(media, jobs: jobs, bridge: EditsBridge(settings: settings))
            + ColorTools.make(media) + EffectTools.make(media) + ExportTools.make(media, jobs: jobs) + HyperFramesTools.make(media, jobs: jobs)
            + MatteTools.make(media, jobs: jobs) + BrowserTools.make(browser, jobs: jobs)
            + MediaTools.voiceTools(media, player: player, recorder: voice)
            + SocialTools.make(media, jobs: jobs)
        let names = Set(base.map(\.name))
        // New HyperFrames slices: rebuild the player so it shows them.
        let (m, pl) = (media, Unchecked(player))
        Task { await m.hyperframes.setOnChange { await m.invalidate(); await MainActor.run { Task { await pl.value.rebuild() } } } }
        Task { await m.mattes.setOnChange { await m.invalidate(); await MainActor.run { Task { await pl.value.rebuild() } } } }
        let withKeys = base + keymap.tools(validTools: { names })
        tools = withKeys + AgentTools.make(tools: withKeys)
    }

    /// Finds a tool by its editor name (`timeline.split`) or MCP name (`timeline_split`).
    public func tool(_ name: String) -> Tool? {
        tools.first { $0.name == name || $0.name.replacingOccurrences(of: ".", with: "_") == name }
    }
}
