import Foundation
import LunarCore

/// 可控异步事件源：只返回测试数据，不创建 EKEventStore 或请求系统权限。
private final class FakeCalendarSource: CalendarEventSource, @unchecked Sendable {
    private struct Pending {
        let interval: DateInterval
        let completion: @Sendable (CalendarReadResult) -> Void
    }
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var accessCompletion: (@Sendable (Bool) -> Void)?
    private var invalidations = 0
    private var accessRequests = 0

    var intervals: [DateInterval] {
        lock.lock(); defer { lock.unlock() }
        return pending.map(\.interval)
    }
    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return accessRequests
    }

    func fetch(in interval: DateInterval, completion: @escaping @Sendable (CalendarReadResult) -> Void) {
        lock.lock(); defer { lock.unlock() }
        pending.append(Pending(interval: interval, completion: completion))
    }
    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        accessRequests += 1
        accessCompletion = completion
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        invalidations += 1
    }
    func complete(_ index: Int, with result: CalendarReadResult) {
        lock.lock()
        let callback = pending[index].completion
        lock.unlock()
        callback(result)
    }
    func completeAccess(failed: Bool = false) {
        lock.lock()
        let callback = accessCompletion
        accessCompletion = nil
        lock.unlock()
        callback?(failed)
    }
}

private final class QueryExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [Int] = []
    private var results: [CalendarReadResult] = []

    func executed(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        operations.append(index)
    }
    func completed(_ result: CalendarReadResult) {
        lock.lock(); defer { lock.unlock() }
        results.append(result)
    }
    var executedIndices: [Int] {
        lock.lock(); defer { lock.unlock() }
        return operations
    }
    var completions: [CalendarReadResult] {
        lock.lock(); defer { lock.unlock() }
        return results
    }
}

@MainActor
private final class CalendarTestEnvironment {
    var authorization: CalendarAuthorization = .authorized
    var timeZone = TimeZone(identifier: "Asia/Shanghai")!
}

