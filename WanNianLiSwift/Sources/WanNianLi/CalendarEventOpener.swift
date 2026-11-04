import AppKit
import Carbon
import LunarCore

/// 反映实际完成的定位层级，不把“打开应用”误报为已选中事件。
enum CalendarEventOpenResult: Equatable, Sendable {
    case event
    case date
    case application(automationDenied: Bool)
    case failed

    var message: String? {
        switch self {
        case .event:
            return nil
        case .date:
            return "已打开所选日期，未能选中具体日程。"
        case .application(let automationDenied):
            return automationDenied
                ? "已打开系统日历。请在系统设置的“隐私与安全性 → 自动化”中允许万年历控制日历，以定位事件。"
                : "已打开系统日历，未能定位到所选日期。"
        case .failed:
            return "无法打开系统日历，请稍后重试。"
        }
    }
}

/// 只在用户点击事件后调用。日历读取权限与这里的 Automation 权限相互独立。
@MainActor
final class CalendarEventOpener {
    static let shared = CalendarEventOpener()
    private static let calendarBundleIdentifier = "com.apple.iCal"
    private let executeScript: @MainActor (CalendarEventOpenRequest) -> CalendarEventScriptResult
    private var isOpening = false

    init() {
        self.executeScript = { CalendarEventScript.execute($0) }
    }

    init(executeScript: @escaping @MainActor (CalendarEventOpenRequest) -> CalendarEventScriptResult) {
        self.executeScript = executeScript
    }

    func open(_ event: AgendaEvent, completion: @escaping @MainActor (CalendarEventOpenResult) -> Void) {
        open(CalendarEventOpenRequest(startDate: event.startDate,
                                      externalIdentifier: event.externalIdentifier ?? "",
                                      calendarIdentifier: event.calendarIdentifier ?? ""), completion: completion)
    }

    func open(_ event: AgendaEvent, selectedDate: SolarDate,
              completion: @escaping @MainActor (CalendarEventOpenResult) -> Void) {
        open(CalendarEventOpenRequest(startDate: event.startDate, selectedDate: selectedDate,
                                      externalIdentifier: event.externalIdentifier ?? "",
                                      calendarIdentifier: event.calendarIdentifier ?? ""), completion: completion)
    }

    func open(_ request: CalendarEventOpenRequest,
              completion: @escaping @MainActor (CalendarEventOpenResult) -> Void) {
        guard !isOpening else {
            completion(.failed)
            return
        }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.calendarBundleIdentifier) else {
            completion(.failed)
            return
        }
        isOpening = true

        // Defer the synchronous scripting call until after the SwiftUI click handler returns.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            let result = self.executeScript(request)
            switch result {
            case .event:
                self.isOpening = false
                completion(.event)
            case .date:
                self.isOpening = false
                completion(.date)
            case .failed(let automationDenied):
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
                    let opened = application != nil && error == nil
                    Task { @MainActor in
                        self.isOpening = false
                        completion(opened ? .application(automationDenied: automationDenied) : .failed)
                    }
                }
            }
        }
    }
}

/// 请求不包含标题或备注，也不会把真实事件内容写入日志。
struct CalendarEventOpenRequest: Sendable {
    let displayDate: Date
    let startDate: Date
    let externalIdentifier: String
    let calendarIdentifier: String

    init(startDate: Date, selectedDate: SolarDate? = nil, externalIdentifier: String,
         calendarIdentifier: String, timeZone: TimeZone = .current) {
        self.startDate = startDate
        self.externalIdentifier = externalIdentifier
        self.calendarIdentifier = calendarIdentifier
        // 中午代表用户选择的本地日期，避免夏令时午夜切换影响日期定位。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let selectedDate,
           (1...9999).contains(selectedDate.year), (1...12).contains(selectedDate.month),
           (1...SolarDate.daysInMonth(year: selectedDate.year, month: selectedDate.month)).contains(selectedDate.day),
           let date = calendar.date(from: DateComponents(year: selectedDate.year, month: selectedDate.month,
                                                         day: selectedDate.day, hour: 12)),
           calendar.component(.year, from: date) == selectedDate.year,
           calendar.component(.month, from: date) == selectedDate.month,
           calendar.component(.day, from: date) == selectedDate.day {
            displayDate = date
        } else {
            displayDate = startDate
        }
    }
}

enum CalendarEventScriptResult: Equatable, Sendable {
    case event
    case date
    case failed(automationDenied: Bool)
}

/// 动态参数通过 Apple Event descriptor 传递，不参与脚本源文本拼接。
enum CalendarEventScript {
    static let source = """
    on openCalendarEvent(displayDate, occurrenceDate, requestedUID, requestedCalendarID)
        tell application id "com.apple.iCal"
            with timeout of 10 seconds
                activate
                view calendar at displayDate
                if requestedUID is "" or requestedCalendarID is "" then return "date"
                try
                    set matchingCalendars to every calendar whose calendarIdentifier is requestedCalendarID
                    if (count matchingCalendars) is not 1 then return "date"
                    set targetCalendar to item 1 of matchingCalendars
                    set matchingEvents to every event of targetCalendar whose uid is requestedUID
                    repeat with candidate in matchingEvents
                        -- 重复系列可能只返回主事件；起始日期不一致时保留用户所选日。
                        if (start date of candidate) is occurrenceDate then
                            show candidate
                            return "event"
                        end if
                    end repeat
                on error
                    return "date"
                end try
                return "date"
            end timeout
        end tell
    end openCalendarEvent
    """

    static func invocation(for request: CalendarEventOpenRequest) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                           eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "opencalendarevent"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(date: request.displayDate), at: 1)
        arguments.insert(NSAppleEventDescriptor(date: request.startDate), at: 2)
        arguments.insert(NSAppleEventDescriptor(string: request.externalIdentifier), at: 3)
        arguments.insert(NSAppleEventDescriptor(string: request.calendarIdentifier), at: 4)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    @MainActor
    static func execute(_ request: CalendarEventOpenRequest) -> CalendarEventScriptResult {
        guard let script = NSAppleScript(source: source) else { return .failed(automationDenied: false) }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { return failure(from: error) }
        let response = script.executeAppleEvent(invocation(for: request), error: &error)
        if error != nil { return failure(from: error) }
        switch response.stringValue {
        case "event": return .event
        case "date": return .date
        default: return .failed(automationDenied: false)
        }
    }

    private static func failure(from error: NSDictionary?) -> CalendarEventScriptResult {
        let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        return .failed(automationDenied: code == Int(errAEEventNotPermitted))
    }
}
