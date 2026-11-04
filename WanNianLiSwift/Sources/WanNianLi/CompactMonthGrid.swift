import AppKit
import LunarCore
import SwiftUI

/// 紧凑月历，提供月份跳转、周数和日期选择。
struct CompactMonthGrid: View {
    @ObservedObject var model: CalendarViewModel
    @ObservedObject var calendarStore: SystemCalendarStore
    let scale: CGFloat
    var previewEventCounts: [SolarDate: Int]?

    private var weekNumberWidth: CGFloat { scaled(20) }
    private var cellWidth: CGFloat { scaled(40) }
    private var rowHeight: CGFloat { scaled(39) }
    private let weekdays = Array("一二三四五六日").map(String.init)

    private func scaled(_ value: CGFloat) -> CGFloat { value * scale }

    var body: some View {
        VStack(spacing: scaled(2)) {
            header
            weekdayHeader
            calendarRows
        }
        .frame(width: weekNumberWidth + cellWidth * 7)
    }

    private var header: some View {
        HStack(spacing: scaled(5)) {
            Menu {
                Picker("年份", selection: Binding(get: { model.year }, set: { model.setYear($0) })) {
                    ForEach(CalendarViewModel.years, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                Picker("月份", selection: Binding(get: { model.month }, set: { model.setMonth($0) })) {
                    ForEach(1...12, id: \.self) { month in
                        Text("\(month)月").tag(month)
                    }
                }
            } label: {
                Text("\(String(model.year))年 \(model.month)月")
                .font(.system(size: scaled(16), weight: .semibold))
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("选择年份和月份")

            Spacer(minLength: 0)
            headerButton("chevron.left", help: "上个月", enabled: model.canMoveBackward) {
                model.moveMonth(by: -1)
            }
            headerButton("circle.fill", help: "回到今天", enabled: true) {
                model.showToday()
            }
            headerButton("chevron.right", help: "下个月", enabled: model.canMoveForward) {
                model.moveMonth(by: 1)
            }
        }
        .frame(height: scaled(29))
    }

    private func headerButton(_ symbol: String, help: String, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: scaled(symbol == "circle.fill" ? 7 : 10), weight: .semibold))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: scaled(20), height: scaled(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: weekNumberWidth, height: scaled(20))
            ForEach(0..<7, id: \.self) { column in
                Text(weekdays[column])
                    .font(.system(size: scaled(12), weight: .medium))
                    .foregroundStyle(column >= 5 ? Palette.secondaryText : .primary)
                    .frame(width: cellWidth, height: scaled(20))
            }
        }
    }

    private var calendarRows: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    // MonthGrid is Monday-first, so each row's first date anchors its ISO week.
                    Text(weekNumber(for: model.grid.days[row * 7].date))
                        .font(.system(size: scaled(10), weight: .regular, design: .rounded))
                        .foregroundStyle(Palette.secondaryText.opacity(0.8))
                        .frame(width: weekNumberWidth, height: rowHeight)
                }
            }

            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            dateButton(at: row * 7 + column)
                        }
                    }
                }
            }
            .frame(width: cellWidth * 7, height: rowHeight * 6)
        }
    }

    private func dateButton(at index: Int) -> some View {
        let day = model.grid.days[index]
        let inMonth = model.grid.isInMonth(day)
        let isToday = day.date == model.today
        let isHighlighted = (model.selected ?? model.today) == day.date
        let agendaCount = previewEventCounts?[day.date] ?? calendarStore.eventCount(on: day.date) ?? 0
        let occasionColor: Color = day.hasHighlightedEvent || day.isOffDay
            ? Palette.red : Palette.blue

        return Button {
            model.select(day)
        } label: {
            VStack(spacing: 0) {
                Text(String(day.date.day))
                    .font(.system(size: scaled(13), weight: isHighlighted ? .semibold : .regular))
                    .foregroundStyle(isHighlighted ? .white : (day.isRestDay || day.hasHighlightedEvent ? Palette.red : .primary))
                Text(day.lunarShortText)
                    .font(.system(size: max(9, scaled(9))))
                    .foregroundStyle(isHighlighted ? .white : Palette.secondaryText)
                    .lineLimit(1)
                    .frame(width: cellWidth, alignment: .center)
            }
            .frame(width: cellWidth - scaled(4), height: rowHeight - scaled(4))
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: scaled(5)).fill(Palette.calendarSelection)
                }
            }
            .overlay {
                if isToday && !isHighlighted {
                    RoundedRectangle(cornerRadius: scaled(5))
                        .stroke(Palette.calendarSelection, lineWidth: scaled(1.2))
                }
            }
            .overlay(alignment: .topTrailing) {
                if day.hasOccasion {
                    Circle()
                        .fill(occasionColor)
                        .frame(width: scaled(3), height: scaled(3))
                        .offset(x: -scaled(2), y: scaled(3))
                }
            }
            .overlay(alignment: .topLeading) {
                if agendaCount > 0 {
                    Circle()
                        .fill(isHighlighted ? .white : Palette.accent)
                        .frame(width: scaled(3), height: scaled(3))
                        .offset(x: scaled(2), y: scaled(3))
                }
            }
            .opacity(inMonth ? 1 : 0.34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: cellWidth, height: rowHeight)
        .help("\(day.solarText) \(day.weekdayName) \(day.lunarText)\(day.allEvents.isEmpty ? "" : "，\(day.allEvents)")\(agendaCount > 0 ? "，\(agendaCount)项日程" : "")")
        .accessibilityLabel("\(day.solarText) \(day.weekdayName)，\(day.lunarShortText)\(day.allEvents.isEmpty ? "" : "，\(day.allEvents)")\(agendaCount > 0 ? "，\(agendaCount)项日程" : "")\(isHighlighted ? "，已选中" : (isToday ? "，今天" : ""))")
    }

    private func weekNumber(for date: SolarDate) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let components = DateComponents(year: date.year, month: date.month, day: date.day)
        guard let value = calendar.date(from: components),
              let week = calendar.dateComponents([.weekOfYear], from: value).weekOfYear else { return "" }
        return String(week)
    }
}
