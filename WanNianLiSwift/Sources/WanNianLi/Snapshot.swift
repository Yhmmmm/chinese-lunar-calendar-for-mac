import AppKit
import LunarCore
import SwiftUI

/// 开发用：`WanNianLi --snapshot <目录> [yyyyMMdd]` 把日历界面和菜单栏图标渲染成 PNG，便于检查界面
@MainActor
enum Snapshot {
    static func run(arguments: [String]) {
        guard let path = arguments.first, !path.hasPrefix("-") else {
            FileHandle.standardError.write(Data("usage: WanNianLi --snapshot <目录> [yyyyMMdd] [-calendarSize small|standard|large]\n".utf8))
            exit(1)
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WanNianLiSnapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let preferencesName = "com.zfdang.WanNianLiSwift.snapshot.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: preferencesName)!
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let store = DataStore(supportDirectory: dataDir, defaults: preferences)
        try? store.upsert(CustomEvent(name: "示例纪念日", rule: .solar(month: 10, day: 28)))
        let model = CalendarViewModel(store: store, preferences: preferences)
        let size = arguments.firstIndex(of: "-calendarSize").flatMap { index in
            arguments.indices.contains(index + 1) ? CalendarSize(rawValue: arguments[index + 1]) : nil
        } ?? .standard
        let menu = AppMenu(preferences: preferences, store: store)
        menu.calendarSize = size
        let calendarStore = SystemCalendarStore()
        if arguments.count > 1, let key = Int(arguments[1]) {
            model.setYear(key / 10000)
            model.setMonth(key / 100 % 100)
            model.select(CalendarDay(date: SolarDate(year: key / 10000, month: key / 100 % 100, day: key % 100),
                                     data: store.data))
        }
        let previewDay = model.detailDay.date
        let previewStart = Calendar.localGregorian.date(from: DateComponents(
            year: previewDay.year, month: previewDay.month, day: previewDay.day, hour: 17))!
        let previewEnd = Calendar.localGregorian.date(byAdding: .hour, value: 1, to: previewStart)!
        let previewEvents = [
            AgendaEvent(id: "snapshot-all-day", title: "示例：全天事项",
                        startDate: previewStart, endDate: previewEnd, isAllDay: true),
            AgendaEvent(id: "snapshot-timed", title: "示例：项目讨论",
                        startDate: previewStart, endDate: previewEnd, isAllDay: false),
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: CalendarView(model: model, menu: menu,
                                                             calendarStore: calendarStore, loadSystemCalendar: false,
                                                             previewEvents: previewEvents)
                .background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: appearance)
            view.frame.size = view.fittingSize
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = appearance == .aqua ? .white : NSColor(white: 0.16, alpha: 1)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            save(view, to: dir.appendingPathComponent("calendar-\(name).png"))
            let list = NSHostingView(rootView: CalendarView(model: model, menu: menu,
                                                             calendarStore: calendarStore, loadSystemCalendar: false).upcomingList)
            list.appearance = NSAppearance(named: appearance)
            list.frame.size = list.fittingSize
            let listWindow = NSWindow(contentRect: list.frame, styleMask: .borderless, backing: .buffered, defer: false)
            listWindow.appearance = NSAppearance(named: appearance)
            listWindow.contentView = list
            list.layoutSubtreeIfNeeded()
            save(list, to: dir.appendingPathComponent("upcoming-\(name).png"))
        }
        // 自定义日期窗口（选中第一项），浅色和深色各一张
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            let events = NSHostingView(rootView: CustomEventsView(store: store,
                                                                  selection: store.customEvents.first?.id))
            events.appearance = NSAppearance(named: appearance)
            events.frame.size = NSSize(width: 680, height: 440)
            let window = NSWindow(contentRect: events.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = events
            events.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            save(events, to: dir.appendingPathComponent("custom-events\(suffix).png"))
        }

        let icon = NSImageView(image: MenuBarIcon.image(day: SolarDate.today.day))
        icon.frame = NSRect(x: 0, y: 0, width: 20, height: 18)
        save(icon, to: dir.appendingPathComponent("icon.png"))
    }

    private static func save(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("saved \(url.path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
}
