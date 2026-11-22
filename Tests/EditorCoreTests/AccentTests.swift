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
}
