import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing
import WebKit

/// The built-in browser driven the way an agent drives it (B-2, B-3, B-6),
/// on a local page that stands in for an image generator.
@Suite("Browser", .serialized)
@MainActor
struct BrowserTests {
    static let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/browser/page.html")

    func ref(_ read: JSONValue, _ name: String) throws -> String {
        let els = read.objectValue?["elements"]?.arrayValue ?? []
        let e = try #require(els.first { $0.objectValue?["name"]?.stringValue == name }, "no element named \(name)")
        return e.objectValue!["ref"]!.stringValue!
    }

    func log(_ host: BrowserHost) async throws -> String {
        try await host.js("return document.getElementById('log').textContent;") as? String ?? ""
    }

    @Test func anAgentFillsThePageGeneratesAndSavesTheResult() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-br-\(UUID().uuidString)")
        let settings = try UserSettingsStore(directory: dir)
        let host = BrowserHost(settings: settings)
        let profile = "test-\(UUID().uuidString.prefix(8))"
        try await host.open(profile: profile, layout: .hidden, url: Self.page)
        defer {
            if let id = settings.current.browser.profiles[profile].flatMap(UUID.init(uuidString:)) {
                WKWebsiteDataStore.remove(forIdentifier: id) { _ in }
            }
        }
        let page = try await host.read()
        // No images yet: an empty list, not a missing one.
        let none = try await host.results()
        #expect(none.objectValue?["pageImages"]?.arrayValue?.isEmpty == true, "\(none)")
        #expect(page.objectValue?["title"]?.stringValue == "Generator test")

        // Sign-in is the owner's: no typing into a password field.
        await #expect(throws: EditorError.self) { try await host.type(try ref(page, "Password"), text: "secret") }

        // A menu item checkbox (Gemini's "Create image" tool) is listed and clicks.
        try await host.click(try ref(page, "Create image"))
        #expect(try await log(host).contains("tool on"))
        try await host.type(try ref(page, "Name"), text: "cover")
        try await host.type(try ref(page, "Prompt"), text: "a red square")
        try await host.select(try ref(page, "Model"), option: "Pro")
        try await host.attach(try ref(page, "Upload"), files: [Self.page])
        try await host.attach(try ref(page, "Drop here"), files: [Self.page], drop: true)
        // A button that opens a file chooser: the chooser gets the files.
        try await host.attach(try ref(page, "Choose files"), files: [Self.page])
        try await host.click(try ref(page, "Generate"))
        _ = try await host.waitFor(text: "image ready", ref: nil, gone: false, download: false, timeout: 10)
        let text = try await log(host)
        #expect(text.contains("files page.html:"), "\(text)")
        #expect(text.contains("dropped page.html"), "\(text)")
        #expect(text.contains("chosen page.html"), "\(text)")
        #expect(text.contains("clicked 1 prompt=a red square model=Pro name=cover"), "\(text)")

        // A real click reaches the page as a trusted event.
        try await host.click(try ref(page, "Generate"), trusted: true)
        let after = try await log(host)
        #expect(after.contains("clicked 2 trusted"), "\(after)")

        // The result: listed, read at full quality, captured.
        let results = try await host.results()
        let images = results.objectValue?["pageImages"]?.arrayValue ?? []
        #expect(images.count >= 1)
        let imageRef = try #require(images.first?.objectValue?["ref"]?.stringValue)
        let (data, _) = try await host.resultData(ref: imageRef, download: nil)
        #expect(BrowserTools.imageExtension(data) == "png")
        let shot = try await host.capture(imageRef)
        #expect(shot.width >= 100)

        // A new session keeps the profile, drops the page.
        try await host.newSession(url: URL(string: "about:blank"))
        #expect(host.profile == profile && host.webView?.url?.absoluteString == "about:blank")
    }
}
