import Foundation

extension UserSettings {
    /// The social-media downloader (`social.*` tools): yt-dlp as an external
    /// command, where downloads go, and how they are inspected.
    public struct DownloaderSettings: Codable, Equatable, Sendable {
        /// yt-dlp as program and arguments. A bare name is looked up in
        /// PATH, then in `searchFolders`; a path is used as it is.
        public var command: [String] = ["yt-dlp"]
        /// ffmpeg, which yt-dlp needs to join picture and sound and to
        /// extract audio. Found the same way; without it only single-file
        /// formats can be downloaded.
        public var ffmpeg = "ffmpeg"
        /// Folders searched after PATH for the commands.
        public var searchFolders = ["/opt/homebrew/bin", "/usr/local/bin"]
        /// Passed to yt-dlp `--cookies-from-browser` (for example "safari"
        /// or "chrome") for items that need a signed-in session. Empty: off.
        public var cookiesFromBrowser = ""
        /// Arguments added to every yt-dlp call.
        public var extraArguments: [String] = []
        /// Folder inside the open project package that downloads go to.
        public var projectFolder = "downloads"
        /// Where downloads go when no project is open. Empty: `downloads`
        /// next to the settings file (Application Support).
        public var cacheFolder = ""
        /// Named qualities: yt-dlp arguments that choose the format. Video
        /// prefers H.264 and AAC in MP4, which AVFoundation reads.
        public var qualities: [String: [String]] = [
            "best": ["-f", "bv*+ba/b", "-S", "vcodec:h264,acodec:aac,ext:mp4:m4a"],
            "1080": ["-f", "bv*+ba/b", "-S", "res:1080,vcodec:h264,acodec:aac,ext:mp4:m4a"],
            "720": ["-f", "bv*+ba/b", "-S", "res:720,vcodec:h264,acodec:aac,ext:mp4:m4a"],
            "480": ["-f", "bv*+ba/b", "-S", "res:480,vcodec:h264,acodec:aac,ext:mp4:m4a"],
        ]
        public var defaultQuality = "1080"
        /// Container for joined picture and sound.
        public var mergeFormat = "mp4"
        /// What `what: audio` downloads, and the format it is converted to.
        public var audioFormat = "ba[ext=m4a]/ba/b"
        public var audioCodec = "m4a"
        /// Items taken from a playlist, carousel or multi-video post at most.
        public var playlistLimit = 20
        /// Subtitle and caption languages asked for (yt-dlp `--sub-langs`,
        /// each a regular expression). `-orig` is YouTube's caption in the
        /// spoken language; a wide pattern such as `en.*` also asks for
        /// every machine translation, which is many requests.
        public var subtitleLanguages = ["en", "en-US", "en-GB", "en-orig"]
        /// Seconds a download may take, and a metadata or page read.
        public var downloadTimeoutSeconds: Double = 1800
        public var infoTimeoutSeconds: Double = 120
        /// User agent for reading a post's page when yt-dlp finds no media
        /// (og:image and og:video tags) and for fetching pictures.
        public var pageUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        /// yt-dlp error text that means the site wants a signed-in session.
        public var loginHints = ["sign in to confirm", "login required", "log in", "login to", "requires authentication",
                                 "use --cookies", "private", "rate-limit", "rate limit", "not available in your country"]
        /// yt-dlp error text that means the post has no video: pictures are
        /// then taken from its metadata or its page.
        public var noVideoHints = ["no video formats found", "no video could be found", "there is no video",
                                   "no media found", "unsupported url"]
        /// `social.inspect` defaults: frames in the contact sheet, frames per
        /// row, width of each, and separate frames saved.
        public var sheetFrames = 12
        public var sheetColumns = 4
        public var frameWidth = 480
        public var frames = 0
        /// Longest subtitle text returned inline, in characters.
        public var maxTextCharacters = 20_000
        /// Loudness is measured for sound up to this long.
        public var loudnessMaxSeconds: Double = 1800

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = DownloaderSettings()
            command = try c.decodeIfPresent([String].self, forKey: .command) ?? d.command
            ffmpeg = try c.decodeIfPresent(String.self, forKey: .ffmpeg) ?? d.ffmpeg
            searchFolders = try c.decodeIfPresent([String].self, forKey: .searchFolders) ?? d.searchFolders
            cookiesFromBrowser = try c.decodeIfPresent(String.self, forKey: .cookiesFromBrowser) ?? d.cookiesFromBrowser
            extraArguments = try c.decodeIfPresent([String].self, forKey: .extraArguments) ?? d.extraArguments
            projectFolder = try c.decodeIfPresent(String.self, forKey: .projectFolder) ?? d.projectFolder
            cacheFolder = try c.decodeIfPresent(String.self, forKey: .cacheFolder) ?? d.cacheFolder
            qualities = try c.decodeIfPresent([String: [String]].self, forKey: .qualities) ?? d.qualities
            defaultQuality = try c.decodeIfPresent(String.self, forKey: .defaultQuality) ?? d.defaultQuality
            mergeFormat = try c.decodeIfPresent(String.self, forKey: .mergeFormat) ?? d.mergeFormat
            audioFormat = try c.decodeIfPresent(String.self, forKey: .audioFormat) ?? d.audioFormat
            audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec) ?? d.audioCodec
            playlistLimit = try c.decodeIfPresent(Int.self, forKey: .playlistLimit) ?? d.playlistLimit
            subtitleLanguages = try c.decodeIfPresent([String].self, forKey: .subtitleLanguages) ?? d.subtitleLanguages
            downloadTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .downloadTimeoutSeconds) ?? d.downloadTimeoutSeconds
            infoTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .infoTimeoutSeconds) ?? d.infoTimeoutSeconds
            pageUserAgent = try c.decodeIfPresent(String.self, forKey: .pageUserAgent) ?? d.pageUserAgent
            loginHints = try c.decodeIfPresent([String].self, forKey: .loginHints) ?? d.loginHints
            noVideoHints = try c.decodeIfPresent([String].self, forKey: .noVideoHints) ?? d.noVideoHints
            sheetFrames = try c.decodeIfPresent(Int.self, forKey: .sheetFrames) ?? d.sheetFrames
            sheetColumns = try c.decodeIfPresent(Int.self, forKey: .sheetColumns) ?? d.sheetColumns
            frameWidth = try c.decodeIfPresent(Int.self, forKey: .frameWidth) ?? d.frameWidth
            frames = try c.decodeIfPresent(Int.self, forKey: .frames) ?? d.frames
            maxTextCharacters = try c.decodeIfPresent(Int.self, forKey: .maxTextCharacters) ?? d.maxTextCharacters
            loudnessMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .loudnessMaxSeconds) ?? d.loudnessMaxSeconds
        }
    }
}
