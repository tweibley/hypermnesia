import SwiftUI
import Charts
import HypermnesiaKit

/// Project Health Trends: time-based view of whether the memory corpus is improving or rotting.
///
/// Note the cohort semantics (see `MemoryAnalytics.projectTrends`): the per-day series bucket
/// memories by *creation day* using their *current* decayed confidence — we don't snapshot history.
struct TrendsView: View {
    @Environment(AppModel.self) private var model

    private let injectionThreshold = MemoryHydrator.Options().minConfidence

    var body: some View {
        @Bindable var model = model
        let vm = model.projectTrends

        VStack(spacing: 0) {
            header($model.trendsWindow)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    kpiRow(vm.kpis)
                    capturedChart(vm)
                    confidenceChart(vm)
                    decayChart(vm)
                    Text("Per-day series group memories by creation day and use each memory's current confidence (history isn't snapshotted). KPIs are a live project-wide snapshot.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
        }
    }

    // MARK: Header

    private func header(_ window: Binding<TrendWindow>) -> some View {
        HStack {
            Label("Trends", systemImage: "chart.xyaxis.line").font(.headline)
            Spacer()
            Picker("Window", selection: window) {
                ForEach(TrendWindow.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(10)
    }

    // MARK: KPIs

    private func kpiRow(_ kpis: ProjectTrendKPI) -> some View {
        HStack(spacing: 12) {
            kpiTile("Confirmed", kpis.confirmedRate,
                    icon: "checkmark.seal.fill", tint: .positive, higherIsBetter: true)
            kpiTile("Below inject. threshold", kpis.belowInjectionThresholdRate,
                    icon: "arrow.down.right.circle.fill", tint: .caution, higherIsBetter: false)
            kpiTile("Override ratio", kpis.aggregateOverrideRate,
                    icon: "arrow.uturn.backward.circle.fill", tint: .caution, higherIsBetter: false)
        }
    }

    private func kpiTile(_ title: String, _ value: Double, icon: String, tint: Color, higherIsBetter: Bool) -> some View {
        // A value is "good" when high-good metrics are high (or low-good metrics are low); only then
        // does it take the accent color — otherwise it stays neutral so the bad cases read as alerts.
        let good = higherIsBetter ? value >= 0.5 : value <= 0.25
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundStyle(tint)
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(good ? tint : Color.primary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    // MARK: Charts

    private func capturedChart(_ vm: ProjectTrendsVM) -> some View {
        chartCard("Captured per day", subtitle: "new vs. confirmed") {
            Chart {
                ForEach(vm.newMemories) { p in
                    LineMark(x: .value("Day", p.bucketStart, unit: .day),
                             y: .value("Count", p.value),
                             series: .value("Series", "New"))
                        .foregroundStyle(by: .value("Series", "New"))
                        .symbol(.circle)
                }
                ForEach(vm.confirmedMemories) { p in
                    LineMark(x: .value("Day", p.bucketStart, unit: .day),
                             y: .value("Count", p.value),
                             series: .value("Series", "Confirmed"))
                        .foregroundStyle(by: .value("Series", "Confirmed"))
                        .symbol(.circle)
                }
            }
            .chartForegroundStyleScale(["New": Color.brand, "Confirmed": Color.positive])
            .chartLegend(position: .top, alignment: .leading)
            .modifier(DayAxis(window: vm.window))
        }
    }

    private func confidenceChart(_ vm: ProjectTrendsVM) -> some View {
        chartCard("Avg injectable confidence", subtitle: "of memories created that day") {
            Chart {
                ForEach(vm.avgInjectableConfidence) { p in
                    AreaMark(x: .value("Day", p.bucketStart, unit: .day),
                             y: .value("Confidence", p.value))
                        .foregroundStyle(Color.brand.opacity(0.15))
                    LineMark(x: .value("Day", p.bucketStart, unit: .day),
                             y: .value("Confidence", p.value))
                        .foregroundStyle(Color.brand)
                        .symbol(.circle)
                }
                RuleMark(y: .value("Threshold", injectionThreshold))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("inject ≥ \(Int(injectionThreshold * 100))%")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartYScale(domain: 0...1)
            .modifier(DayAxis(window: vm.window))
        }
    }

    private func decayChart(_ vm: ProjectTrendsVM) -> some View {
        chartCard("Memory health over time", subtitle: "decay level of each day's cohort") {
            Chart(decaySlices(vm)) { slice in
                BarMark(x: .value("Day", slice.day, unit: .day),
                        y: .value("Count", slice.count))
                    .foregroundStyle(by: .value("Level", slice.level))
            }
            .chartForegroundStyleScale([
                DecayLevel.fresh.displayName: DecayLevel.fresh.color,
                DecayLevel.aging.displayName: DecayLevel.aging.color,
                DecayLevel.stale.displayName: DecayLevel.stale.color,
                DecayLevel.dormant.displayName: DecayLevel.dormant.color,
            ])
            .chartLegend(position: .top, alignment: .leading)
            .modifier(DayAxis(window: vm.window))
        }
    }

    /// Flatten the stacked points into long-form rows, keeping a stable fresh→dormant order.
    private func decaySlices(_ vm: ProjectTrendsVM) -> [DecaySlice] {
        vm.decayStack.flatMap { p in
            [
                DecaySlice(day: p.bucketStart, level: DecayLevel.fresh.displayName, count: p.fresh),
                DecaySlice(day: p.bucketStart, level: DecayLevel.aging.displayName, count: p.aging),
                DecaySlice(day: p.bucketStart, level: DecayLevel.stale.displayName, count: p.stale),
                DecaySlice(day: p.bucketStart, level: DecayLevel.dormant.displayName, count: p.dormant),
            ]
        }
    }

    @ViewBuilder
    private func chartCard(_ title: String, subtitle: String, @ViewBuilder _ chart: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
            chart().frame(height: 160)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

private struct DecaySlice: Identifiable {
    let id = UUID()
    let day: Date
    let level: String
    let count: Int
}

/// Compact day x-axis: every day for 7d, weekly for 30d.
private struct DayAxis: ViewModifier {
    let window: TrendWindow
    func body(content: Content) -> some View {
        content.chartXAxis {
            AxisMarks(values: .stride(by: .day, count: window == .days30 ? 7 : 1)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
            }
        }
    }
}
