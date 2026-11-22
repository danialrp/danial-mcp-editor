import EditorCore
import Foundation

/// Settings that belong to the user, not to a project. Stored outside the
/// repository and outside projects, in
/// `~/Library/Application Support/DanialMCPEditor/settings.json`, or under
/// `$DME_HOME` when that is set (tests use it).
public struct UserSettings: Codable, Equatable, Sendable {
    public struct MCP: Codable, Equatable, Sendable {
        public var port: Int
        /// Bearer token for the HTTP transport. Never returned by `settings.get`.
        public var token: String
    }

    /// Rules for automatic cutting and voice level. Values from the current
    /// production flow.
    public struct CutRules: Codable, Equatable, Sendable {
        public var talkingHeadSpeed: Double = 1.22
        public var silence = SilenceRules()
        public var joinFade: Double = 0.05
        public var voiceLoudnessLUFS: Double = -16
        public var voicePeakCeilingDB: Double = -1

        public init() {}

        // Older settings files lack some keys; missing ones take the defaults.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = CutRules()
            talkingHeadSpeed = try c.decodeIfPresent(Double.self, forKey: .talkingHeadSpeed) ?? d.talkingHeadSpeed
            silence = try c.decodeIfPresent(SilenceRules.self, forKey: .silence) ?? d.silence
            joinFade = try c.decodeIfPresent(Double.self, forKey: .joinFade) ?? d.joinFade
            voiceLoudnessLUFS = try c.decodeIfPresent(Double.self, forKey: .voiceLoudnessLUFS) ?? d.voiceLoudnessLUFS
            voicePeakCeilingDB = try c.decodeIfPresent(Double.self, forKey: .voicePeakCeilingDB) ?? d.voicePeakCeilingDB
        }
    }

    /// How the editor reaches the Edits app for transcription (requirement T-2).
    public struct EditsBridgeSettings: Codable, Equatable, Sendable {
        public var url = "http://127.0.0.1:19501/mcp"
        /// Bearer token shown by Edits. Empty: read it from the Edits server
        /// entry in ~/.claude.json, where the Edits setup put it. Never returned by settings.get.
        public var token = ""
        public var appPath = "/Applications/Edits.app"
        public var bundleID = "com.burbn.basel.mac"
        /// Edits can only import from ~/Movies.
        public var importFolder = "~/Movies/DanialMCPEditor"
        public var language = "en"
        /// How long a job waits for Edits to become free before giving up.
        public var waitWhenBusySeconds: Double = 1800

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = EditsBridgeSettings()
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
            token = try c.decodeIfPresent(String.self, forKey: .token) ?? d.token
            appPath = try c.decodeIfPresent(String.self, forKey: .appPath) ?? d.appPath
            bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? d.bundleID
            importFolder = try c.decodeIfPresent(String.self, forKey: .importFolder) ?? d.importFolder
            language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
            waitWhenBusySeconds = try c.decodeIfPresent(Double.self, forKey: .waitWhenBusySeconds) ?? d.waitWhenBusySeconds
        }
    }

    /// How HyperFrames compositions are rendered (section 11 of the architecture).
    public struct HyperFramesSettings: Codable, Equatable, Sendable {
        /// The HyperFrames command line, as program and arguments. The
        /// default runs the published package through npx; a machine can
        /// point it at its own wrapper that pins a version.
        public var command: [String] = ["npx", "--yes", "hyperframes"]
        /// Length of one rendered slice. A fix re-renders the slices it touches.
        public var sliceSeconds: Double = 5
        /// Slices rendered at once (each a Chrome of its own).
        public var parallelSlices: Int = 3
        /// HyperFrames render quality: draft, looks, standard or high.
        public var quality = "high"
        /// Quality of the cached slices (HEVC with alpha), 0 to 1.
        public var sliceQuality: Double = 0.9
        /// A slice whose render fails is tried again this many times.
        public var retries = 2

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = HyperFramesSettings()
            command = try c.decodeIfPresent([String].self, forKey: .command) ?? d.command
            sliceSeconds = try c.decodeIfPresent(Double.self, forKey: .sliceSeconds) ?? d.sliceSeconds
            parallelSlices = try c.decodeIfPresent(Int.self, forKey: .parallelSlices) ?? d.parallelSlices
            quality = try c.decodeIfPresent(String.self, forKey: .quality) ?? d.quality
            sliceQuality = try c.decodeIfPresent(Double.self, forKey: .sliceQuality) ?? d.sliceQuality
            retries = try c.decodeIfPresent(Int.self, forKey: .retries) ?? d.retries
        }
    }

    /// How person mattes are made and drawn (architecture section 11).
    public struct MatteSettings: Codable, Equatable, Sendable {
        /// Vision person segmentation quality: fast, balanced or accurate.
        public var quality = "accurate"
        /// Longest side of a stored matte, in pixels.
        public var maxSize = 1920
        /// Source seconds per cached chunk.
        public var chunkSeconds: Double = 5
        /// Chunks made at once.
        public var parallelChunks = 2
        /// Closing in time: a body part missing for up to this long on both
        /// sides of a frame is filled back in.
        public var closeSeconds: Double = 0.167
        /// The wide matte also covers where the person was this long before
        /// and after, so a fast hand is never cut off.
        public var growSeconds: Double = 0.034
        /// Quality of the stored matte video, 0 to 1.
        public var fileQuality: Double = 0.9
        /// What sits behind the person is cut this many output pixels inside
        /// the tight matte, softened over `cutSoftness` pixels.
        public var cutInset: Double = 1
        public var cutSoftness: Double = 1
        /// Which matte cuts what sits behind the person: tight (the person's
        /// outline) or wide (also covers fast, blurred
        /// hands, at the cost of a thin rim of room round them).
        public var cutWith = "tight"
        /// Vision masks only: what moves fast right next to the body (a
        /// blurred hand, fingertips) is added back. A pixel moves when its
        /// brightness (0-255) differs from both neighbouring frames by more
        /// than `motionThreshold`; it is added when connected to the body and
        /// at most `motionReach` matte pixels from it.
        public var motionFill = true
        public var motionThreshold: Double = 16
        public var motionReach: Double = 48
        /// Vision runs at most this many times a second of footage (0: every
        /// frame); frames between get the union of the masks either side.
        /// Vision is the slow part, so 60 fps footage makes its matte about
        /// twice as fast at 30.
        public var visionFps: Double = 30
        /// The edge drawn round the person in a composition's EDGE windows.
        public var edge = EdgeSettings()
        /// The shadow a depth composition's elements cast on the wall.
        public var shadow = ShadowSettings()

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = MatteSettings()
            quality = try c.decodeIfPresent(String.self, forKey: .quality) ?? d.quality
            maxSize = try c.decodeIfPresent(Int.self, forKey: .maxSize) ?? d.maxSize
            chunkSeconds = try c.decodeIfPresent(Double.self, forKey: .chunkSeconds) ?? d.chunkSeconds
            parallelChunks = try c.decodeIfPresent(Int.self, forKey: .parallelChunks) ?? d.parallelChunks
            closeSeconds = try c.decodeIfPresent(Double.self, forKey: .closeSeconds) ?? d.closeSeconds
            growSeconds = try c.decodeIfPresent(Double.self, forKey: .growSeconds) ?? d.growSeconds
            fileQuality = try c.decodeIfPresent(Double.self, forKey: .fileQuality) ?? d.fileQuality
            cutInset = try c.decodeIfPresent(Double.self, forKey: .cutInset) ?? d.cutInset
            cutSoftness = try c.decodeIfPresent(Double.self, forKey: .cutSoftness) ?? d.cutSoftness
            cutWith = try c.decodeIfPresent(String.self, forKey: .cutWith) ?? d.cutWith
            motionFill = try c.decodeIfPresent(Bool.self, forKey: .motionFill) ?? d.motionFill
            motionThreshold = try c.decodeIfPresent(Double.self, forKey: .motionThreshold) ?? d.motionThreshold
            motionReach = try c.decodeIfPresent(Double.self, forKey: .motionReach) ?? d.motionReach
            visionFps = try c.decodeIfPresent(Double.self, forKey: .visionFps) ?? d.visionFps
            edge = try c.decodeIfPresent(EdgeSettings.self, forKey: .edge) ?? d.edge
            shadow = try c.decodeIfPresent(ShadowSettings.self, forKey: .shadow) ?? d.shadow
        }
    }

    /// The lit outline of the person: it fills the band between the tight
    /// and the wide matte, grown outward. Radii are in pixels of a frame
    /// `referenceWidth` wide and scale with the output.
    public struct EdgeSettings: Codable, Equatable, Sendable {
        public var color = "#FFFFFF"
        public var referenceWidth: Double = 1080
        /// The band grows to `peakRadius` in `riseSeconds`, then settles to
        /// `restRadius` over `settleSeconds`.
        public var peakRadius: Double = 20
        public var restRadius: Double = 12
        public var riseSeconds: Double = 0.07
        public var settleSeconds: Double = 0.12
        /// Fade at the end of a window.
        public var fadeOutSeconds: Double = 0.0833
        /// Strength per frame after the edge comes on, at `blinkFps`; 1 after the list ends.
        public var blink: [Double] = [1, 1, 1, 0.25, 1, 1, 0.25, 1, 1, 1, 1, 1]
        public var blinkFps: Double = 60
        /// Softness of the matte edges, in pixels.
        public var softness: Double = 1.1
        /// Full strength from the top down to this fraction of the height,
        /// fading to nothing at `profileZeroAt`.
        public var profileFullTo: Double = 0.8125
        public var profileZeroAt: Double = 1

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = EdgeSettings()
            color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
            referenceWidth = try c.decodeIfPresent(Double.self, forKey: .referenceWidth) ?? d.referenceWidth
            peakRadius = try c.decodeIfPresent(Double.self, forKey: .peakRadius) ?? d.peakRadius
            restRadius = try c.decodeIfPresent(Double.self, forKey: .restRadius) ?? d.restRadius
            riseSeconds = try c.decodeIfPresent(Double.self, forKey: .riseSeconds) ?? d.riseSeconds
            settleSeconds = try c.decodeIfPresent(Double.self, forKey: .settleSeconds) ?? d.settleSeconds
            fadeOutSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? d.fadeOutSeconds
            blink = try c.decodeIfPresent([Double].self, forKey: .blink) ?? d.blink
            blinkFps = try c.decodeIfPresent(Double.self, forKey: .blinkFps) ?? d.blinkFps
            softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? d.softness
            profileFullTo = try c.decodeIfPresent(Double.self, forKey: .profileFullTo) ?? d.profileFullTo
            profileZeroAt = try c.decodeIfPresent(Double.self, forKey: .profileZeroAt) ?? d.profileZeroAt
        }
    }

    /// Voice-over recording (audio.record).
    public struct VoiceSettings: Codable, Equatable, Sendable {
        public var sampleRate: Double = 48_000
        public var channels = 1
        public var bitrateKbps = 192

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = VoiceSettings()
            sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? d.sampleRate
            channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? d.channels
            bitrateKbps = try c.decodeIfPresent(Int.self, forKey: .bitrateKbps) ?? d.bitrateKbps
        }
    }

    /// The shadow the elements of a depth composition cast on the wall
    /// behind the person, never on the person, so they sit in the room.
    /// Distances are in pixels of a frame `edge.referenceWidth` wide.
    public struct ShadowSettings: Codable, Equatable, Sendable {
        public var enabled = true
        public var color = "#000000"
        /// Darkness at the shadow's core, 0 to 1. Kept light.
        public var opacity: Double = 0.18
        /// Where it falls from the element: right and down are positive.
        public var offsetX: Double = 10
        public var offsetY: Double = 16
        /// Blur radius.
        public var blur: Double = 28
        /// Which elements cast it: back (between the person and the wall),
        /// front, or both.
        public var from = "both"

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = ShadowSettings()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
            opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
            offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? d.offsetX
            offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? d.offsetY
            blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? d.blur
            from = try c.decodeIfPresent(String.self, forKey: .from) ?? d.from
        }
    }

    /// How `browser.generateImage` drives the image site: its address and
    /// the names of its controls as `browser.read` shows them. Google AI
    /// Studio by default.
    public struct ImageSiteRecipe: Codable, Equatable, Sendable {
        /// `{model}` is replaced by the model id.
        public var url = "https://aistudio.google.com/prompts/new_chat?model={model}"
        public var model = "gemini-3-pro-image"
        /// Run settings chosen on every image unless the call says otherwise.
        public var defaults: [String: String] = ["Aspect ratio": "1:1", "Resolution": "4K"]
        public var prompt = "Enter a prompt"
        /// Input images go in like a person adds them: this button, then
        /// this menu item, then the file chooser.
        public var insert = "Insert images"
        public var upload = "Upload files"
        public var run = "Run"
        /// A button whose name contains this is shown while the site works.
        public var busy = "Stop"
        /// Page text that means the site failed this try.
        public var errors = ["Permission denied", "An internal error", "error has occurred", "Failed to generate"]
        /// Tries in a fresh session after an error before giving up.
        public var retries = 4
        /// Seconds to wait before each new try (the last repeats).
        public var retryWaitSeconds: [Double] = [5, 15, 30, 60]
        /// After the site stops working, how long a 4K picture may take to
        /// appear on the page.
        public var resultWaitSeconds: Double = 90
        /// Smallest result side, in pixels, that counts as the generated image.
        public var minResultSize = 1000
        /// A generated image's description starts with this; the inputs
        /// shown in the chat do not.
        public var resultName = "Generated Image"

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = ImageSiteRecipe()
            resultName = try c.decodeIfPresent(String.self, forKey: .resultName) ?? d.resultName
            busy = try c.decodeIfPresent(String.self, forKey: .busy) ?? d.busy
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
            defaults = try c.decodeIfPresent([String: String].self, forKey: .defaults) ?? d.defaults
            prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? d.prompt
            insert = try c.decodeIfPresent(String.self, forKey: .insert) ?? d.insert
            upload = try c.decodeIfPresent(String.self, forKey: .upload) ?? d.upload
            run = try c.decodeIfPresent(String.self, forKey: .run) ?? d.run
            errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? d.errors
            retries = try c.decodeIfPresent(Int.self, forKey: .retries) ?? d.retries
            retryWaitSeconds = try c.decodeIfPresent([Double].self, forKey: .retryWaitSeconds) ?? d.retryWaitSeconds
            resultWaitSeconds = try c.decodeIfPresent(Double.self, forKey: .resultWaitSeconds) ?? d.resultWaitSeconds
            minResultSize = try c.decodeIfPresent(Int.self, forKey: .minResultSize) ?? d.minResultSize
        }
    }

    /// The built-in browser (B-1): profiles keep their own sign-ins.
    public struct BrowserSettings: Codable, Equatable, Sendable {
        /// Profile name to the id of its website data store, made on first use.
        public var profiles: [String: String] = [:]
        public var defaultProfile = "main"
        /// Page a new session opens.
        public var homePage = "https://aistudio.google.com/prompts/new_chat"
        /// Size of the page when the browser is not shown in a window.
        public var width = 1280
        public var height = 900
        /// Images at least this many pixels on their shorter side count as results.
        public var resultMinSize = 256
        /// The browser's user agent: Safari's, which the engine is. Some
        /// sign-in pages refuse an unnamed embedded browser.
        /// Where downloads land; empty: the editor's cache.
        public var downloadFolder = ""
        /// A fresh session for every generated image: the site slows down
        /// badly from the third image of a chat, so one image per session is
        /// fastest, and a failed image is never revised in its own chat.
        public var freshSessionPerImage = true
        /// How `browser.generateImage` drives the image site.
        public var imageSite = ImageSiteRecipe()
        public var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = BrowserSettings()
            profiles = try c.decodeIfPresent([String: String].self, forKey: .profiles) ?? d.profiles
            defaultProfile = try c.decodeIfPresent(String.self, forKey: .defaultProfile) ?? d.defaultProfile
            homePage = try c.decodeIfPresent(String.self, forKey: .homePage) ?? d.homePage
            width = try c.decodeIfPresent(Int.self, forKey: .width) ?? d.width
            height = try c.decodeIfPresent(Int.self, forKey: .height) ?? d.height
            resultMinSize = try c.decodeIfPresent(Int.self, forKey: .resultMinSize) ?? d.resultMinSize
            userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? d.userAgent
            downloadFolder = try c.decodeIfPresent(String.self, forKey: .downloadFolder) ?? d.downloadFolder
            freshSessionPerImage = try c.decodeIfPresent(Bool.self, forKey: .freshSessionPerImage) ?? d.freshSessionPerImage
            imageSite = try c.decodeIfPresent(ImageSiteRecipe.self, forKey: .imageSite) ?? d.imageSite
        }
    }

    /// How the player shows the picture. Export is never affected.
    public struct PreviewSettings: Codable, Equatable, Sendable {
        public enum Range: String, Codable, CaseIterable, Sendable {
            /// The project's range when the timeline has HDR footage and the
            /// display has HDR; otherwise SDR, where raw footage looks as it does elsewhere.
            case auto
            /// Always the project's range.
            case project
            /// Always SDR.
            case sdr
        }

        /// How SDR looks in the preview. The two cannot both be matched: the
        /// editors they follow show the same file differently (measured).
        public enum Gamma: String, Codable, CaseIterable, Sendable {
            /// Gamma 1.961, as CapCut and plain players show a video file: grey 8 as 4 to 7.
            case video
            /// The camera curve of BT.709, as Edits shows an SDR project: lighter shadows, grey 8 as 20.
            case edits
        }

        public var dynamicRange = Range.auto
        public var gamma = Gamma.video

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dynamicRange = try c.decodeIfPresent(Range.self, forKey: .dynamicRange) ?? PreviewSettings().dynamicRange
            gamma = try c.decodeIfPresent(Gamma.self, forKey: .gamma) ?? PreviewSettings().gamma
        }

        /// Whether an HLG project plays as SDR. `displayHDR` is nil when no display is known.
        ///
        /// SDR footage sent to the screen as HLG is brighter or darker than
        /// the same file in a player, and changes with the display's
        /// headroom (measured).
        public func showsSDR(displayHDR: Bool?, hdrFootage: Bool) -> Bool {
            switch dynamicRange {
            case .auto: displayHDR == false || !hdrFootage
            case .project: false
            case .sdr: true
            }
        }
    }

    public var mcp: MCP
    public var undoDepth: Int
    public var recentProjects: [String]
    public var projectPresets: [String: ProjectSettings]
    public var cutRules: CutRules
    public var edits: EditsBridgeSettings
    public var exportPresets: [String: ExportPreset]
    public var export: ExportOptions
    public var hyperframes: HyperFramesSettings
    public var matte: MatteSettings
    public var browser: BrowserSettings
    public var voice = VoiceSettings()
    public var downloader = DownloaderSettings()
    public var preview = PreviewSettings()

    public init(mcp: MCP, undoDepth: Int, recentProjects: [String], projectPresets: [String: ProjectSettings],
                cutRules: CutRules, edits: EditsBridgeSettings,
                exportPresets: [String: ExportPreset] = ExportPreset.shipped, export: ExportOptions = ExportOptions(),
                hyperframes: HyperFramesSettings = HyperFramesSettings(), matte: MatteSettings = MatteSettings(), browser: BrowserSettings = BrowserSettings()) {
        self.mcp = mcp
        self.undoDepth = undoDepth
        self.recentProjects = recentProjects
        self.projectPresets = projectPresets
        self.cutRules = cutRules
        self.edits = edits
        self.exportPresets = exportPresets
        self.export = export
        self.hyperframes = hyperframes
        self.matte = matte
        self.browser = browser
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserSettings.defaults()
        mcp = try c.decodeIfPresent(MCP.self, forKey: .mcp) ?? d.mcp
        undoDepth = try c.decodeIfPresent(Int.self, forKey: .undoDepth) ?? d.undoDepth
        recentProjects = try c.decodeIfPresent([String].self, forKey: .recentProjects) ?? []
        projectPresets = try c.decodeIfPresent([String: ProjectSettings].self, forKey: .projectPresets) ?? d.projectPresets
        cutRules = try c.decodeIfPresent(CutRules.self, forKey: .cutRules) ?? d.cutRules
        edits = try c.decodeIfPresent(EditsBridgeSettings.self, forKey: .edits) ?? d.edits
        exportPresets = try c.decodeIfPresent([String: ExportPreset].self, forKey: .exportPresets) ?? d.exportPresets
        export = try c.decodeIfPresent(ExportOptions.self, forKey: .export) ?? d.export
        hyperframes = try c.decodeIfPresent(HyperFramesSettings.self, forKey: .hyperframes) ?? d.hyperframes
        matte = try c.decodeIfPresent(MatteSettings.self, forKey: .matte) ?? d.matte
        browser = try c.decodeIfPresent(BrowserSettings.self, forKey: .browser) ?? d.browser
        voice = try c.decodeIfPresent(VoiceSettings.self, forKey: .voice) ?? d.voice
        downloader = try c.decodeIfPresent(DownloaderSettings.self, forKey: .downloader) ?? d.downloader
        preview = try c.decodeIfPresent(PreviewSettings.self, forKey: .preview) ?? d.preview
    }

    public static func defaults() -> UserSettings {
        UserSettings(
            mcp: MCP(port: 19700, token: randomToken()),
            undoDepth: 500,
            recentProjects: [],
            projectPresets: [
                "reel": ProjectSettings(width: 1440, height: 2560, frameRate: .fps60, dynamicRange: .hlg),
                "youtube": ProjectSettings(width: 3840, height: 2160, frameRate: .fps60, dynamicRange: .sdr),
                "lesson": ProjectSettings(width: 1920, height: 1080, frameRate: .fps30, dynamicRange: .sdr),
            ],
            cutRules: CutRules(),
            edits: EditsBridgeSettings())
    }

    static func randomToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }
}

