@testable import EditorCore
import Foundation
import Testing

/// The accent's derived values match the hyperframes skill's picker
/// (reference numbers computed with the picker's own JavaScript).
@Suite struct AccentTests {
    @Test(arguments: [
        ("#FF0000", 4.9312, 3.9985, 4.8481, "#FFB8B8"),
        ("#2E6BF0", 4.2040, 4.6901, 4.1332, "#C4D6FB"),
        ("#FFD23F", 13.6541, 1.4441, 13.4241, "#FFF2C9"),
        ("#7A3CFF", 3.6785, 5.3601, 3.6166, "#DAC8FF"),
    ])
    func matchesTheSkillsPicker(_ c: String, _ dark: Double, _ white: Double, _ glass: Double, _ hi: String) {
        let a = Accent(mode: .solid, stops: [c])
        #expect(abs(a.inkContrasts.dark - dark) < 0.0005)
        #expect(abs(a.inkContrasts.white - white) < 0.0005)
        #expect(abs(a.glassContrast - glass) < 0.0005)
        #expect(a.accHi == hi)
        #expect(a.ink == (dark >= white ? Accent.dark : Accent.white))
    }

    @Test func gradientTakesTheWorstStopAndWritesItsAngle() {
        let a = Accent(mode: .gradient, stops: ["#FFD23F", "#7A3CFF"], angle: 120)
        #expect(a.acc == "#FFD23F" && a.acc2 == "#7A3CFF")
        // Dark ink: min(13.65, 3.68) = 3.68; white: min(1.44, 5.36) = 1.44.
        #expect(a.ink == Accent.dark && abs(a.inkContrast - 3.6785) < 0.0005)
        #expect(a.css.contains("--acc-grad: linear-gradient(120deg, var(--acc), var(--acc2));"))
    }

    @Test func theCommandValidatesAndClears() throws {
        var p = Project(id: "p", name: "p", settings: ProjectSettings(width: 1080, height: 1920, frameRate: .fps60, dynamicRange: .sdr))
        try SetAccent(mode: "gradient", stops: ["#ff0000", "0af"], angle: 90).apply(to: &p)
        #expect(p.accent?.stops == ["#FF0000", "#00AAFF"])
        #expect(throws: EditorError.self) { try SetAccent(mode: "gradient", stops: ["#ff0000"]).apply(to: &p) }
        #expect(throws: EditorError.self) { try SetAccent(mode: "solid", stops: ["red"]).apply(to: &p) }
        try SetAccent(mode: "none").apply(to: &p)
        #expect(p.accent == nil)
    }

    @Test func threeColoursTakeTheWorstOfAllThreeAndWriteThem() throws {
        let a = try Accent(mode: .three, stops: ["#ffd23f", "#7A3CFF", "#2E6BF0"]).validated()
        #expect(a.c1 == "#FFD23F" && a.c2 == "#7A3CFF" && a.c3 == "#2E6BF0")
        #expect(a.acc == "#FFD23F" && a.acc2 == "#7A3CFF")
        // Dark: min(13.65, 3.68, 4.20); white: min(1.44, 5.36, 4.69); glass: min(13.42, 3.62, 4.13).
        #expect(a.ink == Accent.dark && abs(a.inkContrast - 3.6785) < 0.0005)
        #expect(abs(a.glassContrast - 3.6166) < 0.0005)
        #expect(a.css.hasSuffix("--c1: #FFD23F; --c2: #7A3CFF; --c3: #2E6BF0;"))
        #expect(!a.css.contains("--acc-grad"))
        // Fewer colours: c3 falls back to the second, then the first.
        #expect(Accent(mode: .gradient, stops: ["#FF0000", "#0000FF"]).c3 == "#0000FF")
        #expect(Accent(mode: .solid, stops: ["#FF0000"]).c3 == "#FF0000")
        #expect(Accent(mode: .solid, stops: ["#FF0000"]).css.hasSuffix("/* solid: --acc2 = --acc */"))
        #expect(throws: EditorError.self) { try Accent(mode: .three, stops: ["#FF0000", "#00FF00"]).validated() }
    }

    @Test func theLightColourCanBePickedByHand() throws {
        var p = Project(id: "p", name: "p", settings: ProjectSettings(width: 1080, height: 1920, frameRate: .fps60, dynamicRange: .sdr))
        try SetAccent(mode: "solid", stops: ["#FF0000"], hiColor: "#00ff88").apply(to: &p)
        #expect(p.accent?.accHi == "#00FF88" && p.accent?.hiManual == true)
        #expect(p.accent?.css.contains("--acc-hi: #00FF88;") == true)
        // Kept when only the colour changes.
        try SetAccent(mode: "solid", stops: ["#2E6BF0"]).apply(to: &p)
        #expect(p.accent?.accHi == "#00FF88")
        // hiPercent alone, or auto, goes back to the mix.
        try SetAccent(mode: "solid", hiPercent: 72).apply(to: &p)
        #expect(p.accent?.accHi == "#C4D6FB" && p.accent?.hiManual == false)
        try SetAccent(mode: "solid", hiColor: "#123456").apply(to: &p)
        try SetAccent(mode: "solid", hiColor: "auto").apply(to: &p)
        #expect(p.accent?.accHi == "#C4D6FB")
        #expect(throws: EditorError.self) { try SetAccent(mode: "solid", hiColor: "light").apply(to: &p) }
    }

    @Test func anAccentSavedBeforeTheseChangesStillLoads() throws {
        let old = ##"{"mode":"gradient","stops":["#FF0000","#0000FF"],"angle":90,"hiPercent":60}"##
        let a = try JSONDecoder().decode(Accent.self, from: Data(old.utf8))
        #expect(a.mode == .gradient && a.hiColor == nil && a.accHi == Accent.mixWhite("#FF0000", 60))
    }
}
