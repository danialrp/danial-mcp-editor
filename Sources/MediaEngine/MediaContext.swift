import AVFoundation
import EditorCore
import EditorKit
import Foundation

/// Keeps the composition of the open project up to date. Built lazily and
/// cached per revision and preview mode, so several reads at one revision
/// build once.
public actor MediaContext {
    /// How the preview differs from what tools and export get.
    public struct PreviewMode: Hashable, Sendable {
        /// An HLG project handed over as SDR.
        public var sdr = false
        /// How SDR frames are read on screen.
        public var gamma = UserSettings.PreviewSettings.Gamma.video

        public init(sdr: Bool = false, gamma: UserSettings.PreviewSettings.Gamma = .video) {
            self.sdr = sdr
            self.gamma = gamma
        }

        /// The mode that gives the same picture for a project in `range`, so equal pictures share one build.
        func effective(in range: DynamicRange) -> PreviewMode {
            let toSDR = sdr && range == .hlg
            return PreviewMode(sdr: toSDR, gamma: range == .sdr || toSDR ? gamma : .video)
        }
    }

    public let editor: Editor
    public let hyperframes: HyperFramesHost
    public let mattes: MatteStore
    private let builder = CompositionBuilder()
    /// Previews that differ build apart: a builder keeps state while it builds, and
    /// the player and a tool may ask for their compositions at once.
    private let previewBuilder = CompositionBuilder()
    private var cached: [PreviewMode: (session: UUID, revision: Int, project: Project, built: BuiltComposition)] = [:]

    public init(editor: Editor) {
        self.editor = editor
        hyperframes = HyperFramesHost(settings: editor.settings)
        mattes = MatteStore(settings: editor.settings)
    }

    /// The open project's composition as tools and export see it, or with
    /// `preview` as the player shows it.
    public func composition(preview: PreviewMode = PreviewMode()) async throws -> BuiltComposition {
        let session = try await editor.requireSession()
        let (project, revision) = await (session.project, session.revision)
        let mode = preview.effective(in: project.settings.dynamicRange)
        if let c = cached[mode], c.session == session.instanceID {
            if c.revision == revision { return c.built }
            // Only colour sliders moved: same composition, new values in its
            // look table. The picture changes without a rebuild or a flash.
            var same = c.project
            same.looks = project.looks
            if same == project {
                c.built.setLooks(project.looks)
                cached[mode] = (c.session, revision, project, c.built)
                return c.built
            }
        }
        let built = try await (mode == PreviewMode() ? builder : previewBuilder).build(
            project, package: session.url, hyperframes: hyperframes,
            mattes: mattes, matteSettings: editor.settings.current.matte, sdrPreview: mode.sdr, gamma: mode.gamma)
        cached[mode] = (session.instanceID, revision, project, built)
        return built
    }

    /// Drops the cached composition, for example after effect plug-ins reload.
    public func invalidate() { cached = [:] }

    public func composition(for project: Project, preview: PreviewMode = PreviewMode()) async throws -> BuiltComposition {
        let mode = preview.effective(in: project.settings.dynamicRange)
        return try await (mode == PreviewMode() ? builder : previewBuilder).build(
            project, package: await editor.session?.url, hyperframes: hyperframes,
            mattes: mattes, matteSettings: editor.settings.current.matte, sdrPreview: mode.sdr, gamma: mode.gamma)
    }
}