/// Loads and saves user settings. The file is created on first use with
/// owner-only permissions, because it holds the MCP token.
public final class UserSettingsStore: @unchecked Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("settings.json") }
    private let lock = NSLock()
    private var cached: UserSettings

    public init(directory: URL? = nil) throws {
        let dir = directory ?? Self.defaultDirectory()
        self.directory = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url) {
            cached = try JSONDecoder().decode(UserSettings.self, from: data)
        } else {
            cached = .defaults()
            try Self.write(cached, to: url)
        }
    }

    public static func defaultDirectory() -> URL {
        if let home = ProcessInfo.processInfo.environment["DME_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DanialMCPEditor", isDirectory: true)
    }

    public var current: UserSettings {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public func update(_ change: (inout UserSettings) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var s = cached
        try change(&s)
        try Self.write(s, to: fileURL)
        cached = s
    }

    /// Settings as JSON without the token.
    public func publicJSON() throws -> JSONValue {
        var v = try JSONValue(encoding: current)
        if case .object(var o) = v, case .object(var mcp) = o["mcp"] ?? .null {
            mcp.removeValue(forKey: "token")
            o["mcp"] = .object(mcp)
            if case .object(var e) = o["edits"] ?? .null {
                e["token"] = .string(((e["token"]?.stringValue) ?? "").isEmpty ? "" : "(set)")
                o["edits"] = .object(e)
            }
            v = .object(o)
        }
        return v
    }

    /// Sets one value by dotted key, for example `cutRules.minPause`. Only keys
    /// that already exist can be set, and the value must keep its type.
    public func set(key: String, value: JSONValue) throws {
        let parts = key.split(separator: ".").map(String.init)
        guard !parts.isEmpty, parts != ["mcp", "token"], parts != ["edits", "token"] else {
            throw EditorError.invalid("\(key) cannot be set here", parameter: "key")
        }
        try update { s in
            var tree = try JSONValue(encoding: s)
            tree = try Self.replacing(tree, at: parts[...], with: value, key: key, allowNewKey: parts.first == "projectPresets")
            do {
                s = try tree.decode(UserSettings.self)
            } catch let e as DecodingError {
                throw EditorError.invalid("invalid value for \(key): \(describe(e))", parameter: "value")
            }
        }
    }

    private static func replacing(_ node: JSONValue, at path: ArraySlice<String>, with value: JSONValue,
                                  key: String, allowNewKey: Bool) throws -> JSONValue {
        guard let head = path.first else { return value }
        guard case .object(var o) = node else { throw EditorError.invalid("\(key) is not a settings key", parameter: "key") }
        if o[head] == nil && !(allowNewKey && path.count == 1) {
            throw EditorError.invalid("\(key) is not a settings key", parameter: "key")
        }
        o[head] = try replacing(o[head] ?? .object([:]), at: path.dropFirst(), with: value, key: key, allowNewKey: allowNewKey)
        return .object(o)
    }

    private static func write(_ s: UserSettings, to url: URL) throws {
        try JSON.prettyEncoder.encode(s).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
