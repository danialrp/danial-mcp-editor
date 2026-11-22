import EditorCore
import Foundation
@testable import MediaEngine
import Testing

/// SDR footage in an HLG project must look on an HLG display as it did in
/// SDR (BT.2408): not darker, not harsher, colours unchanged. Checked against
/// the BT.2100 reference display (1000 cd/m², system gamma 1.2, SDR white at
/// 203 cd/m²), written out here independently of the shader.
@Suite("SDR in HLG")
struct HLGConversionTests {
    static let m709to2020: [[Double]] = [[0.6274, 0.3293, 0.0433], [0.0691, 0.9195, 0.0114], [0.0164, 0.0880, 0.8956]]

    /// What the reference HLG display shows for a signal, as SDR R'G'B'.
    static func referenceDisplay(_ s: RGB) -> RGB {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        func inv(_ x: Double) -> Double { x <= 0.5 ? x * x / 3 : (exp((x - c) / a) + b) / 12 }
        let e = RGB(inv(s.x), inv(s.y), inv(s.z))
        let ys = max(0.2627 * e.x + 0.6780 * e.y + 0.0593 * e.z, 1e-9)
        let d = e * pow(ys, 0.2) / 0.203          // OOTF, in units of SDR white
        // 2020 back to 709: solve m709to2020 * x = d.
        let m = m709to2020
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        func col(_ i: Int, _ v: RGB) -> [[Double]] { var n = m; for r in 0..<3 { n[r][i] = v[r] }; return n }
        func dt(_ n: [[Double]]) -> Double { n[0][0] * (n[1][1] * n[2][2] - n[1][2] * n[2][1]) - n[0][1] * (n[1][0] * n[2][2] - n[1][2] * n[2][0]) + n[0][2] * (n[1][0] * n[2][1] - n[1][1] * n[2][0]) }
        let lin = RGB(dt(col(0, d)) / det, dt(col(1, d)) / det, dt(col(2, d)) / det)
        return RGB(pow(min(max(lin.x, 0), 1), 1 / 2.4), pow(min(max(lin.y, 0), 1), 1 / 2.4), pow(min(max(lin.z, 0), 1), 1 / 2.4))
    }

    @Test func sdrLooksTheSameOnAnHLGDisplay() async throws {
        let hlg = try await LookRender.render(nil, hdr: true)
        var worst = 0.0, at = 0
        var lumaIn = 0.0, lumaOut = 0.0
        for y in stride(from: 0, to: Chart.height, by: 4) {
            for x in stride(from: 0, to: Chart.width, by: 4) where y / Chart.patch != 2 || x / Chart.patch > 2 {
                let want = Chart.pixel(x, y), got = Self.referenceDisplay(hlg.at(x, y))
                let d = (got.linear - want.linear).abs().max()
                if d > worst { worst = d; at = y * Chart.width + x }
                lumaIn += Chart.luma(want); lumaOut += Chart.luma(got)
            }
        }
        #expect(worst < 0.004, "worst \(worst) of white in linear light, at pixel \(at)")
        #expect(abs(lumaOut - lumaIn) / lumaIn < 0.01, "brightness kept: \(lumaOut / lumaIn)")
    }

    /// HLG into an SDR project is the same display mapping, so SDR → HLG → SDR returns the picture.
    @Test func roundTrip() async throws {
        let hlg = try await LookRender.render(nil, hdr: true)
        let back = try await LookRender.render(nil, pixel: { hlg.at($0, $1) }, sourceHLG: true)
        var worst = 0.0
        for y in stride(from: 0, to: Chart.patch * 2, by: 4) {
            for x in stride(from: 0, to: Chart.width, by: 4) {
                let w = Chart.pixel(x, y)
                // The SDR side rolls off above 80% linear, so compare below that.
                guard pow(w.max(), 2.4) < 0.75 else { continue }
                worst = max(worst, (back.at(x, y).linear - w.linear).abs().max())
            }
        }
        #expect(worst < 0.01, "worst \(worst) of white in linear light (the HLG picture passes through 8 bits)")
    }
}

private extension SIMD3 where Scalar == Double {
    func abs() -> Self { Self(Swift.abs(x), Swift.abs(y), Swift.abs(z)) }
    /// Display light (BT.1886), where a difference means the same at every level.
    var linear: Self { Self(pow(Swift.max(x, 0), 2.4), pow(Swift.max(y, 0), 2.4), pow(Swift.max(z, 0), 2.4)) }
}
