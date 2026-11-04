import AppKit
import LunarCore
import ServiceManagement
import SwiftUI

/// 外观：跟随系统 / 日间模式 / 夜间模式
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "日间模式"
        case .dark: return "夜间模式"
        }
    }

    private static let key = "appearance"
    static let didChange = Notification.Name("WanNianLiAppearanceDidChange")

    static var saved: AppearanceMode {
        UserDefaults.standard.string(forKey: key).flatMap(AppearanceMode.init) ?? .system
    }

    @MainActor
    func apply() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

enum MenuBarDateStyle: String, CaseIterable, Identifiable {
    case icon
    case text
    case iconAndText
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: return "日历图标"
        case .text: return "月日和星期"
        case .iconAndText: return "图标和日期"
        case .custom: return "自定义"
        }
    }

    private static let key = "menuBarDateStyle"

    static var saved: MenuBarDateStyle {
        UserDefaults.standard.string(forKey: key).flatMap(MenuBarDateStyle.init) ?? .icon
    }
}

struct CustomMenuBarFormat: Equatable {
    var showsIcon: Bool
    var showsDate: Bool
    var showsWeekday: Bool

    static let standard = CustomMenuBarFormat(showsIcon: false, showsDate: true, showsWeekday: true)

    var hasContent: Bool { showsIcon || showsDate || showsWeekday }

    func title(for day: CalendarDay) -> String {
        [showsDate ? "\(day.date.month)月\(day.date.day)日" : nil,
         showsWeekday ? day.weekdayName.replacingOccurrences(of: "星期", with: "周") : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

struct MenuBarPresentation {
    let showsIcon: Bool
    let title: String
}

enum CalendarSize: String, CaseIterable, Identifiable {
    case small
    case standard
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "小"
        case .standard: return "标准"
        case .large: return "大"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .standard: return 1.0
        case .large: return 1.2
        }
    }

    private static let key = "calendarSize"

    static var saved: CalendarSize {
        UserDefaults.standard.string(forKey: key).flatMap(CalendarSize.init) ?? .standard
    }
}

/// 日历左下角的设置菜单
@MainActor
final class AppMenu: ObservableObject {
    static let helpURL = URL(string: "https://github.com/Yhmmmm/chinese-lunar-calendar-for-mac/blob/master/WanNianLiSwift/README.md")!
    static let changelogURL = URL(string: "https://github.com/Yhmmmm/chinese-lunar-calendar-for-mac/blob/master/CHANGELOG.md")!
    static let contactURL = URL(string: "https://github.com/Yhmmmm/chinese-lunar-calendar-for-mac/issues")!
    static let festivalSourcesURL = URL(string: "https://github.com/Yhmmmm/chinese-lunar-calendar-for-mac/blob/master/WanNianLiSwift/Data/FESTIVALS.md")!
    static let originalProjectURL = URL(string: "https://github.com/zfdang/chinese-lunar-calendar-for-mac")!

    /// 选择"更新假日信息"时调用
    var onUpdateHolidays: () -> Void = {}
    /// 选择"自定义日期"时调用
    var onEditCustomEvents: () -> Void = {}
    var onTogglePinned: () -> Void = {}

    @Published private(set) var launchAtLogin: Bool
    @Published var appearance: AppearanceMode {
        didSet { appearance.apply() }
    }
    @Published var menuBarDateStyle: MenuBarDateStyle {
        didSet { preferences.set(menuBarDateStyle.rawValue, forKey: "menuBarDateStyle") }
    }
    @Published var calendarSize: CalendarSize {
        didSet { preferences.set(calendarSize.rawValue, forKey: "calendarSize") }
    }
    @Published var customMenuBarFormat: CustomMenuBarFormat {
        didSet {
            preferences.set(customMenuBarFormat.showsIcon, forKey: "customMenuBarShowsIcon")
            preferences.set(customMenuBarFormat.showsDate, forKey: "customMenuBarShowsDate")
            preferences.set(customMenuBarFormat.showsWeekday, forKey: "customMenuBarShowsWeekday")
        }
    }
    @Published var rememberBrowsingDate: Bool {
        didSet { preferences.set(rememberBrowsingDate, forKey: "rememberBrowsingDate") }
    }
    @Published private(set) var isPinned = false

    private let preferences: UserDefaults
    private let dataStore: DataStore

    init(preferences: UserDefaults = .standard, store: DataStore? = nil) {
        self.preferences = preferences
        dataStore = store ?? .shared
        launchAtLogin = Self.isLoginItemEnabled
        appearance = .saved
        menuBarDateStyle = preferences.string(forKey: "menuBarDateStyle")
            .flatMap(MenuBarDateStyle.init) ?? .icon
        calendarSize = preferences.string(forKey: "calendarSize")
            .flatMap(CalendarSize.init) ?? .standard
        let savedFormat = CustomMenuBarFormat(
            showsIcon: preferences.object(forKey: "customMenuBarShowsIcon") as? Bool ?? false,
            showsDate: preferences.object(forKey: "customMenuBarShowsDate") as? Bool ?? true,
            showsWeekday: preferences.object(forKey: "customMenuBarShowsWeekday") as? Bool ?? true
        )
        customMenuBarFormat = savedFormat.hasContent ? savedFormat : .standard
        rememberBrowsingDate = preferences.bool(forKey: "rememberBrowsingDate")
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
    }

