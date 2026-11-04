import Combine
import Foundation
import LunarCore

extension Calendar {
    /// 本地时区的公历。不能用 Calendar.current：用户可能在系统设置中选择了佛历、和历等
    static var localGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }
}

extension SolarDate {
    /// 本地时区的今天
    static var today: SolarDate {
        let c = Calendar.localGregorian.dateComponents([.year, .month, .day], from: Date())
        return SolarDate(year: c.year!, month: c.month!, day: c.day!)
    }
}

/// 日历弹出窗口的状态：当前显示的年月、选中的日期
@MainActor
final class CalendarViewModel: ObservableObject {
    static let years = LunarCalendar.supportedYears
    private static let browsingYearKey = "browsingCalendarYear"
    private static let browsingMonthKey = "browsingCalendarMonth"
    private static let browsingDayKey = "browsingCalendarDay"

    @Published private(set) var year: Int
    @Published private(set) var month: Int
    @Published private(set) var grid: MonthGrid
    /// 用户点击选中的日期；为 nil 时高亮今天
    @Published private(set) var selected: SolarDate?
    @Published private(set) var today: SolarDate
    @Published private(set) var upcoming: [UpcomingEvent] = []

    private let store: DataStore
    private let preferences: UserDefaults
    private var cancellable: AnyCancellable?

    init(store: DataStore, preferences: UserDefaults = .standard, today: SolarDate = .today) {
        self.store = store
        self.preferences = preferences
        let restored = Self.restoredBrowsingState(from: preferences, today: today)
        self.today = today
        year = restored?.year ?? today.year
        month = restored?.month ?? today.month
        selected = restored?.selected
        grid = MonthGrid(year: restored?.year ?? today.year, month: restored?.month ?? today.month,
                         data: store.data, firstWeekday: 1)
        if preferences.bool(forKey: "rememberBrowsingDate"),
           preferences.object(forKey: Self.browsingYearKey) != nil, restored == nil {
            Self.clearBrowsingState(in: preferences)
        }
        if let restored, restored.selected == nil,
           (preferences.integer(forKey: Self.browsingYearKey) != today.year
            || preferences.integer(forKey: Self.browsingMonthKey) != today.month) {
            saveBrowsingState()
        }
        updateUpcoming(data: store.data)
        cancellable = store.$data.dropFirst().sink { [weak self] data in
            guard let self else { return }
            self.grid = MonthGrid(year: self.year, month: self.month, data: data, firstWeekday: 1)
            self.updateUpcoming(data: data)
        }
    }

    // MARK: - 导航

    /// 回到今天，并清除选中的日期
    func showToday() {
        today = .today
        updateUpcoming(data: store.data)
        show(year: today.year, month: today.month)
        selected = nil
        saveBrowsingState()
    }

    /// 跨天时更新"今天"，保留当前显示的月份和选中的日期
    func refreshToday() {
        if today != .today {
            let followedToday = selected == nil && year == today.year && month == today.month
            today = .today
            updateUpcoming(data: store.data)
            if followedToday {
                year = today.year
                month = today.month
                grid = MonthGrid(year: year, month: month, data: store.data, firstWeekday: 1)
                saveBrowsingState()
            }
        }
    }

    func setRememberBrowsingDate(_ enabled: Bool) {
        preferences.set(enabled, forKey: "rememberBrowsingDate")
        if enabled {
            saveBrowsingState()
        } else {
            Self.clearBrowsingState(in: preferences)
        }
    }

    /// 展示今天起 90 天内最多 6 个节日、自定义事件和节气。
    private func updateUpcoming(data: CalendarData) {
        upcoming = UpcomingEvents.find(from: today, data: data)
    }

    func setYear(_ y: Int) { show(year: y, month: month) }
    func setMonth(_ m: Int) { show(year: year, month: m) }

    /// 前后移动若干年；超出范围时返回 false
    @discardableResult
    func moveYear(by delta: Int) -> Bool {
        guard Self.years.contains(year + delta) else { return false }
        show(year: year + delta, month: month)
        return true
    }

