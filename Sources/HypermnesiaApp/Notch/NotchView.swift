import SwiftUI
import HypermnesiaKit

/// The notch-extension outline (the Dynamic Island look): the top edge runs the full width so it
/// melts into the notch/screen edge, the walls tuck inward through small flare curves, and the
/// bottom corners bulge back out. Both radii animate, so the shape can morph.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat = 8
    var bottomCornerRadius: CGFloat = 20

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The black card stack hanging from the notch. On notch screens it wears `NotchShape` so it reads
/// as the notch itself expanding; on notchless displays it's a floating capsule below the menu bar.
/// `visible` drives the pop/retract spring (the panel flips it around ordering the window).
///
/// Working sessions are presence, not pops: alone they render as a slim "N working" strip hugging
/// the notch; alongside cards they're a footer line. Hovering the housing flips `workingExpanded`
/// (via the panel, which also resizes the window) to reveal one row per running session.
struct NotchStatusView: View {
    let cards: [SessionEventFeed.Card]
    var workingCards: [SessionEventFeed.Card] = []
    let geometry: NotchGeometry?
    var visible: Bool = true
    var workingExpanded: Bool = false
    let onActivate: (SessionEventFeed.Card) -> Void
    let onDismiss: (SessionEventFeed.Card) -> Void
    var onHoverChange: (Bool) -> Void = { _ in }

    /// One spring family everywhere, so pops, morphs, and row shuffles feel like one object.
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.77)
    static let popSpring = Animation.spring(response: 0.4, dampingFraction: 0.77)
    static let topCornerRadius: CGFloat = 8
    static let bottomCornerRadius: CGFloat = 20

    private var hasNotch: Bool { geometry?.hasNotch ?? true }

    /// Just the slim working strip — no cards, not expanded.
    private var isStrip: Bool { cards.isEmpty && !workingExpanded }

    private var width: CGFloat {
        if isStrip { return hasNotch ? max((geometry?.notchWidth ?? 0) + 64, 250) : 190 }
        return max(min((geometry?.notchWidth ?? 0) + 170, 480), 400)
    }

    private var bottomRadius: CGFloat { isStrip ? 14 : Self.bottomCornerRadius }

    var body: some View {
        VStack(spacing: 5) {
            ForEach(cards) { card in
                NotchCardRow(card: card, onActivate: onActivate, onDismiss: onDismiss)
            }
            if !workingCards.isEmpty {
                if !cards.isEmpty {
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 6)
                }
                if workingExpanded {
                    ForEach(workingCards) { card in
                        NotchWorkingRow(card: card, onActivate: onActivate)
                    }
                } else {
                    NotchWorkingSummary(count: workingCards.count)
                }
            }
        }
        .padding(.top, hasNotch ? (geometry?.topInset ?? 0) + 2 : 9)
        // The walls tuck in by the top flare radius, so content clears them, not just the frame.
        .padding(.horizontal, 10 + (hasNotch ? Self.topCornerRadius : 0))
        .padding(.bottom, isStrip ? 7 : 10)
        .frame(width: width)
        .background(housing)
        .environment(\.colorScheme, .dark)   // the housing is pure black regardless of theme
        .scaleEffect(x: visible ? 1 : 0.6, y: visible ? 1 : 0.12, anchor: .top)
        .opacity(visible ? 1 : 0)
        .onHover(perform: onHoverChange)
        .animation(Self.popSpring, value: visible)
        .animation(Self.spring, value: cards)
        .animation(Self.spring, value: workingCards)
        .animation(Self.spring, value: workingExpanded)
        // NSHostingView CENTERS a fixed-size root view when the window is bigger than the content
        // — and the panel's deferred shrink leaves the window oversized for a beat on every morph,
        // which would detach the housing from the notch. Pin it to the top edge instead. (This
        // frame's ideal size is still the content's, so `fittingSize` sizing is unaffected.)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Pure black, so it blends seamlessly with the physical notch bezel; the hairline stroke is
    /// what separates it from dark wallpapers.
    @ViewBuilder
    private var housing: some View {
        if hasNotch {
            NotchShape(topCornerRadius: Self.topCornerRadius, bottomCornerRadius: bottomRadius)
                .fill(Color.black)
                .overlay(
                    NotchShape(topCornerRadius: Self.topCornerRadius, bottomCornerRadius: bottomRadius)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                        // The top run sits against the screen edge — mask it off so only the
                        // hanging outline catches a hairline.
                        .mask(Rectangle().padding(.top, 1.5)))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
        } else {
            RoundedRectangle(cornerRadius: isStrip ? 16 : 22, style: .continuous)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: isStrip ? 16 : 22, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
        }
    }
}

