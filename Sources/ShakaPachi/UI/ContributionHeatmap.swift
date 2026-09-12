// ContributionHeatmap.swift
// GitHub-style contribution heatmap using fixed pixel sizes.
// Half-year range (26 columns x 7 rows), centered at a compact fixed width.

import SwiftUI

struct ContributionHeatmap: View {

    let dailyCounts: [String: Int]
    let firstUseDate: String?

    // soft green — matches the tray icon soft palette
    // Shared constant defined next to the other appearance colours (Settings.swift).
    private let activityGreen = AccentColor.heatmapActivityGreen

    // Heatmap geometry constants — all pixel values are final.
    private let totalColumns = 26  // ~half a year
    private let daysPerColumn = 7
    private let gap: CGFloat = 3
    private let squareSize: CGFloat = 13  // unified edge for grid cells AND legend swatches

    // Shared opacity ramp for cells and legend swatches — single source of truth.
    private let levelOpacities: [Double] = [0.5, 0.67, 0.83, 1.0]

    // Fixed total grid width derived from constants.
    private var gridWidth: CGFloat {
        CGFloat(totalColumns) * squareSize + CGFloat(totalColumns - 1) * gap
    }

    var body: some View {
        let gridData = buildGrid()
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                monthLabelsRow(gridData: gridData)
                gridBody(gridData: gridData)
                legendRow()
            }
            .frame(width: gridWidth, alignment: .leading)
            Spacer(minLength: 0)  // symmetric spacers center the compact heatmap within the section
        }
    }

    // MARK: - Grid data model

    private struct DayCell {
        let dateString: String?  // nil = padding cell (before first use or future)
        let count: Int
        let level: Int
        let isInRange: Bool  // false = before firstUseDate or in the future
        let isToday: Bool  // true = this cell is the current local day
        let colIndex: Int
        let rowIndex: Int
    }

    private func buildGrid() -> [[DayCell]] {
        let today = Date()
        let todayStr = StreakStats.stringFromDate(today)
        let cal = Calendar.current

        // Find the Sunday (or week-start) of the week containing today → that's the rightmost column.
        let weekday = cal.component(.weekday, from: today)  // 1=Sun ... 7=Sat
        let firstWeekday = cal.firstWeekday  // 1=Sun or 2=Mon
        // Days to go back to reach the start of the current week.
        let daysToWeekStart = (weekday - firstWeekday + 7) % 7
        guard let thisWeekStart = cal.date(byAdding: .day, value: -daysToWeekStart, to: cal.startOfDay(for: today))
        else { return [] }

        // Grid start = 25 weeks before thisWeekStart (26 columns total).
        guard let gridStart = cal.date(byAdding: .weekOfYear, value: -(totalColumns - 1), to: thisWeekStart) else {
            return []
        }

        // Compute thresholds from counts within the grid range.
        let allCounts = (0..<totalColumns * daysPerColumn).compactMap { offset -> Int? in
            guard let d = cal.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            let s = StreakStats.stringFromDate(d)
            return dailyCounts[s]
        }
        let t = StreakStats.thresholds(for: allCounts)

        // Parse firstUseDate.
        let firstDate: Date? = firstUseDate.flatMap { StreakStats.dateFromString($0) }

        // Build column-major grid (26 columns of 7 days each).
        var columns: [[DayCell]] = []
        for col in 0..<totalColumns {
            var column: [DayCell] = []
            for row in 0..<daysPerColumn {
                let offset = col * daysPerColumn + row
                guard let cellDate = cal.date(byAdding: .day, value: offset, to: gridStart) else { continue }
                let cellStr = StreakStats.stringFromDate(cellDate)
                let isFuture = cellStr > todayStr
                let isBeforeFirst = firstDate.map { cellDate < cal.startOfDay(for: $0) } ?? true
                let inRange = !isFuture && !isBeforeFirst
                let count = inRange ? (dailyCounts[cellStr] ?? 0) : 0
                let lv = inRange ? StreakStats.level(for: count, thresholds: t) : 0
                column.append(
                    DayCell(
                        dateString: cellStr,
                        count: count,
                        level: lv,
                        isInRange: inRange,
                        isToday: cellStr == todayStr,
                        colIndex: col,
                        rowIndex: row
                    ))
            }
            columns.append(column)
        }
        return columns
    }

    // MARK: - Sub-views

    private func monthLabelsRow(gridData: [[DayCell]]) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<gridData.count, id: \.self) { col in
                let cell = gridData[col].first
                let showLabel = shouldShowMonthLabel(col: col, gridData: gridData)
                ZStack(alignment: .leading) {
                    Color.clear.frame(width: squareSize, height: 12)
                    if showLabel, let cell = cell, let dateStr = cell.dateString,
                        let date = StreakStats.dateFromString(dateStr)
                    {
                        let month = Calendar.current.component(.month, from: date)
                        Text(Calendar.current.shortMonthSymbols[month - 1])
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize()
                    }
                }
                // Pin each column to the square width. Without this, a labelled
                // column's ZStack grows to the fixedSize text, widening the row
                // past the grid. The label text overflows visually into the
                // trailing Spacer area — that's fine (not clipped).
                .frame(width: squareSize, alignment: .leading)
            }
        }
    }

    private func shouldShowMonthLabel(col: Int, gridData: [[DayCell]]) -> Bool {
        guard col < gridData.count, let cell = gridData[col].first,
            let dateStr = cell.dateString,
            let date = StreakStats.dateFromString(dateStr)
        else { return false }
        let cal = Calendar.current
        let month = cal.component(.month, from: date)
        // Skip column 0's label: it's a partial first week, so its month label
        // would crowd against the next month's label at the left edge.
        if col == 0 { return false }
        guard let prevCell = gridData[col - 1].first,
            let prevStr = prevCell.dateString,
            let prevDate = StreakStats.dateFromString(prevStr)
        else { return false }
        let prevMonth = cal.component(.month, from: prevDate)
        return month != prevMonth
    }

    private func gridBody(gridData: [[DayCell]]) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<gridData.count, id: \.self) { col in
                VStack(spacing: gap) {
                    ForEach(0..<gridData[col].count, id: \.self) { row in
                        cellView(cell: gridData[col][row])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(cell: DayCell) -> some View {
        let square = RoundedRectangle(cornerRadius: 2)
            .fill(cellColor(cell: cell))
            .frame(width: squareSize, height: squareSize)
            .overlay(todayRing(for: cell))
        // A native hover tooltip reveals the exact date and recorded count.
        // Padding cells (out of range) return nil, so they get no tooltip.
        if let tip = tooltip(for: cell) {
            square.help(tip)
        } else {
            square
        }
    }

    // Cached formatter for hover tooltips (medium date — matches the legend's
    // start-date style for visual consistency).
    private static let tooltipDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        fmt.locale = Locale.current
        return fmt
    }()

    // Hover tooltip text: the day's date plus how many switches were recorded
    // that day. Returns nil for out-of-range padding cells so no tooltip shows.
    private func tooltip(for cell: DayCell) -> String? {
        guard cell.isInRange, let s = cell.dateString,
            let date = StreakStats.dateFromString(s)
        else { return nil }
        let dateText = Self.tooltipDateFormatter.string(from: date)
        if cell.count > 0 {
            return String(
                format: NSLocalizedString(
                    "%1$@ · %2$@ 回", comment: "Heatmap cell tooltip: date and switch count"),
                dateText, String(cell.count))
        }
        return String(
            format: NSLocalizedString(
                "%@ · 記録なし", comment: "Heatmap cell tooltip: date with no records"),
            dateText)
    }

    // A thin high-contrast ring marks the current local day so it's always
    // identifiable even when today has no activity (level 0).
    @ViewBuilder
    private func todayRing(for cell: DayCell) -> some View {
        if cell.isToday {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
        }
    }

    private func cellColor(cell: DayCell) -> Color {
        guard cell.isInRange else {
            return Color.secondary.opacity(0.10)
        }
        switch cell.level {
        case 0: return Color.secondary.opacity(0.10)
        case 1: return activityGreen.opacity(levelOpacities[0])
        case 2: return activityGreen.opacity(levelOpacities[1])
        case 3: return activityGreen.opacity(levelOpacities[2])
        default: return activityGreen.opacity(levelOpacities[3])
        }
    }

    private func legendRow() -> some View {
        HStack(spacing: 4) {
            Text("少ない")
                .font(.caption2)
                .foregroundColor(.secondary)
            ForEach(0..<levelOpacities.count, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 2)
                    .fill(activityGreen.opacity(levelOpacities[idx]))
                    .frame(width: squareSize, height: squareSize)
            }
            Text("多い")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            // Start date on the trailing edge, aligned under the grid's right edge.
            Text(formattedStartDate())
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // Cached formatter for the legend start-date label (dateStyle: .medium, not yyyy-MM-dd).
    private static let startDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        fmt.locale = Locale.current
        return fmt
    }()

    // Format firstUseDate for the legend row; returns "—" when absent.
    private func formattedStartDate() -> String {
        guard let s = firstUseDate, let d = StreakStats.dateFromString(s) else { return "—" }
        return String(
            format: NSLocalizedString("開始 %@", comment: "Heatmap start date"),
            Self.startDateFormatter.string(from: d))
    }
}
