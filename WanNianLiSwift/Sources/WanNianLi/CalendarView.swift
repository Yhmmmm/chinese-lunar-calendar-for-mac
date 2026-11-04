import AppKit
import LunarCore
import SwiftUI

/// 日历使用的颜色，自动适配浅色 / 深色模式。
enum Palette {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        })
    }

    static let red = dynamic(light: 0xC4473D, dark: 0xE27D72)
    static let blue = dynamic(light: 0x2F6BC4, dark: 0x74A7E8)
    static let accent = Color.accentColor
    static let calendarSelection = dynamic(light: 0x315F87, dark: 0x477A98)
    static let background = dynamic(light: 0xFFFFFF, dark: 0x1E1E20)
    static let nsBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x20 / 255.0, alpha: 1) : .white
    }
    static let secondaryText = dynamic(light: 0x55555A, dark: 0xB4B4B9)
    static let panel = dynamic(light: 0xF2F3F5, dark: 0x2B2B2E)
    static let hovered = dynamic(light: 0xE9EAED, dark: 0x343438)
    static let selected = Color.accentColor.opacity(0.18)
}

struct CalendarView: View {
    @ObservedObject var model: CalendarViewModel
    @ObservedObject var menu: AppMenu
    @ObservedObject var calendarStore: SystemCalendarStore
    var loadSystemCalendar = true
    var previewEvents: [AgendaEvent]?

    @State private var showUpcoming = false
    @State private var eventOpenMessage: String?

