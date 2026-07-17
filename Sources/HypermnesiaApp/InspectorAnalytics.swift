import SwiftUI
import HypermnesiaKit

// MARK: - Confidence breakdown card

/// Makes a memory's confidence legible: the headline score, the `belief × freshness` factoring that
/// produced it, and a "why" drill-down — so a low score reads as "old" vs "untrusted", not a black box.
struct ConfidenceCardView: View {
    let vm: ConfidenceBreakdownVM
    @State private var showWhy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            formula
            VStack(alignment: .leading, spacing: 9) {
                FactorBar(label: "Belief — trustworthiness", value: vm.belief, tint: .belief)
                FactorBar(label: vm.decays ? "Freshness — recency" : "Freshness — this type doesn't age",
                          value: vm.freshness, tint: .freshness)
            }
            DisclosureGroup(isExpanded: $showWhy) { why } label: {
                Text("Why this value?").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .disclosureGroupStyle(.automatic)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(pct(vm.confidence))%")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(vm.decayLevel.color)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: vm.decayLevel.sfSymbol)
                    Text(vm.decayLevel.displayName)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(vm.decayLevel.color)
                Text(vm.usesBeliefModel ? "Evidence-based" : "Age-only (legacy)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    /// belief × freshness = confidence, as three tinted chips.
    private var formula: some View {
        HStack(spacing: 6) {
            chip("\(pct(vm.belief))%", .belief)
            Text("×").font(.caption).foregroundStyle(.tertiary)
            chip("\(pct(vm.freshness))%", .freshness)
            Text("=").font(.caption).foregroundStyle(.tertiary)
            chip("\(pct(vm.confidence))%", vm.decayLevel.color)
            Spacer()
        }
    }

    private var why: some View {
        VStack(alignment: .leading, spacing: 6) {
            statRow("Times applied", "\(vm.timesApplied)" + (vm.timesAppliedSuccess > 0 ? " (\(vm.timesAppliedSuccess) survived)" : ""))
            statRow("Times sighted", "\(vm.timesSighted)")
            statRow("Times overridden", "\(vm.timesOverridden)  (\(pct(vm.overrideRate))%)")
            if let outcome = vm.lastAuditOutcome {
                statRow("Last reality check", outcome == "drift" ? "drift detected" : outcome)
            }
            statRow("Last validated", vm.lastValidatedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "never")
            statRow("Age", vm.decays ? "\(vm.ageDays)d since validation" : "n/a (doesn't age)")
            statRow("Decay bucket", vm.decayLevel.displayName)
        }
        .padding(.top, 4)
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func pct(_ x: Double) -> Int { Int((x * 100).rounded()) }
}

/// A labeled 0–1 horizontal bar.
private struct FactorBar: View {
    let label: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Timeline

/// The "story of this memory": created → validated → updated, reinforcement/override markers, and the
/// decay transitions it has crossed — derived entirely from stored timestamps + counters.
struct MemoryTimelineView: View {
    let vm: MemoryTimelineVM

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TIMELINE").font(.caption2).bold().foregroundStyle(.tertiary)
                Spacer()
                TrendMarker(trend: vm.trend)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(vm.events.enumerated()), id: \.element.id) { index, event in
                    eventRow(event, isLast: index == vm.events.count - 1)
                }
            }
        }
    }

    private func eventRow(_ event: MemoryTimelineEventVM, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Image(systemName: event.kind.sfSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(event.kind.tint)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(event.kind.tint.opacity(0.15)))
                if !isLast {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1.5).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(event.title).font(.caption.weight(.semibold))
                    Spacer()
                    Text(event.timestamp.formatted(.relative(presentation: .named)))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(event.detail).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.bottom, isLast ? 0 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Up / down / stable confidence-direction pill.
private struct TrendMarker: View {
    let trend: ConfidenceTrend
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: trend.sfSymbol)
            Text(trend.label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(trend.tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(trend.tint.opacity(0.14)))
    }
}

// MARK: - App-layer presentation for the derived enums

extension MemoryEventKind {
    var sfSymbol: String {
        switch self {
        case .created: "sparkles"
        case .updated: "pencil"
        case .validated: "checkmark.seal.fill"
        case .reinforced: "bolt.fill"
        case .overridden: "arrow.uturn.backward"
        case .decayTransition: "clock.arrow.circlepath"
        }
    }
    var tint: Color {
        switch self {
        case .created: .secondary
        case .updated: .secondary
        case .validated: .positive
        case .reinforced: .belief          // trust gained → the belief/brand purple
        case .overridden: .critical
        case .decayTransition: DecayLevel.aging.color   // amber, matching the decay band
        }
    }
}

extension ConfidenceTrend {
    var sfSymbol: String {
        switch self {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .stable: "arrow.right"
        }
    }
    var label: String {
        switch self {
        case .up: "Rising"
        case .down: "Decaying"
        case .stable: "Stable"
        }
    }
    var tint: Color {
        switch self {
        case .up: .positive
        case .down: .caution
        case .stable: .secondary
        }
    }
}
