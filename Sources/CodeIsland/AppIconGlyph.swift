import SwiftUI

/// Recognizable per-agent icon: the real bundled app icon (PNG) when one exists, falling
/// back to the unified `AppIconGlyph` chip for custom / unknown CLIs that ship no icon.
/// Used where directness beats stylistic uniformity — e.g. the dashboard sidebar + detail
/// header, where the actual app icon is more eye-catching and immediately legible.
struct AgentAppIcon: View {
    let source: String
    var size: CGFloat = 22

    var body: some View {
        if let icon = cliIcon(source: source, size: size) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            AppIconGlyph(source: source, size: size)
        }
    }
}

/// A minimal, style-unified per-app icon shown when the user turns the animated
/// pixel mascot off (R1). Port of AgentIsland's `AgentGlyph`: a rounded brand-tinted
/// chip containing a monochrome, rounded-stroke line glyph — the brand color is the
/// only per-agent variable, which is what makes the set feel unified.
///
/// Headliner agents (Claude / Codex / Cursor / Gemini) get a recognizable line glyph;
/// every other source gets a clean brand-colored monogram in the same chip, so the
/// long tail stays consistent and never falls back to something jarring.
struct AppIconGlyph: View {
    let source: String
    var size: CGFloat = 27

    private var canonical: String { AgentCatalog.canonicalSource(source) }
    private var color: Color { AgentCatalog.brandColor(source: source) }

    var body: some View {
        let chip = size
        let corner = chip * 0.3
        let stroke = max(1.1, chip * 0.075)
        let glyphSize = chip * 0.58

        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(color.opacity(0.14))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: 1)

            glyphView(stroke: stroke)
                .frame(width: glyphSize, height: glyphSize)
        }
        .frame(width: chip, height: chip)
    }

    @ViewBuilder
    private func glyphView(stroke: CGFloat) -> some View {
        switch canonical {
        case "claude":
            Canvas { ctx, sz in drawClaude(ctx, sz, stroke) }
        case "codex":
            Canvas { ctx, sz in drawCodex(ctx, sz, stroke) }
        case "cursor", "cursor-cli":
            Canvas { ctx, sz in drawCursor(ctx, sz, stroke) }
        case "gemini", "google-antigravity":
            Canvas { ctx, sz in drawGemini(ctx, sz, stroke) }
        default:
            Text(monogram)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    // MARK: - Glyph drawings (stroked in the brand color, rounded caps)

    private func strokeStyle(_ w: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
    }

    /// Claude: a radiating sunburst (asterisk of rays from center).
    private func drawClaude(_ ctx: GraphicsContext, _ sz: CGSize, _ w: CGFloat) {
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let r = min(sz.width, sz.height) * 0.46
        var path = Path()
        let rays = 6
        for i in 0..<rays {
            let a = Double(i) / Double(rays) * 2 * .pi
            let dx = CGFloat(cos(a)) * r
            let dy = CGFloat(sin(a)) * r
            path.move(to: CGPoint(x: c.x - dx * 0.28, y: c.y - dy * 0.28))
            path.addLine(to: CGPoint(x: c.x + dx, y: c.y + dy))
        }
        ctx.stroke(path, with: .color(color), style: strokeStyle(w))
    }

    /// Codex: an orbital ring with a small core dot.
    private func drawCodex(_ ctx: GraphicsContext, _ sz: CGSize, _ w: CGFloat) {
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let r = min(sz.width, sz.height) * 0.44
        let orbitRect = CGRect(x: c.x - r, y: c.y - r * 0.5, width: r * 2, height: r)
        var orbit = Path(ellipseIn: orbitRect)
        // Rotate the ellipse ~ -30° around center for an orbital look.
        let rot = CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: -.pi / 6)
            .translatedBy(x: -c.x, y: -c.y)
        orbit = orbit.applying(rot)
        ctx.stroke(orbit, with: .color(color), style: strokeStyle(w))
        let dotR = r * 0.28
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2)), with: .color(color))
    }

    /// Cursor: a pointer / cursor triangle.
    private func drawCursor(_ ctx: GraphicsContext, _ sz: CGSize, _ w: CGFloat) {
        let pad = sz.width * 0.18
        var path = Path()
        path.move(to: CGPoint(x: pad, y: pad))
        path.addLine(to: CGPoint(x: sz.width - pad, y: sz.height * 0.5))
        path.addLine(to: CGPoint(x: sz.width * 0.5, y: sz.height * 0.56))
        path.addLine(to: CGPoint(x: sz.width * 0.42, y: sz.height - pad))
        path.closeSubpath()
        ctx.stroke(path, with: .color(color), style: strokeStyle(w))
    }

    /// Gemini: a four-point sparkle / spark.
    private func drawGemini(_ ctx: GraphicsContext, _ sz: CGSize, _ w: CGFloat) {
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let outer = min(sz.width, sz.height) * 0.48
        let inner = outer * 0.34
        var path = Path()
        let pts = 4
        for i in 0..<(pts * 2) {
            let a = Double(i) / Double(pts * 2) * 2 * .pi - .pi / 2
            let rad = (i % 2 == 0) ? outer : inner
            let p = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.stroke(path, with: .color(color), style: strokeStyle(w))
    }

    // MARK: - Monogram fallback

    private var monogram: String {
        let map: [String: String] = [
            "trae": "Tr", "traecn": "Tr", "traecli": "Tr",
            "copilot": "Co", "qoder": "Qo", "qoder-cli": "Qo",
            "droid": "Fa", "codebuddy": "CB", "codybuddycn": "CB",
            "stepfun": "SF", "antigravity": "AG",
            "workbuddy": "WB", "hermes": "He", "qwen": "Qw",
            "kimi": "Ki", "pi": "Pi", "opencode": "OC", "cline": "Cl",
            "kiro": "Ki",
        ]
        if let m = map[canonical] { return m }
        return String(canonical.prefix(2)).capitalized
    }
}
