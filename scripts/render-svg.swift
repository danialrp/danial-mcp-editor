// Renders an SVG to a square PNG with a transparent background, using the
// WebKit that ships with macOS (no third-party tools).
//
//   swift scripts/render-svg.swift <in.svg> <out.png> <pixels>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 4, let px = Int(args[3]) else {
    FileHandle.standardError.write("usage: render-svg.swift <in.svg> <out.png> <pixels>\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1]).standardizedFileURL
let output = URL(fileURLWithPath: args[2])

@MainActor final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    let px: Int, input: URL, output: URL

    init(size: Int, input: URL, output: URL) {
        px = size
        self.input = input
        self.output = output
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        web = WKWebView(frame: frame)
        web.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        super.init()
        web.navigationDelegate = self
    }

    func load() {
        // Inline the SVG: a page loaded from a string may not read local files.
        guard let svg = try? String(contentsOf: input, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(input.path)\n".data(using: .utf8)!)
            exit(1)
        }
        let html = """
        <html><head><style>html,body{margin:0;background:transparent}svg{display:block;width:\(px)px;height:\(px)px}</style></head>
        <body>\(svg)</body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            let px = self.px, output = self.output
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: px, height: px)
            self.web.takeSnapshot(with: config) { image, error in
                guard let image else {
                    FileHandle.standardError.write("snapshot failed: \(String(describing: error))\n".data(using: .utf8)!)
                    exit(1)
                }
                // Redraw at exactly px × px, whatever the screen's scale.
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.imageInterpolation = .high
                image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                do {
                    try rep.representation(using: .png, properties: [:])!.write(to: output)
                    exit(0)
                } catch {
                    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let r = Renderer(size: px, input: input, output: output)
    r.load()
    objc_setAssociatedObject(NSApp!, "renderer", r, .OBJC_ASSOCIATION_RETAIN)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    FileHandle.standardError.write("timed out\n".data(using: .utf8)!)
    exit(1)
}
NSApp.run()
