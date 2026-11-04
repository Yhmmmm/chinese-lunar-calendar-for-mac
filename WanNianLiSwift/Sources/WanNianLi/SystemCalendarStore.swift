import AppKit
import Combine
import EventKit
import LunarCore

/// EventKit 对象只在查询队列上使用，界面接收可独立保存的事件值。
struct AgendaEvent: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    /// 外部 UID 与日历标识用于打开系统日历；不能以界面组合 id 代替它们。
    let externalIdentifier: String?
    let calendarIdentifier: String?
    let eventIdentifier: String?
    let occurrenceDate: Date?
    let calendarTitle: String?
    let calendarColorRGB: UInt32?

    init(id: String, title: String, startDate: Date, endDate: Date, isAllDay: Bool,
         externalIdentifier: String? = nil, calendarIdentifier: String? = nil,
         eventIdentifier: String? = nil, occurrenceDate: Date? = nil,
         calendarTitle: String? = nil, calendarColorRGB: UInt32? = nil) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.externalIdentifier = externalIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.eventIdentifier = eventIdentifier
        self.occurrenceDate = occurrenceDate
        self.calendarTitle = calendarTitle
        self.calendarColorRGB = calendarColorRGB
    }
}

enum CalendarAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case writeOnly

    static var current: CalendarAuthorization {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: return .authorized
            case .writeOnly: return .writeOnly
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .denied
            }
        } else {
            switch status {
            case .authorized: return .authorized
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .denied
            }
        }
    }
}

/// 查询接口只传递值，测试可以注入受控事件源，不访问真实系统日历。
protocol CalendarEventSource: Sendable {
    /// 事件源可以跳过已被新查询或 invalidate 替代的请求，不再调用其 completion。
    func fetch(in interval: DateInterval, completion: @escaping @Sendable (CalendarReadResult) -> Void)
    func requestAccess(completion: @escaping @Sendable (Bool) -> Void)
    func invalidate()
}

struct CalendarReadResult: Sendable {
    let authorization: CalendarAuthorization
    let events: [AgendaEvent]
    let errorMessage: String?

    init(authorization: CalendarAuthorization, events: [AgendaEvent] = [], errorMessage: String? = nil) {
        self.authorization = authorization
        self.events = events
        self.errorMessage = errorMessage
    }
}

private struct CalendarQueryRange: Equatable, Sendable {
    let dates: [SolarDate]
    let timeZoneIdentifier: String
    let dayIntervals: [DateInterval]

    var interval: DateInterval { DateInterval(start: dayIntervals[0].start, end: dayIntervals.last!.end) }

    init?(dates: [SolarDate], timeZone: TimeZone) {
        guard !dates.isEmpty,
              dates.allSatisfy({ SystemCalendarStore.dayInterval(for: $0, timeZone: timeZone) != nil }) else { return nil }
        self.dates = Array(Set(dates)).sorted()
        self.timeZoneIdentifier = timeZone.identifier
        self.dayIntervals = self.dates.compactMap { SystemCalendarStore.dayInterval(for: $0, timeZone: timeZone) }
        guard self.dayIntervals.count == self.dates.count else { return nil }
    }
}