private struct NotchCardRow: View {
    let card: SessionEventFeed.Card
    let onActivate: (SessionEventFeed.Card) -> Void
    let onDismiss: (SessionEventFeed.Card) -> Void
    @State private var hovering = false

    private var event: SessionEvent { card.event }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.18), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(projectDisplayName(event.projectId))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let title = event.title {
                        Text("· \(title)")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if event.isDemo { SampleBadge() }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if hovering {
                Button {
                    onDismiss(card)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            } else {
                // Compact static age ("45s", "2m") — re-rendered by the controller's 2s tick, and
                // far narrower than SwiftUI's live relative style ("1 min, 15 sec").
                Text(Self.compactAge(since: event.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(hovering ? 0.14 : 0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onTapGesture { onActivate(card) }
        .onHover { hovering = $0 }
        .help("Click to jump back to this session")
        .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
    }

    private var symbol: String {
        switch event.kind {
        case .attention: event.needsPermission ? "hand.raised.fill" : "ellipsis.bubble.fill"
        case .finished: "checkmark.circle.fill"
        case .ended, .working: "circle"   // never rendered as pop cards
        }
    }

    private var accent: Color {
        event.kind == .attention ? .caution : .positive
    }

    private var subtitle: String {
        switch event.kind {
        case .attention:
            return event.message ?? "Waiting for your input"
        case .finished, .ended, .working:
            return "\(clientDisplayName(event.client)) finished — click to jump back"
        }
    }

    static func compactAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3_600: return "\(seconds / 60)m"
        default: return "\(seconds / 3_600)h"
        }
    }
}

/// Demo cards must be distinguishable from real sessions at a glance — `notch-demo` and the
/// Settings Preview button tag their events, and this chip is the visible mark.
private struct SampleBadge: View {
    var body: some View {
        Text("sample")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.white.opacity(0.08)))
    }
}

private func clientDisplayName(_ raw: String) -> String {
    switch HookClient(rawValue: raw) {
    case .claude: "Claude Code"
    case .cursor: "Cursor"
    case .antigravity: "Antigravity"
    case nil: raw
    }
}

/// A slow-pulsing "alive" dot — the working state's whole visual vocabulary.
private struct NotchBreathingDot: View {
    var size: CGFloat = 6
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(Color.positive)
            .frame(width: size, height: size)
            .opacity(breathing ? 1 : 0.3)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathing)
            .onAppear { breathing = true }
    }
}

/// The collapsed presence line: a breathing dot and "N working". Hovering the housing expands it
/// into `NotchWorkingRow`s.
private struct NotchWorkingSummary: View {
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            NotchBreathingDot()
            Text(count == 1 ? "1 working" : "\(count) working")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .transition(.opacity)
    }
}

/// One running session in the expanded strip: spinner, project · what it's chewing on, and how
/// long the turn has been going. Click jumps to the session; there's nothing to dismiss — the row
/// leaves when the turn does.
private struct NotchWorkingRow: View {
    let card: SessionEventFeed.Card
    let onActivate: (SessionEventFeed.Card) -> Void
    @State private var hovering = false

    private var event: SessionEvent { card.event }

    var body: some View {
        HStack(spacing: 10) {
            // Same icon language as the pop cards, with a breathing dot instead of a glyph —
            // pure SwiftUI (an NSProgressIndicator-backed spinner can't render headlessly).
            NotchBreathingDot(size: 8)
                .frame(width: 30, height: 30)
                .background(Color.positive.opacity(0.18), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(projectDisplayName(event.projectId))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let title = event.title {
                        Text("· \(title)")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if event.isDemo { SampleBadge() }
                }
                Text("\(clientDisplayName(event.client)) working — click to jump there")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Elapsed turn time, anchored to the turn's start so heartbeats don't reset it.
            Text(NotchCardRow.compactAge(since: event.startedAt ?? event.timestamp))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(hovering ? 0.13 : 0.05)))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onActivate(card) }
        .onHover { hovering = $0 }
        .help("Click to jump to this session")
        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
    }
}
