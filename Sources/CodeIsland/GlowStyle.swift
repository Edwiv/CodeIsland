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

/// Renders the island's solid shape with a status-driven glow, using AgentIsland's
/// `island-frame` technique: the glow is a `.shadow` (drop-shadow) of the black silhouette —
/// a Gaussian blur of the shape's alpha mask — so it hugs the rounded corners and bleeds out
/// smoothly, plus a crisp white lit edge and a soft downward depth shadow for a "floating" feel.
/// - working (running/processing): steady soft blue
/// - awaiting approval/question: pulsing orange (breathing)
/// - just completed: one-shot green flash (keyed off `doneNonce`)
///
/// `intensity` (1.0 = 100%) scales the waiting/done glow; `runningIntensity` scales the steady
/// running (blue) glow independently. Final opacities are clamped to [0, 1].
struct IslandGlowBackground<S: Shape>: View {
    let shape: S
    let status: AgentStatus
    let doneNonce: Int
    let enabled: Bool
    /// True while the completion ("done") card is being presented. Drives a sustained
    /// green ring for the full card lifetime, rather than only the ~1s one-shot flash.
    var completing: Bool = false
    /// True while the panel is expanded. Drives the lit edge + floating depth even when idle
    /// (AgentIsland's "is-open" look); kept off while collapsed so the notch stays pure black.
    var expanded: Bool = false
    /// When false, the glow is fully suppressed while collapsed — it appears only once the panel
    /// is expanded. (Setting: "Glow When Collapsed".)
    var glowWhenCollapsed: Bool = true
    var intensity: Double = 1.3
    var runningIntensity: Double = 1.0

    @State private var pulse = false
    @State private var flash: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func scaled(_ v: Double, _ factor: Double) -> Double { min(1.0, max(0.0, v * factor)) }

    /// Dominant colored glow for the current state (color, core opacity). Rendered below as a
    /// two-stop `.shadow` of the solid island — a true drop-shadow of the silhouette (Gaussian
    /// blur of the shape's alpha mask), the AgentIsland `island-frame` technique. It hugs the
    /// rounded corners and falls off smoothly; the old approach blurred a *filled copy* of the
    /// shape, exposing the rectangular silhouette ("粗糙"). Opacity 0 ⇒ no colored glow.
    private func resolvedGlow() -> (color: Color, opacity: Double) {
        guard enabled else { return (.clear, 0) }
        // Collapsed + opted out: no glow until the panel is expanded.
        if !expanded && !glowWhenCollapsed { return (.clear, 0) }
        if completing {
            return (IslandGlowPalette.done, scaled(0.62, intensity))
        }
        if flash > 0.01 {
            return (IslandGlowPalette.done, scaled(flash, intensity))
        }
        if let steady = IslandGlowPalette.steady(for: status) {
            if steady.pulse {
                // Waiting (orange) — breathe the opacity (reads as a gentle pulse).
                return (steady.color, scaled(pulse ? 0.72 : 0.46, intensity))
            }
            // Running / processing (blue) — steady.
            return (steady.color, scaled(0.55, runningIntensity))
        }
        return (.clear, 0)
    }

    var body: some View {
        let glow = resolvedGlow()
        let glowActive = glow.opacity > 0.001
        // Lit edge + floating depth show whenever the island is expanded, or a colored glow is
        // active. Off for the collapsed/idle notch so it stays pure black and blends in.
        let chrome = enabled && (expanded || glowActive)

        shape
            .fill(.black)
            // Subtle antialiased lit edge — an inner stroke, NOT a hard ~1px white shadow (which
            // aliased on the curved top/shoulders and read as a rough edge).
            .overlay(shape.stroke(Color.white.opacity(chrome ? 0.13 : 0), lineWidth: 0.75))
            // Two-stop colored glow: a wide faint wash + a tighter brighter core. Drop-shadows of
            // the silhouette → smooth, even, no exposed corners. Invisible (opacity 0) when idle.
            .shadow(color: glow.color.opacity(glow.opacity * 0.72), radius: 26)
            .shadow(color: glow.color.opacity(glow.opacity), radius: 10)
            // Soft downward depth for the "floating" feel.
            .shadow(color: .black.opacity(chrome ? 0.35 : 0), radius: 20, x: 0, y: 11)
            .onAppear {
                guard !reduceMotion else { return }
                // Gentle inhale/exhale for the waiting state; only opacity oscillates.
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
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