/// 只读系统日历。初始化不会请求权限或读取事件，调用 load 后才开始查询。
@MainActor
final class SystemCalendarStore: ObservableObject {
    @Published private(set) var authorization: CalendarAuthorization
    @Published private(set) var events: [AgendaEvent] = []
    @Published private(set) var eventsByDay: [SolarDate: [AgendaEvent]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var errorMessage: String?

    private let source: any CalendarEventSource
    private let authorizationProvider: @MainActor () -> CalendarAuthorization
    private let timeZoneProvider: @MainActor () -> TimeZone
    private var requestedDates: [SolarDate] = []
    private var selectedDate: SolarDate?
    private var activeRange: CalendarQueryRange?
    private var hasSnapshot = false
    private var generation: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    init(source: any CalendarEventSource = EventKitSource(),
         authorizationProvider: @escaping @MainActor () -> CalendarAuthorization = { .current },
         timeZoneProvider: @escaping @MainActor () -> TimeZone = { .current },
         observeChanges: Bool = true) {
        self.source = source
        self.authorizationProvider = authorizationProvider
        self.timeZoneProvider = timeZoneProvider
        self.authorization = authorizationProvider()
        guard observeChanges else { return }
        // 通过主队列接收系统通知；截图若未调用 load，不会因此读取真实日程。
        for name in [Notification.Name.EKEventStoreChanged,
                     NSApplication.didBecomeActiveNotification,
                     Notification.Name.NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// 兼容原单日入口。已载入月范围时，切日继续复用该范围。
    func load(for date: SolarDate) {
        load(visibleDates: requestedDates.contains(date) ? requestedDates : [date], selectedDate: date)
    }

    func select(_ date: SolarDate) { load(for: date) }

    /// nil 表示未加载、读取失败或未授权；0 才表示已确认当天没有日程。
    func eventCount(on date: SolarDate) -> Int? {
        guard authorization == .authorized, hasSnapshot, !isLoading else { return nil }
        return eventsByDay[date]?.count
    }

    /// 月格和详情共用同一份范围快照；同范围切日不会重复读取 EventKit。
    func load(visibleDates: [SolarDate], selectedDate date: SolarDate) {
        requestedDates = visibleDates
        selectedDate = date
        authorization = authorizationProvider()

        guard authorization == .authorized else {
            clearSnapshot()
            source.invalidate()
            return
        }
        guard visibleDates.contains(date),
              let range = CalendarQueryRange(dates: visibleDates, timeZone: timeZoneProvider()) else {
            clearSnapshot()
            errorMessage = "无法读取当前月历范围的日程。"
            return
        }

        if activeRange == range, isLoading || hasSnapshot {
            events = hasSnapshot ? eventsByDay[date, default: []] : []
            return
        }
        beginQuery(range)
    }

    private func beginQuery(_ range: CalendarQueryRange) {
        clearSnapshot()
        activeRange = range
        isLoading = true
        let request = generation
        source.fetch(in: range.interval) { [weak self] result in
            // 实际事件源在后台查询队列回调；日期分组也不占用界面线程。
            let grouped = result.authorization == .authorized && result.errorMessage == nil
                ? Self.group(result.events, in: range) : [:]
            Task { @MainActor [weak self] in
                guard let self, self.generation == request else { return }
                let current = self.authorizationProvider()
                self.authorization = current
                guard current == .authorized else {
                    self.clearSnapshot()
                    self.source.invalidate()
                    return
                }
                guard result.authorization == .authorized else {
                    self.clearSnapshot()
                    self.errorMessage = "日历访问状态已变化，请重试。"
                    return
                }
                if let error = result.errorMessage {
                    self.clearSnapshot()
                    self.errorMessage = error
                    return
                }
                self.eventsByDay = grouped
                self.hasSnapshot = true
                self.events = self.selectedDate.flatMap { grouped[$0] } ?? []
                self.isLoading = false
            }
        }
    }

    private func clearSnapshot() {
        generation &+= 1
        activeRange = nil
        hasSnapshot = false
        events = []
        eventsByDay = [:]
        isLoading = false
        errorMessage = nil
    }

    /// 只由界面的“连接系统日历”操作显式调用，绝不在初始化或普通刷新时弹出授权。
    func requestAccess() {
        guard !isRequestingAccess else { return }
        authorization = authorizationProvider()
        errorMessage = nil
        if authorization == .authorized {
            refresh()
            return
        }
        guard authorization == .notDetermined || authorization == .writeOnly else {
            clearSnapshot()
            source.invalidate()
            return
        }

        isRequestingAccess = true
        source.requestAccess { [weak self] failed in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRequestingAccess = false
                self.authorization = self.authorizationProvider()
                if self.authorization == .authorized {
                    self.refresh()
                } else {
                    self.clearSnapshot()
                    self.source.invalidate()
                    self.errorMessage = failed ? "暂时无法连接系统日历，请稍后重试。" : nil
                }
            }
        }
    }

    /// 从系统设置返回、事件库改变或时区变化时，重建当前范围快照。
    func refresh() {
        authorization = authorizationProvider()
        clearSnapshot()
        source.invalidate()
        if let selectedDate {
            load(visibleDates: requestedDates, selectedDate: selectedDate)
        }
    }

    /// 测试与预览可复用分组规则，不需要创建或授权 EKEventStore。
    nonisolated static func groupEvents(_ events: [AgendaEvent], for dates: [SolarDate],
                                       timeZone: TimeZone = .current) -> [SolarDate: [AgendaEvent]] {
        guard let range = CalendarQueryRange(dates: dates, timeZone: timeZone) else { return [:] }
        return group(events, in: range)
    }

    private nonisolated static func group(_ events: [AgendaEvent], in range: CalendarQueryRange)
        -> [SolarDate: [AgendaEvent]] {
        var seen = Set<String>()
        let ordered = events.filter {
            $0.startDate.timeIntervalSinceReferenceDate.isFinite && $0.endDate.timeIntervalSinceReferenceDate.isFinite
                && $0.endDate >= $0.startDate && seen.insert($0.id).inserted
        }.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            if $0.endDate != $1.endDate { return $0.endDate < $1.endDate }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
        return Dictionary(uniqueKeysWithValues: zip(range.dates, range.dayIntervals).map { date, interval in
            (date, ordered.filter { event in
                event.startDate == event.endDate
                    ? event.startDate >= interval.start && event.startDate < interval.end
                    : event.startDate < interval.end && event.endDate > interval.start
            })
        })
    }

    /// 使用实际日边界，夏令时切换日可能是 23 或 25 小时，不能固定加 86400 秒。
    nonisolated static func dayInterval(for date: SolarDate, timeZone: TimeZone = .current) -> DateInterval? {
        guard (1...9999).contains(date.year), (1...12).contains(date.month),
              (1...SolarDate.daysInMonth(year: date.year, month: date.month)).contains(date.day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: date.year, month: date.month, day: date.day, hour: 12)
        guard let noon = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: noon)
        guard resolved.year == date.year, resolved.month == date.month, resolved.day == date.day else { return nil }
        return calendar.dateInterval(of: .day, for: noon)
    }
}

/// 在串行队列执行前检查查询代次，避免快速翻月时排队读取每一个过期月份。
/// 已开始的同步 EventKit 查询不能中断；它完成后也会再次检查代次。
final class CalendarQueryScheduler: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var latestRequest: UInt64 = 0