    func updateCustomMenuBarFormat(_ update: (inout CustomMenuBarFormat) -> Void) {
        var next = customMenuBarFormat
        update(&next)
        guard next.hasContent else { return }
        customMenuBarFormat = next
    }

    func menuBarPresentation(for day: CalendarDay) -> MenuBarPresentation {
        let dateAndWeekday = "\(day.date.month)月\(day.date.day)日 \(day.weekdayName.replacingOccurrences(of: "星期", with: "周"))"
        switch menuBarDateStyle {
        case .icon: return MenuBarPresentation(showsIcon: true, title: "")
        case .text: return MenuBarPresentation(showsIcon: false, title: dateAndWeekday)
        case .iconAndText: return MenuBarPresentation(showsIcon: true, title: dateAndWeekday)
        case .custom:
            return MenuBarPresentation(showsIcon: customMenuBarFormat.showsIcon,
                                      title: customMenuBarFormat.title(for: day))
        }
    }

    var menuBarPreview: String {
        let day = CalendarDay(date: .today, data: dataStore.data)
        let presentation = menuBarPresentation(for: day)
        let icon = presentation.showsIcon ? "[日历] " : ""
        return icon + (presentation.title.isEmpty ? "" : presentation.title)
    }

    /// 已注册为登录项（包括等待用户在系统设置中批准的情况）
    private static var isLoginItemEnabled: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func refresh() {
        launchAtLogin = Self.isLoginItemEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            if SMAppService.mainApp.status == .requiresApproval {
                // 需要用户在"系统设置 > 通用 > 登录项"中允许
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = enabled ? "无法设置自动启动" : "无法取消自动启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }

    var button: some View {
        AppMenuButton(menu: self, store: dataStore)
    }
}

private struct AppMenuButton: View {
    @ObservedObject var menu: AppMenu
    @ObservedObject var store: DataStore

    var body: some View {
        Menu {
            Toggle("自动启动", isOn: Binding(get: { menu.launchAtLogin }, set: { menu.setLaunchAtLogin($0) }))
            Picker("外观", selection: $menu.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("菜单栏日期", selection: $menu.menuBarDateStyle) {
                ForEach(MenuBarDateStyle.allCases) { Text($0.title).tag($0) }
            }
            if menu.menuBarDateStyle == .custom {
                Menu("自定义格式") {
                    Toggle("日历图标", isOn: Binding(
                        get: { menu.customMenuBarFormat.showsIcon },
                        set: { value in menu.updateCustomMenuBarFormat { $0.showsIcon = value } }))
                    Toggle("月日", isOn: Binding(
                        get: { menu.customMenuBarFormat.showsDate },
                        set: { value in menu.updateCustomMenuBarFormat { $0.showsDate = value } }))
                    Toggle("星期", isOn: Binding(
                        get: { menu.customMenuBarFormat.showsWeekday },
                        set: { value in menu.updateCustomMenuBarFormat { $0.showsWeekday = value } }))
                    Divider()
                    Text("预览：\(menu.menuBarPreview)")
                        .disabled(true)
                }
            }
            Picker("月历大小", selection: $menu.calendarSize) {
                ForEach(CalendarSize.allCases) { Text($0.title).tag($0) }
            }
            Toggle("记住上次查看日期", isOn: $menu.rememberBrowsingDate)
            Menu("显示节日") {
                ForEach(FestivalCategory.allCases) { category in
                    Toggle(category.title, isOn: Binding(
                        get: { !store.hiddenCategories.contains(category) },
                        set: { store.setCategory(category, visible: $0) }))
                }
                Divider()
                Menu("国外公共假日") {
                    Menu("英国") {
                        ForEach(FestivalCalendar.allCases.filter(\.isBritish)) { calendar in
                            calendarToggle(calendar)
                        }
                    }
                    ForEach(FestivalCalendar.allCases.filter { !$0.isBritish }) { calendar in
                        calendarToggle(calendar)
                    }
                }
                Button("节日来源与收录范围…") { NSWorkspace.shared.open(AppMenu.festivalSourcesURL) }
            }
            Button("自定义日期…") { menu.onEditCustomEvents() }
            Divider()
            Button("使用帮助") { NSWorkspace.shared.open(AppMenu.helpURL) }
            Button("更新假日信息…") { menu.onUpdateHolidays() }
            Divider()
            Button("版本: \(AppMenu.version)") { NSWorkspace.shared.open(AppMenu.changelogURL) }
            Button("定制版反馈") { NSWorkspace.shared.open(AppMenu.contactURL) }
            Button("原项目 © zfdang") { NSWorkspace.shared.open(AppMenu.originalProjectURL) }
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("设置")
        .onAppear { menu.refresh() }
    }

    private func calendarToggle(_ calendar: FestivalCalendar) -> some View {
        Toggle(calendar.title, isOn: Binding(
            get: { store.selectedCalendars.contains(calendar) },
            set: { store.setCalendar(calendar, visible: $0) }))
    }
}
