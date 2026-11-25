import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing

/// accent.export writes the pick in the shape the hyperframes skill's
/// picker saves it: its mode names, angle only for a gradient, hi_pct only
/// for the mix, and c1 to c3.
@Suite struct AccentExportTests {
    func pick(_ a: Accent) -> [String: JSONValue] {
        guard case .object(let o) = HyperFramesTools.skillPick(a, savedAt: Date(timeIntervalSince1970: 0)) else { return [:] }
        return o
    }

    @Test func threeColoursWithAHandPickedLight() {
        let o = pick(Accent(mode: .three, stops: ["#FFD23F", "#7A3CFF", "#2E6BF0"], angle: 120, hiColor: "#EEEEEE"))
        #expect(o["mode"] == .string("tri"))
        #expect(o["angle"] == .null && o["hi_pct"] == .null)
        #expect(o["hi_mode"] == .string("manual") && o["acc_hi"] == .string("#EEEEEE"))
        #expect(o["c1"] == .string("#FFD23F") && o["c2"] == .string("#7A3CFF") && o["c3"] == .string("#2E6BF0"))
        #expect(o["stops"] == .array([.string("#FFD23F"), .string("#7A3CFF"), .string("#2E6BF0")]))
    }

    @Test func gradientWithTheMix() {
        let o = pick(Accent(mode: .gradient, stops: ["#FF0000", "#0000FF", "#00FF00"], angle: 120))
        #expect(o["mode"] == .string("grad") && o["angle"] == .number(120))
        #expect(o["hi_pct"] == .number(72) && o["hi_mode"] == .string("auto") && o["acc_hi"] == .string("#FFB8B8"))
        #expect(o["c3"] == .string("#0000FF"), "c3 falls back to the second colour")
        #expect(o["stops"] == .array([.string("#FF0000"), .string("#0000FF")]))
    }
}
