import SwiftUI
import Charts
import ExpensesKit

/// Renders exactly the rows the database returned. Values are USD.
struct SpendChart: View {
    let rows: [AggregateRow]
    let kind: ChartKind
    var height: CGFloat = 260

    var body: some View {
        if rows.isEmpty || rows.allSatisfy({ $0.usdMinor == 0 }) {
            ContentUnavailableView("No spending in this range", systemImage: "chart.bar")
                .frame(height: height)
        } else {
            chart.frame(height: height)
        }
    }

    @ViewBuilder var chart: some View {
        switch kind {
        case .pie:
            Chart(rows.filter { $0.usdMinor > 0 }) { r in
                SectorMark(angle: .value("USD", Double(r.usdMinor) / 100), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(by: .value("Group", r.label))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale(domain: rows.filter { $0.usdMinor > 0 }.map(\.label), range: Self.palette)
            .chartLegend(position: .trailing, alignment: .center)
        case .line:
            Chart(rows) { r in
                LineMark(x: .value("Period", r.label), y: .value("USD", Double(r.usdMinor) / 100))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Period", r.label), y: .value("USD", Double(r.usdMinor) / 100))
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis { axis }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(d, format: .currency(code: "USD").precision(.fractionLength(0))) } } } }
        case .bar:
            Chart(rows) { r in
                BarMark(x: .value("Period", r.label), y: .value("USD", Double(r.usdMinor) / 100))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
            }
            .chartXAxis { axis }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(d, format: .currency(code: "USD").precision(.fractionLength(0))) } } } }
        }
    }

    /// 12 distinct hues so categories never share a color.
    static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .yellow, .pink, .indigo, .mint, .brown, .gray]

    /// "Jan 2026" -> "Jan ’26" so 12 monthly labels fit.
    static func short(_ label: String) -> String {
        let parts = label.split(separator: " ")
        if parts.count == 2, parts[1].count == 4, parts[0].count == 3 { return "\(parts[0]) ’\(parts[1].suffix(2))" }
        return label
    }

    /// Show at most ~8 x labels so 365 daily bars stay readable.
    var axis: some AxisContent {
        let stride = max(1, Int((Double(rows.count) / 8).rounded(.up)))
        let shown = Set(rows.enumerated().filter { $0.offset % stride == 0 }.map(\.element.label))
        return AxisMarks { v in
            if let s = v.as(String.self), shown.contains(s) {
                AxisValueLabel { Text(Self.short(s)).font(.caption2) }
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