    /// 前后移动若干月；超出范围时返回 false
    @discardableResult
    func moveMonth(by delta: Int) -> Bool {
        let index = year * 12 + (month - 1) + delta
        guard Self.years.contains(index / 12) else { return false }
        show(year: index / 12, month: index % 12 + 1)
        return true
    }

    var canMoveBackward: Bool { year * 12 + month > Self.years.lowerBound * 12 + 1 }
    var canMoveForward: Bool { year * 12 + month < Self.years.upperBound * 12 + 12 }

    private func show(year: Int, month: Int) {
        if year != self.year || month != self.month {
            let visibleDay = selected ?? today
            selected = SolarDate(year: year, month: month,
                                 day: min(visibleDay.day, SolarDate.daysInMonth(year: year, month: month)))
        }
        self.year = year
        self.month = month
        grid = MonthGrid(year: year, month: month, data: store.data, firstWeekday: 1)
        saveBrowsingState()
    }

    /// 点击日期：点击今天会清除选中，回到默认状态；点击上月或下月的日期时切换到该月
    func select(_ day: CalendarDay) {
        selected = day.date == today ? nil : day.date
        if !grid.isInMonth(day) && Self.years.contains(day.date.year) {
            show(year: day.date.year, month: day.date.month)
        }
        saveBrowsingState()
    }

    // MARK: - 显示

    /// 高亮显示的日期：选中的日期，没有选中时为今天
    func isHighlighted(_ day: CalendarDay) -> Bool {
        day.date == (selected ?? today)
    }

    /// 详细信息面板显示的日期：选中的日期，没有选中时为今天
    var detailDay: CalendarDay {
        let date = selected ?? today
        return grid.days.first { $0.date == date } ?? CalendarDay(date: date, data: store.data)
    }

    private func saveBrowsingState() {
        guard preferences.bool(forKey: "rememberBrowsingDate") else { return }
        preferences.set(year, forKey: Self.browsingYearKey)
        preferences.set(month, forKey: Self.browsingMonthKey)
        preferences.set(selected?.day ?? 0, forKey: Self.browsingDayKey)
    }

    private static func restoredBrowsingState(from preferences: UserDefaults, today: SolarDate)
        -> (year: Int, month: Int, selected: SolarDate?)? {
        guard preferences.bool(forKey: "rememberBrowsingDate"),
              preferences.object(forKey: browsingYearKey) != nil,
              preferences.object(forKey: browsingMonthKey) != nil,
              preferences.object(forKey: browsingDayKey) != nil else { return nil }
        let year = preferences.integer(forKey: browsingYearKey)
        let month = preferences.integer(forKey: browsingMonthKey)
        let day = preferences.integer(forKey: browsingDayKey)
        guard years.contains(year), (1...12).contains(month),
              (0...SolarDate.daysInMonth(year: year, month: month)).contains(day) else { return nil }
        if day == 0 {
            return (today.year, today.month, nil)
        }
        let selected = SolarDate(year: year, month: month, day: day)
        guard selected.year == year, selected.month == month else { return nil }
        return (year, month, selected)
    }

    private static func clearBrowsingState(in preferences: UserDefaults) {
        preferences.removeObject(forKey: browsingYearKey)
        preferences.removeObject(forKey: browsingMonthKey)
        preferences.removeObject(forKey: browsingDayKey)
    }

    /// 标题栏的两部分文字
    var title: (solar: String, lunar: String) {
        let visible = grid.days.filter { grid.isInMonth($0) }
        if let day = visible.first(where: isHighlighted) {
            return (day.solarText, day.lunarText)
        }
        // 当前月份中没有选中的日期或今天，显示月份信息（取 15 日，此时本月的"节"已过）
        let middle = visible[14]
        return ("\(year)年\(month)月", "\(middle.ganZhiYear)年[\(middle.shengXiao)] \(middle.ganZhiMonth)月")
    }
}
