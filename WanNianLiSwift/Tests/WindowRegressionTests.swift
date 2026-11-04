import AppKit
import Foundation
import LunarCore

private final class WindowTestCalendarEventSource: CalendarEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [AgendaEvent] = []

    func setEvents(_ events: [AgendaEvent]) {
        lock.lock()
        storedEvents = events
        lock.unlock()
    }

    func fetch(in interval: DateInterval, completion: @escaping @Sendable (CalendarReadResult) -> Void) {
        lock.lock()
        let events = storedEvents
        lock.unlock()
        completion(CalendarReadResult(authorization: .authorized, events: events))
    }

    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) { completion(false) }
    func invalidate() {}
}

@MainActor
final class WindowTestDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var preferences: UserDefaults?
    private var suiteName: String?
    private let eventSource = WindowTestCalendarEventSource()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = DataStore(supportDirectory: directory)
        let suiteName = "WanNianLiRegression-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        self.suiteName = suiteName
        self.preferences = preferences
        testMenuBarPreferences(preferences)
        testBrowsingDatePersistence(store: store, preferences: preferences)

        let model = CalendarViewModel(store: store, preferences: preferences)
        model.setYear(2024)
        model.setMonth(1)
        model.select(CalendarDay(date: SolarDate(year: 2024, month: 1, day: 31), data: store.data))
        guard model.moveMonth(by: 1),
              model.selected == SolarDate(year: 2024, month: 2, day: 29),
              model.detailDay.date == model.selected else {
            FileHandle.standardError.write(Data("month navigation left agenda on a different date\n".utf8))
            exit(1)
        }
        model.showToday()
        guard model.selected == nil, model.detailDay.date == model.today else {
            FileHandle.standardError.write(Data("return to today did not reset selection\n".utf8))
            exit(1)
        }
        print("ok   month navigation keeps the agenda date in the visible month")
        let calendarStore = SystemCalendarStore(source: eventSource,
                                               authorizationProvider: { .authorized },
                                               observeChanges: false)
        controller = StatusItemController(store: store, preferences: preferences, calendarStore: calendarStore)
        controller?.testSetCalendarSize(.standard)
        controller?.testSelectDate(SolarDate(year: 2026, month: 10, day: 2))
        controller?.testOpenPinnedCalendar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let panel = controller?.testPinnedWindow,
                  panel.isVisible,
                  let visible = panel.screen?.visibleFrame,
                  visible.contains(panel.frame),
                  let content = panel.contentViewController?.view else {
                FileHandle.standardError.write(Data("pinned calendar window did not appear within the screen\n".utf8))
                exit(1)
            }
            let standardSize = content.bounds.size
            print("ok   pinned calendar window is visible within the screen")
            controller?.testSetCalendarSize(.small)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                guard checkPinnedWindowSize(.small, relativeTo: standardSize) else {
                    FileHandle.standardError.write(Data("pinned calendar did not resize to small mode\n".utf8))
                    exit(1)
                }
                print("ok   pinned calendar resizes to small mode")
                controller?.testSetCalendarSize(.large)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                    guard checkPinnedWindowSize(.large, relativeTo: standardSize) else {
                        FileHandle.standardError.write(Data("pinned calendar did not resize to large mode\n".utf8))
                        exit(1)
                    }
                    print("ok   pinned calendar resizes to large mode")
                    controller?.testSetCalendarSize(.standard)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                        guard let panel = controller?.testPinnedWindow,
                              let content = panel.contentViewController?.view else {
                            FileHandle.standardError.write(Data("pinned calendar content view is missing\n".utf8))
                            exit(1)
                        }
                        let ordinaryDayHeight = content.bounds.height
                        controller?.testSelectDate(SolarDate(year: 2026, month: 10, day: 1))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                            guard let panel = controller?.testPinnedWindow,
                                  let content = panel.contentViewController?.view,
                                  content.bounds.height > ordinaryDayHeight + 4,
                                  pinnedPanelMatchesContentAndScreen(panel) else {
                                FileHandle.standardError.write(Data("pinned window did not grow for festival details\n".utf8))
                                exit(1)
                            }
                            print("ok   pinned window grows for festival details")
                            controller?.testSelectDate(SolarDate(year: 2026, month: 10, day: 2))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                                guard let panel = controller?.testPinnedWindow,
                                      let content = panel.contentViewController?.view else {
                                    FileHandle.standardError.write(Data("pinned calendar content view is missing\n".utf8))
                                    exit(1)
                                }
                                let noEventsHeight = content.bounds.height
                                controller?.testPlacePinnedWindowAtBottomEdge()
                                guard let visible = panel.screen?.visibleFrame,
                                      abs(panel.frame.minY - visible.minY) <= 1 else {
                                    FileHandle.standardError.write(Data("pinned window could not be placed at the bottom screen edge\n".utf8))
                                    exit(1)
                                }
                                eventSource.setEvents((9...12).map { hour in
                                    let start = Calendar.localGregorian.date(from: DateComponents(
                                        year: 2026, month: 10, day: 2, hour: hour))!
                                    return AgendaEvent(id: "window-event-\(hour)", title: "日程 \(hour)",
                                                       startDate: start,
                                                       endDate: Calendar.localGregorian.date(byAdding: .minute, value: 30, to: start)!,
                                                       isAllDay: false)
                                })
                                controller?.testRefreshCalendarEvents()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                                    guard let panel = controller?.testPinnedWindow,
                                          let content = panel.contentViewController?.view,
                                          content.bounds.height > noEventsHeight + 8,
                                          pinnedPanelMatchesContentAndScreen(panel) else {
                                        FileHandle.standardError.write(Data("pinned window did not resize for event changes\n".utf8))
                                        exit(1)
                                    }
                                    print("ok   pinned window resizes when event data changes")
                                    controller?.testOpenCustomEventsFromPinnedCalendar()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                                        guard let pinned = controller?.testPinnedWindow,
                                              pinned.isVisible,
                                              controller?.testIsPinned == true,
                                              let custom = controller?.testCustomEventsWindow,
                                              custom.isVisible,
                                              custom.occlusionState.contains(.visible),
                                              NSApp.orderedWindows.first === custom,
                                              NSApp.keyWindow !== controller?.testPinnedWindow else {
                                            let pinnedVisible = controller?.testPinnedWindow?.isVisible ?? false
                                            let isPinned = controller?.testIsPinned ?? false
                                            let customVisible = controller?.testCustomEventsWindow?.isVisible ?? false
                                            let keyTitle = NSApp.keyWindow?.title ?? "<none>"
                                            let frontTitle = NSApp.orderedWindows.first?.title ?? "<none>"
                                            FileHandle.standardError.write(Data("opening custom dates failed: pinnedVisible=\(pinnedVisible), isPinned=\(isPinned), customVisible=\(customVisible), keyWindow=\(keyTitle), frontWindow=\(frontTitle), appActive=\(NSApp.isActive)\n".utf8))
                                            exit(1)
                                        }
                                        print("ok   custom dates opens above and preserves the pinned calendar")
                                        custom.performClose(nil)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                                            guard let pinned = controller?.testPinnedWindow,
                                                  pinned.isVisible,
                                                  controller?.testIsPinned == true else {
                                                FileHandle.standardError.write(Data("closing custom dates closed the pinned calendar\n".utf8))
                                                exit(1)
                                            }
                                            guard controller?.testUpdateWindowTakesFocusAbovePinnedCalendar() == true,
                                                  controller?.testPinnedWindow?.isVisible == true else {
                                                FileHandle.standardError.write(Data("update holidays window did not take focus above the pinned calendar\n".utf8))
                                                exit(1)
                                            }
                                            print("ok   update holidays window takes focus above the pinned calendar")
                                            controller?.testTogglePinnedCalendar()
                                            guard controller?.testPinnedWindow == nil, controller?.testIsPinned == false else {
                                                FileHandle.standardError.write(Data("unpinning did not close the calendar window\n".utf8))
                                                exit(1)
                                            }
                                            print("ok   unpinning closes the calendar window")
                                            testCustomEventsWindowAppears()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func checkPinnedWindowSize(_ size: CalendarSize, relativeTo standard: NSSize) -> Bool {
        guard let panel = controller?.testPinnedWindow,
              let content = panel.contentViewController?.view,
              let visible = panel.screen?.visibleFrame else { return false }
        let expectedWidth = standard.width * size.scale
        let expectedHeight = standard.height * size.scale
        let actual = content.bounds.size
        let panelContent = panel.contentRect(forFrameRect: panel.frame).size
        let sizeMatches = abs(actual.width - expectedWidth) <= 3
            && abs(actual.height - expectedHeight) <= 4
            && abs(panelContent.width - actual.width) <= 1
            && abs(panelContent.height - actual.height) <= 1
        return sizeMatches && visible.contains(panel.frame)
    }

    private func pinnedPanelMatchesContentAndScreen(_ panel: NSPanel) -> Bool {
        guard let content = panel.contentViewController?.view,
              let visible = panel.screen?.visibleFrame else { return false }
        let panelContent = panel.contentRect(forFrameRect: panel.frame).size
        return abs(panelContent.width - content.bounds.width) <= 1
            && abs(panelContent.height - content.bounds.height) <= 1
            && visible.contains(panel.frame)
    }

    private func testCustomEventsWindowAppears() {
        controller?.testOpenCustomEventsFromCalendar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let window = NSApp.windows.first(where: { $0.title == "自定义日期" && $0.isVisible }),
                  let visible = window.screen?.visibleFrame else {
                FileHandle.standardError.write(Data("custom dates window did not appear\n".utf8))
                exit(1)
            }
            guard visible.contains(window.frame) else {
                FileHandle.standardError.write(Data("custom dates window is outside the visible screen\n".utf8))
                exit(1)
            }
            guard window.occlusionState.contains(.visible) else {
                FileHandle.standardError.write(Data("custom dates window: visible=\(window.occlusionState.contains(.visible))\n".utf8))
                exit(1)
            }
            print("ok   custom dates window is visible within the screen")
            try? FileManager.default.removeItem(at: directory)
            if let preferences, let suiteName { preferences.removePersistentDomain(forName: suiteName) }
            NSApp.terminate(nil)
        }
    }

    private func testMenuBarPreferences(_ preferences: UserDefaults) {
        let menu = AppMenu(preferences: preferences)
        menu.menuBarDateStyle = .custom
        menu.updateCustomMenuBarFormat {
            $0.showsIcon = true
            $0.showsDate = false
            $0.showsWeekday = true
        }
        let day = CalendarDay(date: SolarDate(year: 2026, month: 10, day: 28), data: CalendarData())
        let presentation = menu.menuBarPresentation(for: day)
        guard presentation.showsIcon, presentation.title == "周三" else {
            FileHandle.standardError.write(Data("custom menu bar format did not render selected components\n".utf8))
            exit(1)
        }
        menu.updateCustomMenuBarFormat {
            $0.showsIcon = false
            $0.showsWeekday = false
        }
        guard menu.customMenuBarFormat.hasContent else {
            FileHandle.standardError.write(Data("custom menu bar format allowed an empty result\n".utf8))
            exit(1)
        }
        let restored = AppMenu(preferences: preferences)
        guard restored.menuBarDateStyle == .custom,
              restored.customMenuBarFormat == menu.customMenuBarFormat else {
            FileHandle.standardError.write(Data("custom menu bar format did not persist\n".utf8))
            exit(1)
        }
        print("ok   custom menu bar format validates and persists")
    }

    private func testBrowsingDatePersistence(store: DataStore, preferences: UserDefaults) {
        let model = CalendarViewModel(store: store, preferences: preferences)
        model.setRememberBrowsingDate(true)
        model.setYear(2024)
        model.setMonth(1)
        model.select(CalendarDay(date: SolarDate(year: 2024, month: 1, day: 31), data: store.data))

        let restored = CalendarViewModel(store: store, preferences: preferences)
        guard restored.year == 2024, restored.month == 1,
              restored.selected == SolarDate(year: 2024, month: 1, day: 31) else {
            FileHandle.standardError.write(Data("remember browsing date did not restore after restart\n".utf8))
            exit(1)
        }
        print("ok   remembered browsing date restores after restart")

        let nextMonthToday = SolarDate(year: 2026, month: 11, day: 1)
        preferences.set(true, forKey: "rememberBrowsingDate")
        preferences.set(2026, forKey: "browsingCalendarYear")
        preferences.set(10, forKey: "browsingCalendarMonth")
        preferences.set(0, forKey: "browsingCalendarDay")
        let afterMonthBoundary = CalendarViewModel(store: store, preferences: preferences, today: nextMonthToday)
        guard afterMonthBoundary.year == nextMonthToday.year,
              afterMonthBoundary.month == nextMonthToday.month,
              afterMonthBoundary.selected == nil,
              preferences.integer(forKey: "browsingCalendarYear") == nextMonthToday.year,
              preferences.integer(forKey: "browsingCalendarMonth") == nextMonthToday.month else {
            FileHandle.standardError.write(Data("unselected browsing date did not follow today across a month boundary\n".utf8))
            exit(1)
        }
        print("ok   unselected remembered date follows today across a month boundary")

        preferences.set(1800, forKey: "browsingCalendarYear")
        let invalid = CalendarViewModel(store: store, preferences: preferences)
        guard invalid.year == invalid.today.year, invalid.month == invalid.today.month,
              invalid.selected == nil else {
            FileHandle.standardError.write(Data("invalid remembered date did not fall back to today\n".utf8))
            exit(1)
        }
        print("ok   invalid remembered date falls back to today")

        invalid.setRememberBrowsingDate(false)
        let notRemembered = CalendarViewModel(store: store, preferences: preferences)
        guard notRemembered.year == notRemembered.today.year,
              notRemembered.month == notRemembered.today.month,
              notRemembered.selected == nil else {
            FileHandle.standardError.write(Data("disabled date memory restored a previous selection\n".utf8))
            exit(1)
        }
        print("ok   disabled date memory does not restore a previous selection")
    }
}

@main
struct WindowRegressionTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = WindowTestDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
