import Combine
import SwiftUI

// Rolling bar visualization of the rumble command stream we hand to the NS2
// profile's encodeRumble. Each tick advances by one sample: hi-frequency motor
// (RumbleCommand.rightAmp) grows up from the center, low-frequency motor
// (RumbleCommand.leftAmp) grows down. When no rumble cmd has arrived recently
// the meter scrolls zero samples so the bars decay visibly.
struct RumbleMeterView: View {
    let latest: RumbleCommand
    let lastUpdate: Date
    var tint: Color = .accentColor

    private static let sampleCount = 80
    private static let tickInterval: TimeInterval = 1.0 / 30.0
    private static let staleAfter: TimeInterval = 0.2

    @State private var samples: [RumbleCommand] = Array(
        repeating: RumbleCommand(),
        count: RumbleMeterView.sampleCount
    )
    @State private var ticker = Timer
        .publish(every: RumbleMeterView.tickInterval, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Canvas(opaque: false) { ctx, size in
            draw(in: ctx, size: size)
        }
        .frame(height: 36)
        .onReceive(ticker) { _ in
            let stale = Date().timeIntervalSince(lastUpdate) > Self.staleAfter
            samples.removeFirst()
            samples.append(stale ? RumbleCommand() : latest)
        }
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let count = samples.count
        let spacing: CGFloat = 1
        let barWidth = max(1, (size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let centerY = size.height / 2
        let halfH = centerY - 1

        let line = Path(CGRect(x: 0, y: centerY - 0.5, width: size.width, height: 1))
        ctx.fill(line, with: .color(tint.opacity(0.18)))

        for (i, s) in samples.enumerated() {
            let x = CGFloat(i) * (barWidth + spacing)
            let hiH = halfH * CGFloat(s.rightAmp) / CGFloat(UInt16.max)
            let loH = halfH * CGFloat(s.leftAmp)  / CGFloat(UInt16.max)
            if hiH > 0 {
                let rect = CGRect(x: x, y: centerY - hiH, width: barWidth, height: hiH)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tint))
            }
            if loH > 0 {
                let rect = CGRect(x: x, y: centerY, width: barWidth, height: loH)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tint))
            }
        }
    }
}