@main
@MainActor
struct SystemCalendarRegressionTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("ok   " + message)
    }

    static func settle() async {
        // 让事件源的回调跳到 MainActor。只等待测试任务，不涉及系统日历或 UI。
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    static func instant(_ date: SolarDate, hour: Int = 0, minute: Int = 0,
                        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day,
                                                   hour: hour, minute: minute))!
    }

    private static func makeStore(_ source: FakeCalendarSource, _ environment: CalendarTestEnvironment) -> SystemCalendarStore {
        SystemCalendarStore(source: source, authorizationProvider: { environment.authorization },
                            timeZoneProvider: { environment.timeZone }, observeChanges: false)
    }

    private static func checkQueryCoalescing() {
        let queue = DispatchQueue(label: "calendar-regressions.pending-queries")
        let scheduler = CalendarQueryScheduler(queue: queue)
        let recorder = QueryExecutionRecorder()
        let blockerStarted = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        queue.async {
            blockerStarted.signal()
            _ = unblock.wait(timeout: .now() + 5)
        }
        check(blockerStarted.wait(timeout: .now() + 2) == .success, "test query queue is held before rapid navigation")
        for index in 0..<40 {
            scheduler.fetch(operation: {
                recorder.executed(index)
                return CalendarReadResult(authorization: .authorized)
            }, completion: { recorder.completed($0) })
        }
        unblock.signal()
        queue.sync {}
        check(recorder.executedIndices == [39] && recorder.completions.count == 1,
              "forty queued month queries execute only the latest operation and callback")

        let activeRecorder = QueryExecutionRecorder()
        let activeStarted = DispatchSemaphore(value: 0)
        let finishActive = DispatchSemaphore(value: 0)
        scheduler.fetch(operation: {
            activeRecorder.executed(0)
            activeStarted.signal()
            _ = finishActive.wait(timeout: .now() + 5)
            return CalendarReadResult(authorization: .authorized)
        }, completion: { activeRecorder.completed($0) })
        check(activeStarted.wait(timeout: .now() + 2) == .success, "test query starts before it is superseded")
        for index in 1...2 {
            scheduler.fetch(operation: {
                activeRecorder.executed(index)
                return CalendarReadResult(authorization: .authorized)
            }, completion: { activeRecorder.completed($0) })
        }
        finishActive.signal()
        queue.sync {}
        check(activeRecorder.executedIndices == [0, 2] && activeRecorder.completions.count == 1,
              "a running query finishes without publishing while queued stale work is skipped")

        let revokedRecorder = QueryExecutionRecorder()
        let revocationStarted = DispatchSemaphore(value: 0)
        let finishRevocation = DispatchSemaphore(value: 0)
        queue.async {
            revocationStarted.signal()
            _ = finishRevocation.wait(timeout: .now() + 5)
        }
        check(revocationStarted.wait(timeout: .now() + 2) == .success, "test queue is held before invalidation")
        scheduler.fetch(operation: {
            revokedRecorder.executed(0)
            return CalendarReadResult(authorization: .authorized)
        }, completion: { revokedRecorder.completed($0) })
        scheduler.invalidate()
        finishRevocation.signal()
        queue.sync {}
        check(revokedRecorder.executedIndices.isEmpty && revokedRecorder.completions.isEmpty,
              "invalidation prevents a queued query from reading or publishing events")
        scheduler.fetch(operation: {
            revokedRecorder.executed(1)
            return CalendarReadResult(authorization: .denied)
        }, completion: { revokedRecorder.completed($0) })
        queue.sync {}
        check(revokedRecorder.executedIndices == [1] && revokedRecorder.completions.first?.authorization == .denied,
              "a new current query after invalidation completes and preserves permission status")
    }

    static func main() async {
        checkQueryCoalescing()
        let first = SolarDate(year: 2026, month: 10, day: 28)
        let second = first.adding(days: 1)
        let third = first.adding(days: 2)
        let dates = [first, second, third]
        let allDay = AgendaEvent(id: "all-day", title: "全天", startDate: instant(first),
                                 endDate: instant(second), isAllDay: true)
        let across = AgendaEvent(id: "across", title: "跨日", startDate: instant(first, hour: 23),
                                 endDate: instant(second, hour: 1), isAllDay: false)
        let point = AgendaEvent(id: "point", title: "零时长", startDate: instant(second),
                                endDate: instant(second), isAllDay: false)
        let repeatedFirst = AgendaEvent(id: "series|1", title: "重复", startDate: instant(first, hour: 10),
                                        endDate: instant(first, hour: 11), isAllDay: false,
                                        externalIdentifier: "same-series", calendarIdentifier: "test-calendar")
        let repeatedSecond = AgendaEvent(id: "series|2", title: "重复", startDate: instant(second, hour: 10),
                                         endDate: instant(second, hour: 11), isAllDay: false,
                                         externalIdentifier: "same-series", calendarIdentifier: "test-calendar")
        let previous = AgendaEvent(id: "previous", title: "前日", startDate: instant(first.adding(days: -1)),
                                   endDate: instant(first), isAllDay: false)
        let invalid = AgendaEvent(id: "invalid", title: "无效", startDate: instant(second),
                                  endDate: instant(first), isAllDay: false)
        let sample = [across, repeatedSecond, point, allDay, repeatedFirst, repeatedFirst, previous, invalid]
        let grouped = SystemCalendarStore.groupEvents(sample, for: dates,
                                                       timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        check(grouped[first]?.map(\.id) == ["all-day", "series|1", "across"],
              "all-day comes first and duplicate instances are counted once")
        check(grouped[second]?.map(\.id) == ["across", "point", "series|2"],
              "cross-day and zero-duration events use half-open local day boundaries")
        check(grouped[third] == [], "loaded dates without events keep an explicit empty list")
        check(grouped.values.flatMap { $0 }.allSatisfy { $0.id != "previous" && $0.id != "invalid" },
              "events ending at range start and invalid durations are excluded")

        let newYork = TimeZone(identifier: "America/New_York")!
        let spring = SolarDate(year: 2026, month: 3, day: 8)
        let autumn = SolarDate(year: 2026, month: 11, day: 1)
        check(SystemCalendarStore.dayInterval(for: spring, timeZone: newYork)?.duration == 23 * 3600,
              "spring DST day has 23 hours")
        check(SystemCalendarStore.dayInterval(for: autumn, timeZone: newYork)?.duration == 25 * 3600,
              "autumn DST day has 25 hours")
        let dstEvent = AgendaEvent(id: "dst", title: "DST", startDate: instant(spring, hour: 1, timeZone: newYork),
                                   endDate: instant(spring.adding(days: 1), timeZone: newYork), isAllDay: false)
        let dstGroups = SystemCalendarStore.groupEvents([dstEvent], for: [spring, spring.adding(days: 1)], timeZone: newYork)
        check(dstGroups[spring]?.count == 1 && dstGroups[spring.adding(days: 1)] == [],
              "DST grouping excludes the midnight end day")
        check(SystemCalendarStore.dayInterval(for: SolarDate(year: 2026, month: 2, day: 30)) == nil,
              "invalid civil dates are rejected")

        let source = FakeCalendarSource()
        let environment = CalendarTestEnvironment()
        let store = makeStore(source, environment)
        let visibleDates = (0..<42).map { first.adding(days: $0 - 30) }
        check(source.intervals.isEmpty && source.requestCount == 0, "initialization does not query or request access")
        store.load(visibleDates: visibleDates, selectedDate: first)
        store.load(visibleDates: visibleDates, selectedDate: second)
        check(source.intervals.count == 1 && store.isLoading && store.eventCount(on: first) == nil,
              "same-range selection during loading reuses one query and remains unknown")
        check(source.intervals[0].start == instant(visibleDates.first!)
              && source.intervals[0].end == instant(visibleDates.last!.adding(days: 1)),
              "one query covers all 42 visible dates including adjacent months")
        source.complete(0, with: CalendarReadResult(authorization: .authorized, events: sample))
        await settle()
        check(store.events == store.eventsByDay[second] && store.eventCount(on: first) == 3,
              "selected list and month counts use the same completed snapshot")
        check(store.eventCount(on: third) == 0 && store.eventCount(on: visibleDates.last!.adding(days: 1)) == nil,
              "loaded empty dates and dates outside the range are distinguishable")
        store.select(first)
        check(source.intervals.count == 1 && store.events == store.eventsByDay[first],
              "same-range selection after loading uses the cached list")
        store.refresh()
        check(source.intervals.count == 2 && store.events.isEmpty && store.eventCount(on: first) == nil,
              "event-store refresh clears stale results and reloads the visible range")
        source.complete(1, with: CalendarReadResult(authorization: .authorized, events: []))
        await settle()
        check(store.eventCount(on: first) == 0 && !store.isLoading, "refresh publishes the updated empty snapshot")

        let changingSource = FakeCalendarSource()
        let changing = makeStore(changingSource, environment)
        changing.load(visibleDates: dates, selectedDate: first)
        let nextMonth = SolarDate(year: 2026, month: 11, day: 28)
        let newEvent = AgendaEvent(id: "new-month", title: "新月", startDate: instant(nextMonth, hour: 10),
                                   endDate: instant(nextMonth, hour: 11), isAllDay: false)
        changing.load(visibleDates: [nextMonth], selectedDate: nextMonth)
        changingSource.complete(1, with: CalendarReadResult(authorization: .authorized, events: [newEvent]))
        await settle()
        changingSource.complete(0, with: CalendarReadResult(authorization: .authorized, events: sample))
        await settle()
        check(changing.events == [newEvent] && changing.eventCount(on: first) == nil,
              "a late previous-month response cannot overwrite the current month")

        changing.refresh()
        environment.authorization = .denied
        changingSource.complete(2, with: CalendarReadResult(authorization: .authorized, events: [newEvent]))
        await settle()
        check(changing.authorization == .denied && changing.events.isEmpty && changing.eventsByDay.isEmpty
              && changing.eventCount(on: nextMonth) == nil, "revocation during a query clears all event data")
        environment.authorization = .authorized
        changing.refresh()
        changingSource.complete(3, with: CalendarReadResult(authorization: .authorized, events: [newEvent]))
        await settle()
        check(changing.events == [newEvent], "permission restoration reloads the most recent visible range")
        environment.authorization = .denied
        changing.refresh()
        check(changing.eventsByDay.isEmpty && changing.events.isEmpty && changingSource.intervals.count == 4,
              "revocation after loading clears the snapshot without another query")
        environment.authorization = .authorized

        let errorSource = FakeCalendarSource()
        let errored = makeStore(errorSource, environment)
        errored.load(visibleDates: dates, selectedDate: first)
        errorSource.complete(0, with: CalendarReadResult(authorization: .authorized, errorMessage: "读取失败，请重试。"))
        await settle()
        check(errored.errorMessage != nil && errored.eventCount(on: first) == nil && !errored.isLoading,
              "query failures are not presented as an empty successful day")
        errored.load(visibleDates: dates, selectedDate: first)
        check(errorSource.intervals.count == 2 && errored.errorMessage == nil, "same-range load retries a failed query")
        errorSource.complete(1, with: CalendarReadResult(authorization: .authorized, events: [allDay]))
        await settle()
        environment.timeZone = newYork
        errored.load(visibleDates: dates, selectedDate: first)
        check(errorSource.intervals.count == 3 && errored.eventCount(on: first) == nil
              && errorSource.intervals[2] != errorSource.intervals[1], "a time-zone change invalidates the date range snapshot")

        let permissionSource = FakeCalendarSource()
        let permissionEnvironment = CalendarTestEnvironment()
        permissionEnvironment.authorization = .notDetermined
        let permissionStore = makeStore(permissionSource, permissionEnvironment)
        permissionStore.load(visibleDates: dates, selectedDate: first)
        check(permissionSource.intervals.isEmpty && permissionSource.requestCount == 0,
              "ordinary loading never prompts for calendar access")
        permissionStore.requestAccess()
        permissionStore.requestAccess()
        permissionStore.select(second)
        check(permissionSource.requestCount == 1 && permissionStore.isRequestingAccess,
              "access requests are explicit and duplicate requests are suppressed")
        permissionEnvironment.authorization = .authorized
        permissionSource.completeAccess()
        await settle()
        permissionSource.complete(0, with: CalendarReadResult(authorization: .authorized, events: [point]))
        await settle()
        check(permissionStore.events == [point] && !permissionStore.isRequestingAccess,
              "granting access loads the date most recently selected during the prompt")

        let failedSource = FakeCalendarSource()
        let failedEnvironment = CalendarTestEnvironment()
        failedEnvironment.authorization = .notDetermined
        let failedStore = makeStore(failedSource, failedEnvironment)
        failedStore.load(visibleDates: dates, selectedDate: first)
        failedStore.requestAccess()
        failedSource.completeAccess(failed: true)
        await settle()
        check(failedStore.errorMessage != nil && !failedStore.isRequestingAccess && failedSource.intervals.isEmpty,
              "failed access requests expose a retryable error without querying")
        failedStore.requestAccess()
        check(failedSource.requestCount == 2, "a failed access request can be retried explicitly")
        failedEnvironment.authorization = .authorized
        failedSource.completeAccess()
        await settle()
        failedSource.complete(0, with: CalendarReadResult(authorization: .denied, events: [allDay]))
        await settle()
        check(failedStore.events.isEmpty && failedStore.eventsByDay.isEmpty && failedStore.errorMessage != nil,
              "a source that lost permission cannot publish data even after authorization changes again")
    }
}
