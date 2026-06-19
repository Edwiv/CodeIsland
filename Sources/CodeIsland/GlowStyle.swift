import SwiftUI
import CodeIslandCore

/// Glow-ring palette + background, ported from AgentIsland's `island-frame` drop-shadow
/// glow (island.css). The colored halo bleeds out from behind the solid black island
/// shape, producing a soft ring. Driven by the aggregate agent status plus a one-shot
/// "done" flash (R6).
enum IslandGlowPalette {
    static let running   = Color(red: 0.43, green: 0.62, blue: 1.0)   // #6e9fff
    static let attention = Color(red: 1.0,  green: 0.62, blue: 0.04)  // #ff9f0a
    static let done      = Color(red: 0.26, green: 0.91, blue: 0.42)  // #42e86b

    /// Steady glow (color, whether it pulses) for an aggregate status.
    /// Returns nil for idle — no steady glow when nothing is happening.
    static func steady(for status: AgentStatus) -> (color: Color, pulse: Bool)? {
        switch status {
        case .waitingApproval, .waitingQuestion: return (attention, true)
        case .running, .processing:              return (running, false)
        case .idle:                              return nil
        }
    }
}

/// Renders the island's solid shape with a status-driven glow ring behind it.
/// - working (running/processing): steady soft blue
/// - awaiting approval/question: pulsing orange (breathing)
/// - just completed: one-shot green flash (keyed off `doneNonce`)
///
/// `intensity` (1.0 = 100%) scales the waiting/done halos; `runningIntensity` scales the
/// steady running (blue) halo independently so the always-on "working" glow can be dialed
/// separately. Final opacities are clamped to [0, 1].
struct IslandGlowBackground<S: Shape>: View {
    let shape: S
    let status: AgentStatus
    let doneNonce: Int
    let enabled: Bool
    /// True while the completion ("done") card is being presented. Drives a sustained
    /// green ring for the full card lifetime, rather than only the ~1s one-shot flash.
    var completing: Bool = false
    var intensity: Double = 1.3
    var runningIntensity: Double = 1.0

    @State private var pulse = false
    @State private var flash: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func scaled(_ v: Double, _ factor: Double) -> Double { min(1.0, max(0.0, v * factor)) }

    /// A soft halo built from three graduated blur layers: a wide faint wash, a mid ring,
    /// and a tight bright core. The wide layer is what rounds off the silhouette — a single
    /// tight blur leaves the rounded-rect's straight edges and corners visible (the "直角"
    /// the ring used to show). Opacity (not radius) is what the breathing animates, so the
    /// extra layers stay cheap: the compositor caches each blurred layer and only cross-fades.
    @ViewBuilder
    private func halo(_ color: Color, base: Double, factor: Double) -> some View {
        let o = scaled(base, factor)
        if o > 0.001 {
            shape.fill(color).blur(radius: 30).opacity(min(1.0, o * 0.5))
            shape.fill(color).blur(radius: 16).opacity(min(1.0, o * 0.82))
            shape.fill(color).blur(radius: 7).opacity(o)
        }
    }

    var body: some View {
        let steady = enabled ? IslandGlowPalette.steady(for: status) : nil
        let flashing = flash > 0.01

        ZStack {
            // Sustained green "completed" ring: shown for the whole completion-card
            // lifetime. The one-shot flash below decays in ~1s, but the card stays up
            // for several seconds — without this the idle aggregate status leaves no
            // colored ring and the white panel chrome bleeds through as a white glow.
            if enabled && completing {
                halo(IslandGlowPalette.done, base: 0.5, factor: intensity)
            } else if let steady {
                // Waiting (orange, pulsing) uses `intensity`; running (blue) uses `runningIntensity`,
                // so the always-on working glow can be tuned independently. A narrower hi→lo swing
                // (was 0.34–0.74) keeps the breath gentle rather than strobing.
                let factor = steady.pulse ? intensity : runningIntensity
                let hi = steady.pulse ? 0.70 : 0.46
                let lo = steady.pulse ? 0.44 : 0.46
                let base = steady.pulse ? (pulse ? hi : lo) : hi
                halo(steady.color, base: base, factor: factor)
            }

            // One-shot completion flash (green), independent of steady glow — brighter and
            // longer than before so a finished task is hard to miss.
            if enabled && flashing {
                halo(IslandGlowPalette.done, base: flash, factor: intensity)
            }

            shape.fill(.black)
        }
        .onAppear {
            guard !reduceMotion else { return }
            // Slower, gentler breath — paired with the narrower opacity swing above it reads
            // as a smooth inhale/exhale instead of a coarse pulse.
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: doneNonce) { _, _ in
            guard enabled else { return }
            if reduceMotion {
                flash = 0  // no flash animation under reduce-motion
                return
            }
            flash = 0.95
            withAnimation(.easeOut(duration: 1.1)) { flash = 0 }
        }
    }
}