    private var scale: CGFloat { menu.calendarSize.scale }
    private var width: CGFloat { scaled(332) }
    private var day: CalendarDay { model.detailDay }
    private func scaled(_ value: CGFloat) -> CGFloat { value * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactMonthGrid(model: model, calendarStore: calendarStore, scale: scale,
                             previewEventCounts: previewEvents.map { [day.date: $0.count] })
                .padding(.horizontal, scaled(16))
                .padding(.top, scaled(10))
                .padding(.bottom, scaled(8))
            Divider()
            agenda
            Divider()
            toolbar
        }
        .frame(width: width)
        .background(Palette.background)
        .onAppear {
            loadVisibleEvents()
        }
        .onChange(of: model.grid.days.first?.date) { _ in
            loadVisibleEvents()
        }
        .onChange(of: day.date) { _ in
            eventOpenMessage = nil
            loadVisibleEvents()
        }
    }

    private func loadVisibleEvents() {
        guard loadSystemCalendar else { return }
        calendarStore.load(visibleDates: model.grid.days.map(\.date), selectedDate: day.date)
    }

    private var toolbar: some View {
        HStack(spacing: scaled(4)) {
            toolButton("plus", help: "自定义日期") { menu.onEditCustomEvents() }
            Spacer(minLength: 0)
            toolButton("list.bullet.rectangle", help: "即将到来") { showUpcoming.toggle() }
                .popover(isPresented: $showUpcoming, arrowEdge: .top) { upcomingList }
            toolButton(menu.isPinned ? "pin.slash" : "pin",
                       help: menu.isPinned ? "取消固定窗口" : "固定窗口") {
                menu.onTogglePinned()
            }
            menu.button
                .frame(width: scaled(23), height: scaled(26))
        }
        .padding(.horizontal, scaled(9))
        .frame(height: scaled(38))
    }

    private func toolButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: scaled(13)))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: scaled(23), height: scaled(26))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var agenda: some View {
        VStack(alignment: .leading, spacing: scaled(6)) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(day.date.month)月\(day.date.day)日 \(day.weekdayName.replacingOccurrences(of: "星期", with: "周"))")
                    .font(.system(size: scaled(14), weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel("\(day.date.month)月\(day.date.day)日 \(day.weekdayName)")
                Spacer(minLength: scaled(8))
                if day.date == model.today {
                    Text("今天")
                        .font(.system(size: scaled(10), weight: .medium))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            Text(day.lunarText)
                .font(.system(size: scaled(11)))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if !day.allEvents.isEmpty {
                Text(day.allEvents)
                    .font(.system(size: scaled(11)))
                    .foregroundStyle(day.hasHighlightedEvent ? Palette.red : Palette.secondaryText)
                    .lineLimit(2)
                    .help(day.allEvents)
                    .accessibilityLabel("节日和节气：\(day.allEvents)")
            }
            agendaContent
            if let eventOpenMessage {
                Text(eventOpenMessage)
                    .font(.system(size: scaled(10)))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, scaled(16))
        .padding(.top, scaled(12))
        .padding(.bottom, scaled(13))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var agendaContent: some View {
        if let previewEvents {
            agendaList(previewEvents)
        } else {
            switch calendarStore.authorization {
            case .notDetermined, .writeOnly:
                VStack(alignment: .leading, spacing: scaled(4)) {
                    Button {
                        calendarStore.requestAccess()
                    } label: {
                        Label(calendarStore.isRequestingAccess ? "正在连接系统日历…" : "连接系统日历",
                              systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(calendarStore.isRequestingAccess)
                    .foregroundStyle(Palette.accent)
                    .help("允许读取 macOS 日历中的日程")
                    if let error = calendarStore.errorMessage {
                        Text(error)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .frame(minHeight: scaled(52), alignment: .topLeading)
            case .denied, .restricted:
                VStack(alignment: .leading, spacing: scaled(4)) {
                    Text("未获得日历读取权限")
                        .foregroundStyle(Palette.secondaryText)
                    Button("打开系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                }
                .frame(minHeight: scaled(52), alignment: .topLeading)
            case .authorized:
                if calendarStore.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: scaled(52))
                } else if let error = calendarStore.errorMessage {
                    Text(error)
                        .foregroundStyle(Palette.secondaryText)
                        .frame(minHeight: scaled(52), alignment: .topLeading)
                } else if calendarStore.events.isEmpty {
                    Text("这一天没有日程")
                        .foregroundStyle(Palette.secondaryText)
                        .frame(minHeight: scaled(52), alignment: .topLeading)
                } else {
                    agendaList(calendarStore.events)
                }
            }
        }
    }

    private func agendaList(_ events: [AgendaEvent]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: scaled(7)) {
                ForEach(events) { event in
                    agendaRow(event)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: scaled(148))
    }

    private func agendaRow(_ event: AgendaEvent) -> some View {
        Button {
            eventOpenMessage = nil
            CalendarEventOpener.shared.open(event, selectedDate: day.date) { result in
                eventOpenMessage = result.message
            }
        } label: {
            HStack(alignment: .top, spacing: scaled(8)) {
                Text(event.isAllDay ? "全天" : clockText(event.startDate))
                    .font(.system(size: scaled(10), weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: scaled(40), alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                RoundedRectangle(cornerRadius: scaled(2))
                    .fill(eventColor(event))
                    .frame(width: scaled(3), height: scaled(29))
                VStack(alignment: .leading, spacing: scaled(2)) {
                    Text(event.title)
                        .font(.system(size: scaled(12), weight: .medium))
                        .lineLimit(2)
                    let detail = event.isAllDay ? (event.calendarTitle ?? "全天") : eventTime(event)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: scaled(10)))
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在系统日历中打开\(event.title)\(event.calendarTitle.map { "（\($0)）" } ?? "")")
        .accessibilityLabel("\(event.title)，\(eventTime(event))，在系统日历中打开")
    }

    private func eventColor(_ event: AgendaEvent) -> Color {
        guard let rgb = event.calendarColorRGB else { return Palette.accent }
        return Color(nsColor: NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                                      green: CGFloat((rgb >> 8) & 0xff) / 255,
                                      blue: CGFloat(rgb & 0xff) / 255, alpha: 1))
    }

    private func eventTime(_ event: AgendaEvent) -> String {
        if event.isAllDay { return "全天" }
        let calendar = Calendar.localGregorian
        let start = clockText(event.startDate)
        let end = clockText(event.endDate)
        if calendar.isDate(event.startDate, inSameDayAs: event.endDate) {
            return "\(start)–\(end)"
        }
        return "\(dateText(event.startDate)) \(start)–\(dateText(event.endDate)) \(end)"
    }

    private func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func dateText(_ date: Date) -> String {
        let components = Calendar.localGregorian.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }

    var upcomingList: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Text("即将到来")
                .font(.system(size: scaled(13), weight: .semibold))
            if model.upcoming.isEmpty {
                Text("近期没有节日或自定义日期")
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ForEach(model.upcoming) { event in
                    Button {
                        model.select(event.day)
                        showUpcoming = false
                    } label: {
                        HStack {
                            Text(event.name)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(event.day.date.month)月\(event.day.date.day)日")
                                .foregroundStyle(Palette.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .font(.system(size: scaled(12)))
        .padding(scaled(12))
        .frame(width: scaled(270))
        .background(Palette.background)
    }
}
