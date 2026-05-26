import AppKit
import EventKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var calendarManager: CalendarManager!
    var overlayWindowController: OverlayWindowController?
    var pollTimer: Timer?
    var calendarsMenu: NSMenu!
    // Track which events we've already shown alerts for
    var alertedEventIDs: Set<String> = []

    // Alert window: fire if meeting starts within this many seconds OR
    // has started within this many seconds (for sleep/wake catch-up)
    let alertLeadSeconds: TimeInterval = 60
    let alertGraceSeconds: TimeInterval = 120 // widened from 30s

    // Log file
    lazy var logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MeetingBuzzer.log")
    }()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("MeetingBuzzer launched")

        // Create menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "MeetingBuzzer")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Next Meeting: checking...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Test Alert", action: #selector(testAlert), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())

        let calendarsItem = NSMenuItem(title: "Calendars", action: nil, keyEquivalent: "")
        calendarsMenu = NSMenu(title: "Calendars")
        calendarsMenu.addItem(NSMenuItem(title: "Waiting for access…", action: nil, keyEquivalent: ""))
        calendarsItem.submenu = calendarsMenu
        menu.addItem(calendarsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit MeetingBuzzer", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        calendarManager = CalendarManager()
        calendarManager.requestAccess { [weak self] granted in
            if granted {
                DispatchQueue.main.async {
                    self?.log("Calendar access granted")
                    self?.rebuildCalendarsMenu()
                    self?.startPolling()
                    self?.registerSystemNotifications()
                }
            } else {
                DispatchQueue.main.async {
                    self?.log("Calendar access DENIED")
                    self?.statusItem.menu?.items.first?.title = "⚠️ Calendar access denied"
                }
            }
        }
    }

    func registerSystemNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        // Wake from sleep — re-check immediately
        nc.addObserver(self,
                       selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification,
                       object: nil)

        // Session became active (user unlocked / returned)
        nc.addObserver(self,
                       selector: #selector(systemDidWake),
                       name: NSWorkspace.sessionDidBecomeActiveNotification,
                       object: nil)

        // Screen unlocked — some systems use this
        nc.addObserver(self,
                       selector: #selector(systemDidWake),
                       name: NSWorkspace.screensDidWakeNotification,
                       object: nil)

        // Also watch for calendar changes (new events, edits)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(calendarChanged),
                                               name: .EKEventStoreChanged,
                                               object: calendarManager.eventStore)

        log("System notifications registered (wake/unlock/calendar)")
    }

    @objc func systemDidWake() {
        log("System woke / became active — re-checking calendar")
        // Delay briefly to let calendar sync after wake
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkUpcomingMeetings()
        }
    }

    @objc func calendarChanged() {
        log("Calendar store changed — re-checking")
        rebuildCalendarsMenu()
        checkUpcomingMeetings()
    }

    // MARK: - Calendars submenu

    func rebuildCalendarsMenu() {
        calendarsMenu.removeAllItems()

        let all = calendarManager.allCalendars()
        if all.isEmpty {
            calendarsMenu.addItem(NSMenuItem(title: "No calendars available", action: nil, keyEquivalent: ""))
            return
        }

        let enableAll = NSMenuItem(title: "Enable All", action: #selector(enableAllCalendars), keyEquivalent: "")
        enableAll.target = self
        calendarsMenu.addItem(enableAll)
        calendarsMenu.addItem(NSMenuItem.separator())

        // Group by source (iCloud, Google account, etc.)
        let grouped = Dictionary(grouping: all, by: { $0.source.title })
        let sources = grouped.keys.sorted()

        for (idx, source) in sources.enumerated() {
            if idx > 0 { calendarsMenu.addItem(NSMenuItem.separator()) }
            let header = NSMenuItem(title: source, action: nil, keyEquivalent: "")
            header.isEnabled = false
            calendarsMenu.addItem(header)

            let cals = grouped[source]!.sorted { $0.title < $1.title }
            for cal in cals {
                let item = NSMenuItem(title: cal.title,
                                      action: #selector(toggleCalendar(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = cal.calendarIdentifier
                item.state = calendarManager.isEnabled(cal) ? .on : .off
                calendarsMenu.addItem(item)
            }
        }

        calendarsMenu.addItem(NSMenuItem.separator())
        let note = NSMenuItem(title: "(events you're invited to always alert)",
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        calendarsMenu.addItem(note)
    }

    @objc func toggleCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let cal = calendarManager.allCalendars().first(where: { $0.calendarIdentifier == id })
        else { return }
        let newState = !calendarManager.isEnabled(cal)
        calendarManager.setEnabled(cal, enabled: newState)
        sender.state = newState ? .on : .off
        log("Calendar '\(cal.title)' \(newState ? "enabled" : "disabled")")
        alertedEventIDs.removeAll()
        checkUpcomingMeetings()
    }

    @objc func enableAllCalendars() {
        calendarManager.enableAllCalendars()
        log("All calendars enabled")
        rebuildCalendarsMenu()
        alertedEventIDs.removeAll()
        checkUpcomingMeetings()
    }

    func startPolling() {
        // Check every 10 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkUpcomingMeetings()
        }
        pollTimer?.tolerance = 2
        // Also check immediately
        checkUpcomingMeetings()
    }

    func checkUpcomingMeetings() {
        guard let event = calendarManager.nextUpcomingEvent() else {
            updateMenuTitle("No upcoming meetings")
            return
        }

        let now = Date()
        let timeUntil = event.startDate.timeIntervalSince(now)
        let minutesUntil = Int(ceil(timeUntil / 60))

        if minutesUntil > 5 {
            updateMenuTitle("Next: \(event.title ?? "Meeting") in \(minutesUntil)m")
        } else if minutesUntil > 0 {
            updateMenuTitle("⚡ \(event.title ?? "Meeting") in \(minutesUntil)m!")
        } else {
            updateMenuTitle("🔴 \(event.title ?? "Meeting") NOW")
        }

        // Fire if starting within alertLeadSeconds OR up to alertGraceSeconds past start
        let eventID = event.eventIdentifier ?? UUID().uuidString
        if timeUntil <= alertLeadSeconds
            && timeUntil > -alertGraceSeconds
            && !alertedEventIDs.contains(eventID) {
            alertedEventIDs.insert(eventID)
            log("Firing overlay for '\(event.title ?? "?")' (timeUntil=\(Int(timeUntil))s)")
            showOverlay(for: event)
        }

        // Clean up old event IDs (keep set small)
        if alertedEventIDs.count > 50 {
            alertedEventIDs.removeAll()
        }
    }

    func updateMenuTitle(_ title: String) {
        DispatchQueue.main.async {
            self.statusItem.menu?.items.first?.title = title
        }
    }

    func showOverlay(for event: EKEvent) {
        DispatchQueue.main.async {
            // Dismiss any existing overlay
            self.overlayWindowController?.close()

            let videoLink = self.calendarManager.extractVideoLink(from: event)
            let controller = OverlayWindowController(event: event, videoLink: videoLink) {
                // Just nil out the reference — close() already handled the windows
                self.overlayWindowController = nil
            }
            self.overlayWindowController = controller
            controller.showWindow(nil)
        }
    }

    @objc func testAlert() {
        log("Test alert triggered manually")
        if let event = calendarManager.nextUpcomingEvent() {
            showOverlay(for: event)
        } else {
            // No real event — create a dummy preview
            let dummy = EKEvent(eventStore: calendarManager.eventStore)
            dummy.title = "Test Meeting"
            dummy.startDate = Date().addingTimeInterval(30)
            dummy.endDate = Date().addingTimeInterval(30 * 60)
            showOverlay(for: dummy)
        }
    }

    @objc func openLog() {
        NSWorkspace.shared.open(logURL)
    }

    @objc func quit() {
        log("MeetingBuzzer quitting")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Logging

    func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        print(line, terminator: "")

        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}

