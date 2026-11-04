import AppKit
import Combine
import LunarCore
import SwiftUI

/// 菜单栏图标及日历弹出窗口
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var pinnedWindow: NSPanel?
    private let store: DataStore
    private let model: CalendarViewModel
    private let menu: AppMenu
    private let calendarStore: SystemCalendarStore
    private let loadSystemCalendar: Bool

    private var shownDay: SolarDate?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var updateWindow: UpdateHolidaysWindowController?
    private var customEventsWindow: CustomEventsWindowController?
#if DEBUG
    private var testUpdateWindowControllerForFocus: NSWindowController?
#endif
    private var lastClosed = Date.distantPast
    private var dataObserver: AnyCancellable?
    private var styleObserver: AnyCancellable?
    private var formatObserver: AnyCancellable?
    private var rememberObserver: AnyCancellable?
    private var sizeObserver: AnyCancellable?
    private var modelContentObserver: AnyCancellable?
    private var calendarContentObserver: AnyCancellable?
    private var resizeScheduled = false
    private var constrainingPinnedWindow = false

    override convenience init() { self.init(store: .shared) }

    init(store: DataStore, loadSystemCalendar: Bool = true, preferences: UserDefaults = .standard,
         calendarStore: SystemCalendarStore? = nil) {
        self.store = store
        self.loadSystemCalendar = loadSystemCalendar
        menu = AppMenu(preferences: preferences, store: store)
        model = CalendarViewModel(store: store, preferences: preferences)
        self.calendarStore = calendarStore ?? SystemCalendarStore()
        super.init()

        // 记住用户按住 Command 键拖动后的图标位置
        statusItem.autosaveName = "WanNianLiSwift"

        menu.onUpdateHolidays = { [weak self] in self?.showUpdateWindow() }
        menu.onEditCustomEvents = { [weak self] in self?.showCustomEventsWindow() }
        menu.onTogglePinned = { [weak self] in self?.togglePinnedCalendar() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        popover.contentViewController = makeCalendarHostingController()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        refreshIcon()
        styleObserver = menu.$menuBarDateStyle.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMenuBarIcon() }
        }
        formatObserver = menu.$customMenuBarFormat.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMenuBarIcon() }
        }
        rememberObserver = menu.$rememberBrowsingDate.dropFirst().sink { [weak self] enabled in
            Task { @MainActor [weak self] in self?.model.setRememberBrowsingDate(enabled) }
        }
        sizeObserver = menu.$calendarSize.dropFirst().sink { [weak self] _ in
            self?.schedulePinnedWindowResize()
        }
        modelContentObserver = model.objectWillChange.sink { [weak self] _ in
            self?.schedulePinnedWindowResize()
        }
        calendarContentObserver = self.calendarStore.objectWillChange.sink { [weak self] _ in
            self?.schedulePinnedWindowResize()
        }
        // 节日设置、假日信息变化时，更新图标的提示文字
        dataObserver = store.$data.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.shownDay = nil
                self?.refreshIcon()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAppearance),
                                               name: AppearanceMode.didChange, object: nil)
        // 每 5 秒检查一次日期是否变化
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }
    }

    private func refreshIcon() {
        let today = SolarDate.today
        guard let button = statusItem.button else { return }
        if today != shownDay {
            shownDay = today
            model.refreshToday()
        }
        let day = CalendarDay(date: today, data: store.data)
        let presentation = menu.menuBarPresentation(for: day)
        statusItem.length = presentation.title.isEmpty && presentation.showsIcon
            ? NSStatusItem.squareLength : NSStatusItem.variableLength
        button.image = presentation.showsIcon ? MenuBarIcon.image(day: today.day) : nil
        button.title = presentation.title
        button.toolTip = "\(day.solarText) \(day.weekdayName)\n\(day.lunarText)"
    }

    private func refreshMenuBarIcon() {
        shownDay = nil
        refreshIcon()
    }

    private func makeCalendarHostingController() -> NSHostingController<CalendarView> {
        let hosting = NSHostingController(rootView: CalendarView(model: model, menu: menu,
                                                                  calendarStore: calendarStore,
                                                                  loadSystemCalendar: loadSystemCalendar))
        hosting.sizingOptions = .preferredContentSize
        return hosting
    }

    // MARK: - 弹出窗口

    @objc private func togglePopover() {
        if menu.isPinned {
            pinnedWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 弹出窗口打开时点击图标：transient 行为会先关闭窗口，这里不要再立即打开
        if Date().timeIntervalSince(lastClosed) < 0.3 { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(resetDate: true)
        }
    }

    private func showPopover(resetDate: Bool) {
        guard let button = statusItem.button else { return }
        if resetDate && !menu.rememberBrowsingDate { model.showToday() }
        refreshIcon()

        updateAppearance()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        if let window = popover.contentViewController?.view.window { installKeyMonitor(for: window) }
    }

    // 应用激活是异步的，弹出窗口显示时可能还没激活，这里再次让它成为键盘焦点窗口，
    // 否则方向键、回车无法控制日历
    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.makeKey()
        if let window = popover.contentViewController?.view.window { installKeyMonitor(for: window) }
        installOpaqueBackground()
    }

    /// 弹出窗口默认跟随菜单栏按钮的外观，而不是 NSApp.appearance，这里显式设置
    @objc private func updateAppearance() {
        popover.appearance = NSApp.appearance ?? NSApp.effectiveAppearance
        pinnedWindow?.appearance = NSApp.appearance ?? NSApp.effectiveAppearance
        popover.contentViewController?.view.window?.contentView?.superview?.subviews
            .filter { $0 is PopoverBackgroundView }
            .forEach { $0.needsDisplay = true }
    }

    /// 把弹出窗口箭头部分的半透明材质也换成不透明背景。
    /// 依赖 NSPopover 内部的视图层级（contentView.superview），如果系统改变了层级，
    /// 只有箭头会恢复为半透明，内容区域的背景由 CalendarView 自己绘制，不受影响
    private func installOpaqueBackground() {
        guard let frameView = popover.contentViewController?.view.window?.contentView?.superview,
              !frameView.subviews.contains(where: { $0 is PopoverBackgroundView }) else { return }
        let background = PopoverBackgroundView(frame: frameView.bounds)
        background.autoresizingMask = [.width, .height]
        frameView.addSubview(background, positioned: .below, relativeTo: nil)
    }

    @objc private func applicationDidBecomeActive() {
        if let customWindow = customEventsWindow?.window, customWindow.isVisible {
            scheduleWindowFocus(customWindow)
        } else if let updateWindow = visibleUpdateWindow {
            scheduleWindowFocus(updateWindow)
        } else if menu.isPinned, pinnedWindow?.isVisible == true {
            if let pinnedWindow { scheduleWindowFocus(pinnedWindow) }
        } else if popover.isShown {
            if let window = popover.contentViewController?.view.window { scheduleWindowFocus(window) }
        }
    }

    private func scheduleWindowFocus(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private var visibleUpdateWindow: NSWindow? {
#if DEBUG
        if let window = testUpdateWindowControllerForFocus?.window, window.isVisible {
            return window
        }
#endif
        guard let window = updateWindow?.window, window.isVisible else { return nil }
        return window
    }

    func popoverDidClose(_ notification: Notification) {
        lastClosed = Date()
        statusItem.button?.highlight(false)
        removeKeyMonitor()
    }

    private func installKeyMonitor(for window: NSWindow) {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, window.isVisible, event.window === window else { return event }
            if window.firstResponder is NSControl || window.firstResponder is NSTextView { return event }
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func togglePinnedCalendar() {
        if menu.isPinned {
            menu.setPinned(false)
            closePinnedWindow()
            showPopover(resetDate: false)
            return
        }
        menu.setPinned(true)
        if popover.isShown { popover.performClose(nil) }
        showPinnedWindow()
    }

    private func showPinnedWindow() {
        let panel: NSPanel
        if let existing = pinnedWindow {
            panel = existing
        } else {
            let hosting = makeCalendarHostingController()
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 273, height: 426),
                            styleMask: [.titled, .closable, .miniaturizable],
                            backing: .buffered, defer: false)
            panel.title = "万年历"
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.delegate = self
            panel.setFrameAutosaveName("WanNianLiPinnedCalendar")
            panel.contentViewController = hosting
            hosting.view.layoutSubtreeIfNeeded()
            panel.setContentSize(hosting.view.fittingSize)
            panel.center()
            pinnedWindow = panel
        }
        panel.appearance = NSApp.appearance ?? NSApp.effectiveAppearance
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor(for: panel)
    }

    private func resizePinnedWindow() {
        guard let panel = pinnedWindow,
              let hosting = panel.contentViewController as? NSHostingController<CalendarView> else { return }
        hosting.view.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.view.fittingSize)
        constrainPinnedWindowToScreen(panel)
    }

    private func schedulePinnedWindowResize() {
        guard pinnedWindow != nil, !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizePinnedWindow()
        }
    }

    private func constrainPinnedWindowToScreen(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let maxX = max(visible.minX, visible.maxX - frame.width)
        let maxY = max(visible.minY, visible.maxY - frame.height)
        panel.setFrameOrigin(NSPoint(x: min(max(frame.minX, visible.minX), maxX),
                                     y: min(max(frame.minY, visible.minY), maxY)))
    }

    private func closePinnedWindow() {
        guard let panel = pinnedWindow else { return }
        pinnedWindow = nil
        panel.delegate = nil
        panel.close()
        removeKeyMonitor()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === pinnedWindow else { return }
        pinnedWindow = nil
        menu.setPinned(false)
        removeKeyMonitor()
    }

    func windowDidResize(_ notification: Notification) {
        guard !constrainingPinnedWindow,
              let window = notification.object as? NSPanel,
              window === pinnedWindow else { return }
        constrainingPinnedWindow = true
        constrainPinnedWindowToScreen(window)
        constrainingPinnedWindow = false
    }

    /// 键盘控制：← 上一年，→ 下一年，↑ 上一月，↓ 下一月，↵ 回到今天
    private func handleKey(_ event: NSEvent) -> Bool {
        let moved: Bool
        switch event.keyCode {
        case 123: moved = model.moveYear(by: -1)
        case 124: moved = model.moveYear(by: 1)
        case 126: moved = model.moveMonth(by: -1)
        case 125: moved = model.moveMonth(by: 1)
        case 36, 76: model.showToday(); moved = true
        default: return false
        }
        if !moved { NSSound.beep() }
        return true
    }

    // MARK: - 自定义日期

    private func showCustomEventsWindow() {
        if popover.isShown { popover.performClose(nil) }
        if !menu.isPinned { closePinnedWindow() }
        if customEventsWindow == nil {
            customEventsWindow = CustomEventsWindowController(store: store) { [weak self] in
                self?.customEventsWindow = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        customEventsWindow?.showWindow(nil)
        if let window = customEventsWindow?.window { scheduleWindowFocus(window) }
    }

    #if DEBUG
    func testOpenCustomEventsFromCalendar() {
        showPopover(resetDate: true)
        menu.onEditCustomEvents()
    }

    func testOpenPinnedCalendar() {
        menu.setPinned(true)
        showPinnedWindow()
    }

    func testOpenCustomEventsFromPinnedCalendar() {
        if !menu.isPinned {
            menu.setPinned(true)
            showPinnedWindow()
        }
        showCustomEventsWindow()
    }

    func testTogglePinnedCalendar() { togglePinnedCalendar() }

    func testSetCalendarSize(_ size: CalendarSize) { menu.calendarSize = size }

    var testCustomEventsWindow: NSWindow? { customEventsWindow?.window }

    func testSelectDate(_ date: SolarDate) {
        model.select(CalendarDay(date: date, data: store.data))
    }

    func testRefreshCalendarEvents() { calendarStore.refresh() }

    func testPlacePinnedWindowAtBottomEdge() {
        guard let panel = pinnedWindow,
              let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: screen.visibleFrame.minY))
    }

    func testUpdateWindowTakesFocusAbovePinnedCalendar() -> Bool {
        pinnedWindow?.makeKey()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "更新假日信息"
        window.isReleasedWhenClosed = false
        let windowController = NSWindowController(window: window)
        testUpdateWindowControllerForFocus = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        applicationDidBecomeActive()
        let didTakeFocus = window.isVisible
            && NSApp.orderedWindows.first === window
            && NSApp.keyWindow !== pinnedWindow
        windowController.close()
        DispatchQueue.main.async { [weak self, windowController] in
            self?.testUpdateWindowControllerForFocus = nil
            _ = windowController.window
        }
        return didTakeFocus
    }

    var testPinnedWindow: NSPanel? { pinnedWindow }

    var testIsPinned: Bool { menu.isPinned }
    #endif

    // MARK: - 更新假日信息

    private func showUpdateWindow() {
        if popover.isShown { popover.performClose(nil) }
        if !menu.isPinned { closePinnedWindow() }
        if updateWindow == nil {
            updateWindow = UpdateHolidaysWindowController(store: store) { [weak self] in
                self?.updateWindow = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        updateWindow?.showWindow(nil)
        if let window = updateWindow?.window { scheduleWindowFocus(window) }
    }
}


/// 弹出窗口的不透明背景
private final class PopoverBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.nsBackground.setFill()
        bounds.fill()
    }
}