    init(queue: DispatchQueue) { self.queue = queue }

    private func nextRequest() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        latestRequest &+= 1
        return latestRequest
    }

    private func isCurrent(_ request: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return latestRequest == request
    }

    func invalidate() { _ = nextRequest() }

    func fetch(operation: @escaping @Sendable () -> CalendarReadResult,
               completion: @escaping @Sendable (CalendarReadResult) -> Void) {
        let request = nextRequest()
        queue.async { [self] in
            guard isCurrent(request) else { return }
            let result = operation()
            guard isCurrent(request) else { return }
            completion(result)
        }
    }
}

/// 所有 EKEventStore / EKEvent 访问均限制在 queue 上。回调只传递 Sendable 值。
final class EventKitSource: CalendarEventSource, @unchecked Sendable {
    private let queue: DispatchQueue
    private let queries: CalendarQueryScheduler
    private var eventStore: EKEventStore?

    init() {
        let queue = DispatchQueue(label: "com.zfdang.WanNianLiSwift.system-calendar", qos: .userInitiated)
        self.queue = queue
        self.queries = CalendarQueryScheduler(queue: queue)
    }

    private func store() -> EKEventStore {
        if let eventStore { return eventStore }
        let created = EKEventStore()
        eventStore = created
        return created
    }

    func invalidate() {
        queries.invalidate()
        queue.async { [self] in eventStore?.reset() }
    }

    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let finished: EKEventStoreRequestAccessCompletionHandler = { _, error in
                completion(error != nil)
            }
            if #available(macOS 14.0, *) {
                store().requestFullAccessToEvents(completion: finished)
            } else {
                store().requestAccess(to: .event, completion: finished)
            }
        }
    }

    func fetch(in interval: DateInterval, completion: @escaping @Sendable (CalendarReadResult) -> Void) {
        queries.fetch(operation: { [self] in
            let authorization = CalendarAuthorization.current
            guard authorization == .authorized else {
                return CalendarReadResult(authorization: authorization, events: [])
            }
            let eventStore = store()
            let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
            let items = eventStore.events(matching: predicate).compactMap { event -> AgendaEvent? in
                guard event.status != .canceled,
                      let start = event.startDate, let end = event.endDate, end >= start else { return nil }
                // EventKit 的结束日期为开区间；恰好在次日零点结束的事件不属于次日。
                let overlaps = end == start
                    ? start >= interval.start && start < interval.end
                    : start < interval.end && end > interval.start
                guard overlaps else { return nil }
                let name = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let calendarIdentifier = event.calendar?.calendarIdentifier
                let externalIdentifier = event.calendarItemExternalIdentifier
                let identifier = event.calendarItemIdentifier.isEmpty
                    ? (event.eventIdentifier ?? externalIdentifier ?? "\(start.timeIntervalSinceReferenceDate)|\(end.timeIntervalSinceReferenceDate)|\(name)")
                    : event.calendarItemIdentifier
                let occurrence = event.occurrenceDate ?? start
                let id = "\(calendarIdentifier ?? "")|\(identifier)|\(occurrence.timeIntervalSinceReferenceDate)"
                let rgb = event.calendar?.cgColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
                let color = rgb.map {
                    (UInt32((min(1, max(0, $0.redComponent)) * 255).rounded()) << 16)
                        | (UInt32((min(1, max(0, $0.greenComponent)) * 255).rounded()) << 8)
                        | UInt32((min(1, max(0, $0.blueComponent)) * 255).rounded())
                }
                return AgendaEvent(id: id, title: name.isEmpty ? "未命名事件" : name,
                                   startDate: start, endDate: end, isAllDay: event.isAllDay,
                                   externalIdentifier: externalIdentifier, calendarIdentifier: calendarIdentifier,
                                   eventIdentifier: event.eventIdentifier, occurrenceDate: occurrence,
                                   calendarTitle: event.calendar?.title, calendarColorRGB: color)
            }
            let current = CalendarAuthorization.current
            return CalendarReadResult(authorization: current, events: current == .authorized ? items : [])
        }, completion: completion)
    }
}
