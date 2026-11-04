import AppKit
import Carbon
import LunarCore

/// 只编译系统日历脚本；执行的 handler 仅回显参数，不向 Calendar 发送事件。
@main
struct CalendarEventOpenerRegressionTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("ok   " + message)
    }

    static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func checkDisplayedDay(_ request: CalendarEventOpenRequest, equals expected: SolarDate,
                                  timeZone: TimeZone, message: String) {
        let parts = calendar(in: timeZone).dateComponents([.year, .month, .day, .hour], from: request.displayDate)
        check(parts.year == expected.year && parts.month == expected.month && parts.day == expected.day
              && parts.hour == 12, message)
    }

    @MainActor
    static func main() async {
        var error: NSDictionary?
        guard let calendarScript = NSAppleScript(source: CalendarEventScript.source) else {
            fatalError("Calendar script cannot be created")
        }
        check(calendarScript.compileAndReturnError(&error), "Calendar public-dictionary script compiles without execution")

        // 这个脚本没有 tell application；即使参数含脚本语法，也仅作为字符串返回。
        let localScript = NSAppleScript(source: """
        on openCalendarEvent(displayDate, occurrenceDate, requestedUID, requestedCalendarID)
            return {displayDate, occurrenceDate, requestedUID, requestedCalendarID}
        end openCalendarEvent
        """)!
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let originalStart = calendar(in: shanghai).date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 23))!
        let request = CalendarEventOpenRequest(startDate: originalStart,
                                               selectedDate: SolarDate(year: 2026, month: 10, day: 29),
                                               externalIdentifier: "uid-引号\"-反斜杠\\-换行\n-do shell script-🌙",
                                               calendarIdentifier: "calendar-中文\n\"quotes\"", timeZone: shanghai)
        error = nil
        let response = localScript.executeAppleEvent(CalendarEventScript.invocation(for: request), error: &error)
        check(error == nil, "local descriptor handler executes without external automation")
        check(response.atIndex(1)?.dateValue == request.displayDate, "selected date stays the first typed Date argument")
        check(response.atIndex(2)?.dateValue == originalStart, "event start stays a separate typed Date argument")
        check(response.atIndex(3)?.stringValue == request.externalIdentifier,
              "event UID preserves quotes, backslashes, newlines, Chinese and emoji")
        check(response.atIndex(4)?.stringValue == request.calendarIdentifier,
              "calendar ID is passed as a string without source interpolation")
        checkDisplayedDay(request, equals: SolarDate(year: 2026, month: 10, day: 29), timeZone: shanghai,
                          message: "cross-day fallback displays the selected day rather than the event start day")
        check(request.startDate == originalStart && request.displayDate != originalStart,
              "selecting a later day does not change the event matching time")

        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        for selected in [SolarDate(year: 2026, month: 3, day: 8), SolarDate(year: 2026, month: 11, day: 1)] {
            let daylightSavingRequest = CalendarEventOpenRequest(startDate: originalStart, selectedDate: selected,
                                                                  externalIdentifier: "", calendarIdentifier: "",
                                                                  timeZone: losAngeles)
            checkDisplayedDay(daylightSavingRequest, equals: selected, timeZone: losAngeles,
                              message: "DST transition \(selected.key) uses the selected local date at noon")
        }

        let oldCall = CalendarEventOpenRequest(startDate: originalStart, externalIdentifier: "", calendarIdentifier: "")
        check(oldCall.displayDate == originalStart, "omitting the selected date keeps the original start-date behavior")
        for invalidDate in [SolarDate(year: 2026, month: 2, day: 30), SolarDate(year: 2026, month: 0, day: 1)] {
            let invalidRequest = CalendarEventOpenRequest(startDate: originalStart, selectedDate: invalidDate,
                                                          externalIdentifier: "", calendarIdentifier: "", timeZone: shanghai)
            check(invalidRequest.displayDate == originalStart, "invalid selected date safely falls back to the event start")
        }

        check(CalendarEventOpenResult.event.message == nil, "precise event success has no failure message")
        check(CalendarEventOpenResult.date.message?.contains("所选日期") == true,
              "date-only success explicitly identifies the selected-date fallback")
        check(CalendarEventOpenResult.application(automationDenied: true).message?.contains("自动化") == true,
              "denied Automation explains the permission needed for navigation")
        check(CalendarEventOpenResult.application(automationDenied: false).message?.isEmpty == false,
              "application-only success has a partial-success message")
        check(CalendarEventOpenResult.failed.message?.isEmpty == false, "failure provides a user-visible message")

        let opener = CalendarEventOpener { _ in
            check(Thread.isMainThread, "Calendar script executor runs on the main thread")
            return .date
        }
        var openReturned = false
        let deferredResult: CalendarEventOpenResult = await withCheckedContinuation { continuation in
            opener.open(request) { result in
                check(openReturned, "script execution is deferred until the click handler returns")
                continuation.resume(returning: result)
            }
            openReturned = true
        }
        check(deferredResult == .date, "deferred script result is reported unchanged")
    }
}
