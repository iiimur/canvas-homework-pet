import AppKit
import Combine
import CoreGraphics
import SwiftUI
import UserNotifications

private let appTitle = "课程作业桌宠"
private let defaultCanvasURL = "https://oc.sjtu.edu.cn"
private let legacyDefaultTokenPath = "\(NSHomeDirectory())/Desktop/访问许可证.txt"

struct Homework: Identifiable, Codable, Hashable {
    var id: String
    var courseID: Int
    var course: String
    var title: String
    var dueAt: String?
    var htmlURL: String?
    var description: String
    var submitted: Bool

    var dueDate: Date? {
        guard let dueAt else { return nil }
        return ISO8601DateFormatter.canvas.date(from: dueAt)
            ?? ISO8601DateFormatter.canvasWithoutFractions.date(from: dueAt)
    }

    var status: String {
        if submitted { return "已交" }
        guard let dueDate else { return "待完成" }
        return dueDate < Date() ? "已逾期" : "待完成"
    }

    /// 未交且剩余提交时间不足 3 小时（含已逾期）时为 true，桌宠据此切换成疲惫贴图。
    var isImminent: Bool {
        guard !submitted, let dueDate else { return false }
        return dueDate.timeIntervalSinceNow < 3 * 3600
    }

    var dueLabel: String {
        guard let dueDate else { return "未设截止时间" }
        return dueDate.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }

    var countdown: String {
        guard let dueDate else { return "还没设截止时间" }
        let seconds = Int(dueDate.timeIntervalSinceNow)
        if seconds < 0 { return "已经逾期 \(duration(-seconds))" }
        if seconds < 3600 { return "还剩 \(max(1, seconds / 60)) 分钟" }
        if seconds < 86400 { return "还剩 \(duration(seconds))" }
        let days = seconds / 86400
        return "还剩 \(days) 天 \((seconds % 86400) / 3600) 小时"
    }

    private func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(max(1, minutes)) 分钟"
    }
}

private extension ISO8601DateFormatter {
    static let canvas: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let canvasWithoutFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

@MainActor
final class AssignmentStore: ObservableObject {
    @Published var assignments: [Homework] = []
    @Published var isLoading = false
    @Published var message = "正在找今天的作业…"
    @Published var lastUpdated: Date?
    @Published var canvasURL: String
    @Published var tokenPath: String
    /// 每分钟递增，驱动倒计时和"已逾期"状态刷新。
    @Published private(set) var clockTick = 0

    private let folder: URL
    private let cacheURL: URL
    private let settingsURL: URL
    private var refreshTask: Task<Void, Never>?
    private var autoSyncTimer: Timer?
    private var clockTimer: Timer?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appTitle, isDirectory: true)
        folder = support
        cacheURL = support.appendingPathComponent("assignments.json")
        settingsURL = support.appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let settings = (try? Data(contentsOf: settingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        canvasURL = settings["canvasURL"] ?? defaultCanvasURL
        let fileManager = FileManager.default
        let supportTokenURL = support.appendingPathComponent("访问许可证.txt")
        let configuredTokenPath = settings["tokenPath"]
        let expandedConfiguredPath = configuredTokenPath.map {
            NSString(string: $0).expandingTildeInPath
        }
        let shouldMigrateDefaultToken = configuredTokenPath == nil
            || expandedConfiguredPath == legacyDefaultTokenPath
        var shouldSaveMigratedTokenPath = false

        if shouldMigrateDefaultToken {
            if fileManager.fileExists(atPath: supportTokenURL.path) {
                tokenPath = supportTokenURL.path
                shouldSaveMigratedTokenPath = true
                if fileManager.contentsEqual(
                    atPath: legacyDefaultTokenPath,
                    andPath: supportTokenURL.path
                ) {
                    try? fileManager.removeItem(atPath: legacyDefaultTokenPath)
                }
            } else if fileManager.fileExists(atPath: legacyDefaultTokenPath) {
                do {
                    try fileManager.moveItem(
                        at: URL(fileURLWithPath: legacyDefaultTokenPath),
                        to: supportTokenURL
                    )
                    try? fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: supportTokenURL.path
                    )
                    tokenPath = supportTokenURL.path
                    shouldSaveMigratedTokenPath = true
                } catch {
                    tokenPath = configuredTokenPath ?? legacyDefaultTokenPath
                }
            } else {
                tokenPath = supportTokenURL.path
                shouldSaveMigratedTokenPath = true
            }
        } else {
            tokenPath = configuredTokenPath!
        }
        if shouldSaveMigratedTokenPath {
            saveSettings()
        }
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([Homework].self, from: data) {
            assignments = cached.sorted(by: Self.sortByDue)
            message = "显示上次同步的作业"
        }
        startTimers()
    }

    private func startTimers() {
        // 作业按天变化，倒计时显示由 clockTick 每分钟本地刷新，不需要更勤的同步。
        let sync = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(sync, forMode: .common)
        autoSyncTimer = sync
        let tick = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.clockTick += 1 }
        }
        RunLoop.main.add(tick, forMode: .common)
        clockTimer = tick
    }

    var openAssignments: [Homework] {
        assignments.filter { !$0.submitted }.sorted(by: Self.sortByDue)
    }

    var nearest: Homework? {
        openAssignments.first
    }

    func saveSettings() {
        let settings = ["canvasURL": canvasURL, "tokenPath": tokenPath]
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    func refresh() {
        guard !isLoading else { return }
        refreshTask?.cancel()
        refreshTask = Task { await loadAssignments() }
    }

    private func loadAssignments() async {
        isLoading = true
        message = "爱音去 Canvas 看一眼…"
        defer { isLoading = false }
        do {
            let expandedTokenPath = NSString(string: tokenPath).expandingTildeInPath
            let tokenURL = URL(fileURLWithPath: expandedTokenPath)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw SyncError.emptyToken }
            let base = canvasURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard var components = URLComponents(string: base + "/api/v1/courses") else { throw SyncError.badURL }
            components.queryItems = [
                URLQueryItem(name: "enrollment_state", value: "active"),
                URLQueryItem(name: "per_page", value: "100"),
            ]
            guard let coursesURL = components.url else { throw SyncError.badURL }
            let courses = try await Self.getPages(startingAt: coursesURL, token: token)
            var fetched: [Homework] = []
            // 最多同时请求 4 门课的作业列表，缩短整体同步时间。
            try await withThrowingTaskGroup(of: [Homework].self) { group in
                var inFlight = 0
                for course in courses {
                    guard let id = course["id"] as? Int, let name = course["name"] as? String else { continue }
                    if inFlight == 4, let rows = try await group.next() {
                        fetched.append(contentsOf: rows)
                        inFlight -= 1
                    }
                    group.addTask { try await Self.fetchAssignments(base: base, courseID: id, course: name, token: token) }
                    inFlight += 1
                }
                for try await rows in group {
                    fetched.append(contentsOf: rows)
                }
            }
            assignments = fetched.sorted(by: Self.sortByDue)
            lastUpdated = Date()
            message = "刚刚同步 · \(openAssignments.count) 项待完成"
            if let data = try? JSONEncoder().encode(assignments) {
                try? data.write(to: cacheURL, options: .atomic)
            }
            await scheduleNotifications(for: openAssignments)
        } catch is CancellationError {
            return
        } catch {
            message = "同步没成功，先显示上次的作业"
            if assignments.isEmpty { message = error.localizedDescription }
        }
    }

    private static func fetchAssignments(base: String, courseID: Int, course: String, token: String) async throws -> [Homework] {
        var components = URLComponents(string: "\(base)/api/v1/courses/\(courseID)/assignments")
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "include[]", value: "submission"),
        ]
        guard let url = components?.url else { return [] }
        var rows: [Homework] = []
        for raw in try await getPages(startingAt: url, token: token) {
            guard let assignmentID = raw["id"] else { continue }
            let submission = raw["submission"] as? [String: Any] ?? [:]
            let workflow = submission["workflow_state"] as? String ?? ""
            let submitted = submission["submitted_at"] as? String != nil || workflow == "submitted" || workflow == "graded"
            let html = raw["description"] as? String ?? ""
            rows.append(Homework(
                id: String(describing: assignmentID),
                courseID: courseID,
                course: course,
                title: raw["name"] as? String ?? "未命名作业",
                dueAt: raw["due_at"] as? String,
                htmlURL: raw["html_url"] as? String,
                description: Self.plainText(html),
                submitted: submitted
            ))
        }
        return rows
    }

    private static func getPages(startingAt initialURL: URL, token: String) async throws -> [[String: Any]] {
        var next: URL? = initialURL
        var rows: [[String: Any]] = []
        while let url = next {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.badResponse }
            if http.statusCode == 401 || http.statusCode == 403 { throw SyncError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw SyncError.server(http.statusCode) }
            if let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                rows.append(contentsOf: list)
            }
            next = Self.nextPage(in: http)
        }
        return rows
    }

    private static func nextPage(in response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") {
            let value = String(part)
            if value.contains("rel=\"next\"") || value.contains("rel=next"),
               let left = value.firstIndex(of: "<"), let right = value.firstIndex(of: ">") {
                return URL(string: String(value[value.index(after: left)..<right]))
            }
        }
        return nil
    }

    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "(?is)<(script|style)[^>]*>.*?</\\1>",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</li>|</h[1-6]>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive) }
        return text
            .components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func sortByDue(_ lhs: Homework, _ rhs: Homework) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?): return left < right
        case (_?, nil): return true
        default: return false
        }
    }

    private static func reminderLabel(_ minutes: Int) -> String {
        switch minutes {
        case 1440: return "明天截止"
        case 180: return "3 小时后截止"
        default: return "\(minutes) 分钟后截止"
        }
    }

    private func scheduleNotifications(for tasks: [Homework]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let pending = await center.pendingNotificationRequests()
        let oldIDs = pending.map(\.identifier).filter { $0.hasPrefix("course-homework-") }
        center.removePendingNotificationRequests(withIdentifiers: oldIDs)
        for task in tasks {
            guard let due = task.dueDate else { continue }
            for minutes in [1440, 180, 30] {
                let fireDate = due.addingTimeInterval(TimeInterval(-minutes * 60))
                let interval = fireDate.timeIntervalSinceNow
                guard interval > 60 else { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(task.course) · 作业提醒"
                content.body = "\(task.title) · \(Self.reminderLabel(minutes))"
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                let request = UNNotificationRequest(
                    identifier: "course-homework-\(task.id)-\(minutes)",
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }
    }
}

private enum SyncError: LocalizedError {
    case emptyToken, badURL, badResponse, unauthorized, server(Int)
    var errorDescription: String? {
        switch self {
        case .emptyToken: return "Canvas 许可证文件为空。"
        case .badURL: return "Canvas 地址无效，请检查设置。"
        case .badResponse: return "Canvas 返回了无法识别的数据。"
        case .unauthorized: return "Canvas 认证失败，请检查本地许可证。"
        case .server(let status): return "Canvas 返回 HTTP \(status)。"
        }
    }
}

private struct AppPetAnchor: Codable {
    var appName: String
    var distanceFromRight: Double
    var distanceFromTop: Double
}

@MainActor
final class PetPanelController: NSObject, NSApplicationDelegate {
    /// 无边框桌宠不需要系统默认的"窗口不得越过菜单栏"约束，否则头像无法贴到屏幕顶端。
    final class FreeMovingPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    private var panel: NSPanel!
    private let store = AssignmentStore()
    private var isExpanded = false
    /// 展开状态下用户拖动过窗格：本次展开期间暂停自动回位，收起后复位。
    private var isExpandedManuallyMoved = false
    private var outsideClickMonitor: Any?
    private var isFollowingApp = false
    private var restingOrigin: NSPoint?
    private var compactOriginBeforeExpand: NSPoint?
    private var positionTimer: Timer?
    private var lastAppBundleID: String?
    private var lastAppName: String?
    private var lastAppWindowFrame: NSRect?
    private var lastPositionedBundleID: String?
    private var lastPositionedWindowFrame: NSRect?
    private var anchors: [String: AppPetAnchor] = [:]
    private var manuallyMovedBundleIDs = Set<String>()
    private var defaultOrigin = NSPoint.zero
    private var glideTimer: Timer?
    private var glideFrom: NSPoint?
    private var glideTo: NSPoint?
    private var glideStart: Date?
    private var glideDuration: TimeInterval = 0
    private var appTerminationObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var frontmostApplicationObservation: NSKeyValueObservation?
    private var mouseActivityMonitor: Any?
    private let anchorsKey = "appPetAnchors"
    private let avatarCenterInCompactPanel = NSPoint(x: 183, y: 75)
    let ambient = AmbientState()
    private var isFrontAppFullScreen = false
    private var isAutoHidden = false
    private var lastMouseLocation: NSPoint?
    private var lastMouseActivityDate = Date()
    /// 对齐系统光标的全屏自动隐藏：前台全屏且鼠标静止这么久后整个桌宠消失。
    private let fullscreenHideIdleSeconds: TimeInterval = 1

    /// 拖动结束时立刻把当前位置存为该 App 的锚点。若等"切换离开"才存，
    /// 中间任何一次展开/收起清单都会把桌宠弹回旧锚点，刚拖的位置就丢了。
    private func finishManualDrag() {
        ambient.isMoving = false
        guard let bundleID = lastAppBundleID, let frame = lastAppWindowFrame else { return }
        saveAnchor(bundleID: bundleID, appName: lastAppName ?? bundleID, windowFrame: frame)
        restingOrigin = panel.frame.origin
    }

    /// 已经有一只爱音在跑时，激活旧实例并让新进程退出，避免出现两个桌宠。
    /// 必须放在 willFinishLaunching：等到 didFinish 时新 panel 已经建好，退掉就晚了。
    func applicationWillFinishLaunching(_ notification: Notification) {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let bundleID = Bundle.main.bundleIdentifier,
              let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                  .first(where: { $0.processIdentifier != pid }) else { return }
        existing.activate()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        let size = NSSize(width: 236, height: 150)
        panel = FreeMovingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PetView(
            store: store,
            ambient: ambient,
            onExpand: { [weak self] expanded in self?.resize(expanded: expanded) },
            onManualMove: { [weak self] in self?.markCurrentAppPositionAsManuallyMoved() },
            onDragFinished: { [weak self] in self?.finishManualDrag() },
            onExpandedManualMove: { [weak self] in self?.beginExpandedManualMove() },
            onQuit: { NSApp.terminate(nil) }
        ))
        if let data = UserDefaults.standard.data(forKey: anchorsKey),
           let saved = try? JSONDecoder().decode([String: AppPetAnchor].self, from: data) {
            anchors = saved
        }
        placeAtBottomRight(size: size)
        defaultOrigin = panel.frame.origin
        panel.orderFrontRegardless()
        store.refresh()
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.applicationDidTerminate(app) }
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.applicationDidActivate(app) }
        }
        frontmostApplicationObservation = NSWorkspace.shared.observe(
            \.frontmostApplication,
            options: [.new]
        ) { [weak self] _, change in
            guard let app = change.newValue ?? nil else { return }
            Task { @MainActor in self?.applicationDidActivate(app) }
        }
        // 轮询只为捕捉前台应用窗口的移动/缩放；App 切换已有通知驱动，这里 1 秒足够。
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateAppPosition() }
        }
        positionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        // 全屏自动隐藏要像系统光标一样即时恢复，鼠标一动就立刻感知，不等 1 秒轮询。
        mouseActivityMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor in self?.noteMouseActivity() }
        }
        updateAppPosition()
        // 清单展开时，点击面板外的任何位置都收起清单。面板自身的点击属于本地事件，不会进入全局监听。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.outsideClickDetected() }
        }
    }

    /// 展开状态下用户拖动了标题区：本次展开期间不再自动回位，收起清单后恢复原逻辑。
    private func beginExpandedManualMove() {
        guard isExpanded else { return }
        isExpandedManuallyMoved = true
        cancelGlide()
    }

    private func outsideClickDetected() {
        guard isExpanded, !isAutoHidden else { return }
        ambient.requestCollapse()
    }

    private func resize(expanded: Bool) {
        guard isExpanded != expanded else { return }
        cancelGlide()
        isExpanded = expanded
        if !expanded { isExpandedManuallyMoved = false }
        let size = expanded ? NSSize(width: 354, height: 540) : NSSize(width: 236, height: 150)
        if expanded {
            let baseOrigin = isFollowingApp ? (restingOrigin ?? panel.frame.origin) : panel.frame.origin
            compactOriginBeforeExpand = baseOrigin
            panel.setFrame(expandedFrame(fromCompactOrigin: baseOrigin), display: true, animate: true)
        } else {
            var baseOrigin = isFollowingApp ? (restingOrigin ?? compactOriginBeforeExpand ?? panel.frame.origin)
                : (compactOriginBeforeExpand ?? panel.frame.origin)
            // 有锚点时收起直接回到锚点，避免"先回常驻位、下一秒再飞锚点"的两段式移动。
            if isFollowingApp,
               let bundleID = lastAppBundleID,
               let anchor = anchors[bundleID],
               let appFrame = lastAppWindowFrame {
                let center = NSPoint(
                    x: appFrame.maxX - anchor.distanceFromRight,
                    y: appFrame.maxY - anchor.distanceFromTop
                )
                baseOrigin = NSPoint(
                    x: center.x - avatarCenterInCompactPanel.x,
                    y: center.y - avatarCenterInCompactPanel.y
                )
            }
            var frame = NSRect(origin: baseOrigin, size: size)
            frame = clamp(frame, toScreenNear: baseOrigin)
            panel.setFrame(frame, display: true, animate: true)
            compactOriginBeforeExpand = nil
        }
        if isFollowingApp && !expanded {
            lastPositionedBundleID = nil
        }
    }

    private func expandedFrame(fromCompactOrigin origin: NSPoint) -> NSRect {
        let size = NSSize(width: 354, height: 540)
        let compactSize = NSSize(width: 236, height: 150)
        // 保持展开前右上角大致不动，再把整个面板限制在所在屏幕的可见区域。
        let preferred = NSRect(
            x: origin.x + compactSize.width - size.width,
            y: origin.y + compactSize.height - size.height,
            width: size.width,
            height: size.height
        )
        return clamp(preferred, toScreenNear: origin)
    }

    private func clamp(_ frame: NSRect, toScreenNear origin: NSPoint) -> NSRect {
        let reference = NSPoint(x: origin.x + 118, y: origin.y + 75)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(reference) }) ?? NSScreen.main
        // 基准用整块屏幕而非 visibleFrame：桌宠层级低于菜单栏和 Dock，
        // 放进那些区域只是被遮住一部分，不构成必须避开的技术限制。
        let bounds = (screen?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)).insetBy(dx: 8, dy: 8)
        let maxX = max(bounds.minX, bounds.maxX - frame.width)
        let maxY = max(bounds.minY, bounds.maxY - frame.height)
        let x = min(max(frame.minX, bounds.minX), maxX)
        let y = min(max(frame.minY, bounds.minY), maxY)
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private func placeAtBottomRight(size: NSSize) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 32, y: screen.minY + 32))
    }

    /// 把面板滑到目标位置：逐帧插值加缓动，效果类似被手拖过去，而不是闪现。
    private func glide(to target: NSPoint) {
        if let glideTo, hypot(glideTo.x - target.x, glideTo.y - target.y) < 1 { return }
        cancelGlide()
        let from = panel.frame.origin
        let distance = hypot(target.x - from.x, target.y - from.y)
        guard distance > 1 else {
            panel.setFrameOrigin(target)
            return
        }
        glideFrom = from
        glideTo = target
        glideStart = Date()
        // 按距离决定滑行时长（约 450pt/秒），限制在 0.9–2.2 秒，走得从容一点。
        glideDuration = min(2.2, max(0.9, distance / 450))
        ambient.isMoving = true
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.glideStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
        glideStep()
    }

    private func glideStep() {
        guard let from = glideFrom, let to = glideTo, let start = glideStart, glideDuration > 0 else {
            cancelGlide()
            return
        }
        let progress = min(1, Date().timeIntervalSince(start) / glideDuration)
        let t = Self.easeInOutCubic(progress)
        panel.setFrameOrigin(NSPoint(
            x: from.x + (to.x - from.x) * CGFloat(t),
            y: from.y + (to.y - from.y) * CGFloat(t)
        ))
        if progress >= 1 {
            cancelGlide()
            glideFrom = nil
            glideTo = nil
            glideStart = nil
        }
    }

    private func cancelGlide() {
        glideTimer?.invalidate()
        glideTimer = nil
        if ambient.isMoving { ambient.isMoving = false }
    }

    /// "easeOutExpo" 标准曲线，同 CSS cubic-bezier(0.16, 1, 0.3, 1)：
    /// 起步一瞬加速、中段速度饱满、末段是清晰可见的刹车减速。
    private static func easeInOutCubic(_ t: Double) -> Double {
        cubicBezierEase(t, x1: 0.16, y1: 1, x2: 0.3, y2: 1)
    }

    /// 三次贝塞尔缓动求解：牛顿迭代把进度 x 反解成曲线参数 u，再取对应的 y。
    private static func cubicBezierEase(_ x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        guard x > 0, x < 1 else { return x }
        var u = x
        for _ in 0..<8 {
            let bx = bezierValue(u, p0: 0, p1: x1, p2: x2, p3: 1)
            if abs(bx - x) < 1e-5 { break }
            let dx = bezierDerivative(u, p0: 0, p1: x1, p2: x2, p3: 1)
            if abs(dx) < 1e-6 { break }
            u = min(1, max(0, u - (bx - x) / dx))
        }
        return bezierValue(u, p0: 0, p1: y1, p2: y2, p3: 1)
    }

    private static func bezierValue(_ u: Double, p0: Double, p1: Double, p2: Double, p3: Double) -> Double {
        let v = 1 - u
        return v * v * v * p0 + 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u * p3
    }

    private static func bezierDerivative(_ u: Double, p0: Double, p1: Double, p2: Double, p3: Double) -> Double {
        3 * (1 - u) * (1 - u) * (p1 - p0) + 6 * (1 - u) * u * (p2 - p1) + 3 * u * u * (p3 - p2)
    }

    private func updateAppPosition(for activatedApp: NSRunningApplication? = nil) {
        noteMouseActivity()
        guard let app = activatedApp ?? NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            setFrontAppFullScreen(false)
            restoreRestingPositionIfNeeded()
            return
        }
        // 右键桌宠调出菜单时，面板可能短暂成为前台；保留上一个 App 的上下文供“绑定”使用。
        // 但下次该 App 回到前台时必须重新套用锚点，即使 bundle ID 和窗口尺寸没变。
        if bundleID == Bundle.main.bundleIdentifier {
            lastPositionedBundleID = nil
            lastPositionedWindowFrame = nil
            return
        }

        let appChanged = lastAppBundleID != bundleID
        if appChanged {
            saveLastAppAnchorIfNeeded()
            restoreRestingPositionIfNeeded()
            lastPositionedBundleID = nil
            lastPositionedWindowFrame = nil
        }
        lastAppBundleID = bundleID
        lastAppName = app.localizedName ?? bundleID

        // 全屏检测不依赖普通层级的窗口：浏览器的网页全屏、播放器全屏常用高层级窗口。
        let isFullScreen = isAppFullScreen(pid: app.processIdentifier)
        setFrontAppFullScreen(isFullScreen)

        guard let frame = frontWindowFrame(for: app.processIdentifier) else {
            // 全屏播放器场景下可能没有普通层级窗口可锚定；此时桌宠保持原地（随后自动隐藏）。
            if !isFullScreen {
                restoreRestingPositionIfNeeded()
                if appChanged {
                    moveToDefaultPosition()
                    lastPositionedBundleID = bundleID
                }
            }
            lastAppWindowFrame = nil
            return
        }
        lastAppWindowFrame = frame

        guard anchors[bundleID] != nil else {
            restoreRestingPositionIfNeeded()
            // 未记录过的位置使用桌宠的默认停靠点。记下本次应用和窗口，避免定时轮询
            // 把用户在该应用前台时拖动的位置反复弹回去。
            if lastPositionedBundleID != bundleID {
                moveToDefaultPosition()
                lastPositionedBundleID = bundleID
            }
            lastPositionedWindowFrame = frame
            return
        }
        if !isFollowingApp {
            restingOrigin = compactOriginBeforeExpand ?? panel.frame.origin
            isFollowingApp = true
        }

        // 展开作业清单时临时回到常驻位置；收起后按该 App 的存档坐标返回。
        guard !isExpanded else {
            // 用户拖动过展开窗格时，本次展开期间不再拉回。
            if isExpandedManuallyMoved { return }
            if let restingOrigin {
                let target = expandedFrame(fromCompactOrigin: restingOrigin).origin
                if hypot(panel.frame.origin.x - target.x, panel.frame.origin.y - target.y) > 4 {
                    glide(to: target)
                }
            }
            return
        }

        guard let anchor = anchors[bundleID] else { return }
        // 仅在切换 App 或其窗口移动/缩放时自动飞过去；允许用户在该 App 前台时手动微调。
        if lastPositionedBundleID != bundleID || lastPositionedWindowFrame != frame {
            let targetCenter = NSPoint(
                x: frame.maxX - anchor.distanceFromRight,
                y: frame.maxY - anchor.distanceFromTop
            )
            let targetOrigin = NSPoint(
                x: targetCenter.x - avatarCenterInCompactPanel.x,
                y: targetCenter.y - avatarCenterInCompactPanel.y
            )
            let safeTarget = clamp(NSRect(origin: targetOrigin, size: panel.frame.size), toScreenNear: targetOrigin).origin
            if hypot(panel.frame.origin.x - safeTarget.x, panel.frame.origin.y - safeTarget.y) > 4 {
                glide(to: safeTarget)
            }
            lastPositionedBundleID = bundleID
            lastPositionedWindowFrame = frame
        }
    }

    /// 前台 App 只要有任意一个屏幕上的窗口铺满某块显示器，就算全屏。
    /// 需要覆盖两类真实全屏、排除一类形似全屏的普通窗口：
    /// - 原生全屏（绿色按钮 / 播放器）：窗口恰好等于整屏，盖住菜单栏条；
    /// - 网页/客户端视频全屏（B 站实测）：窗口贴着菜单栏下方，但底边一直延伸到
    ///   屏幕最底边（全屏时 Dock 被藏起来，窗口压住 Dock 区域）；
    /// - 平铺/最大化窗口：几何与视频全屏几乎一样，但 Dock 还在，窗口停在 Dock
    ///   上沿、够不到屏幕最底边——靠"是否贴住最底边"排除，避免普通桌面误隐藏。
    private func isAppFullScreen(pid: pid_t) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let slack: CGFloat = 12
        let displays = NSScreen.screens.compactMap { screen -> (CGRect, CGFloat)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let display = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            // 菜单栏高度 = 屏幕顶到可用区域顶的距离（Dock 在底部不影响这个差值）。
            let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
            return (display, menuBar)
        }
        return rows.contains { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return displays.contains { display, menuBar in
                let coversWidth = abs(rect.width - display.width) < slack
                let tallEnough = rect.height >= display.height - menuBar - slack
                let coversMenuBar = rect.minY <= display.minY + 4
                let flushWithBottomEdge = rect.maxY >= display.maxY - 6
                return coversWidth && tallEnough && (coversMenuBar || flushWithBottomEdge)
            }
        }
    }

    /// 由轮询计时器和全局鼠标事件监视器共同调用：鼠标动过就刷新最后活动时间。
    private func noteMouseActivity() {
        let location = NSEvent.mouseLocation
        let moved = lastMouseLocation.map {
            abs(location.x - $0.x) > 0.5 || abs(location.y - $0.y) > 0.5
        } ?? true
        if moved { lastMouseActivityDate = Date() }
        lastMouseLocation = location
        updateAutoHideVisibility()
    }

    private func setFrontAppFullScreen(_ fullScreen: Bool) {
        guard isFrontAppFullScreen != fullScreen else { return }
        isFrontAppFullScreen = fullScreen
        ambient.isFrontAppFullScreen = fullScreen
        updateAutoHideVisibility()
    }

    private func updateAutoHideVisibility() {
        let idle = Date().timeIntervalSince(lastMouseActivityDate)
        setPanelHidden(isFrontAppFullScreen && idle >= fullscreenHideIdleSeconds)
    }

    /// 全屏看视频时像系统光标一样自动隐藏；鼠标一动或退出全屏就淡回来。
    private func setPanelHidden(_ hidden: Bool) {
        // 兜底：任何路径把面板 orderOut 之后状态机又回到可见态时，这里负责把它拉回屏幕。
        if !hidden, !panel.isVisible { panel.orderFrontRegardless() }
        guard isAutoHidden != hidden else { return }
        isAutoHidden = hidden
        if hidden {
            cancelGlide()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // NSAnimationContext 的回调固定在主线程执行。
                MainActor.assumeIsolated {
                    guard let self, self.isAutoHidden else { return }
                    self.panel.orderOut(nil)
                }
            })
        } else {
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func markCurrentAppPositionAsManuallyMoved() {
        // 用户开始手动拖动时立即停掉滑行，避免定时器继续改写面板位置。
        cancelGlide()
        // 拖着走也算"移动中"，头像同样切换成赶路贴图；松手时由 finishManualDrag 复位。
        ambient.isMoving = true
        guard let bundleID = lastAppBundleID else { return }
        manuallyMovedBundleIDs.insert(bundleID)
    }

    private func saveLastAppAnchorIfNeeded() {
        guard let bundleID = lastAppBundleID,
              lastPositionedBundleID == bundleID,
              let frame = lastAppWindowFrame else { return }
        if anchors[bundleID] != nil && !manuallyMovedBundleIDs.contains(bundleID) { return }
        saveAnchor(bundleID: bundleID, appName: lastAppName ?? bundleID, windowFrame: frame)
        manuallyMovedBundleIDs.remove(bundleID)
    }

    private func applicationDidTerminate(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, bundleID == lastAppBundleID else { return }
        saveLastAppAnchorIfNeeded()
        // Safari 网页 App 退出后再启动通常会复用相同 bundle ID 和窗口尺寸。
        // 清除上下文，确保重开时进入新 App 的定位分支。
        lastAppBundleID = nil
        lastAppName = nil
        lastAppWindowFrame = nil
        lastPositionedBundleID = nil
        lastPositionedWindowFrame = nil
    }

    private func applicationDidActivate(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        // 必须在清掉 lastPositionedBundleID 之前把上一个 App 的停留位置存档，
        // 否则切换离开时保存条件（lastPositionedBundleID == 上一个 App）永远不成立，
        // 用户拖好的位置不会被记住，切回来也就无法回位。
        saveLastAppAnchorIfNeeded()
        // 重开同一个 App 时 bundle ID 和窗口尺寸都可能与上次相同，不能用轮询缓存跳过定位。
        lastPositionedBundleID = nil
        lastPositionedWindowFrame = nil
        updateAppPosition(for: app)
    }

    private func moveToDefaultPosition() {
        guard !isExpandedManuallyMoved else { return }
        let target = isExpanded ? expandedFrame(fromCompactOrigin: defaultOrigin).origin : defaultOrigin
        if hypot(panel.frame.origin.x - target.x, panel.frame.origin.y - target.y) > 4 {
            glide(to: target)
        }
    }

    private func saveAnchor(bundleID: String, appName: String, windowFrame: NSRect) {
        let petOrigin = isExpanded
            ? (compactOriginBeforeExpand ?? restingOrigin ?? panel.frame.origin)
            : panel.frame.origin
        let avatarCenter = NSPoint(
            x: petOrigin.x + avatarCenterInCompactPanel.x,
            y: petOrigin.y + avatarCenterInCompactPanel.y
        )
        let updated = AppPetAnchor(
            appName: appName,
            distanceFromRight: Double(windowFrame.maxX - avatarCenter.x),
            distanceFromTop: Double(windowFrame.maxY - avatarCenter.y)
        )
        if let old = anchors[bundleID],
           abs(old.distanceFromRight - updated.distanceFromRight) < 1,
           abs(old.distanceFromTop - updated.distanceFromTop) < 1,
           old.appName == updated.appName { return }
        anchors[bundleID] = updated
        persistAnchors()
    }

    private func persistAnchors() {
        guard let data = try? JSONEncoder().encode(anchors) else { return }
        UserDefaults.standard.set(data, forKey: anchorsKey)
    }

    private func restoreRestingPositionIfNeeded() {
        guard isFollowingApp else { return }
        if let restingOrigin, !isExpandedManuallyMoved {
            let target = isExpanded ? expandedFrame(fromCompactOrigin: restingOrigin).origin : restingOrigin
            glide(to: target)
        }
        restingOrigin = nil
        isFollowingApp = false
        lastPositionedBundleID = nil
        lastPositionedWindowFrame = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveLastAppAnchorIfNeeded()
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        if let mouseActivityMonitor {
            NSEvent.removeMonitor(mouseActivityMonitor)
        }
        frontmostApplicationObservation?.invalidate()
    }

    private func frontWindowFrame(for pid: pid_t) -> NSRect? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let candidate = rows.compactMap { row -> CGRect? in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 300, rect.height > 200 else { return nil }
            return rect
        }.max { $0.width * $0.height < $1.width * $1.height }
        guard let candidate else { return nil }

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard displayBounds.intersects(candidate), displayBounds.width > 0 else { continue }
            let scale = screen.frame.width / displayBounds.width
            let x = screen.frame.minX + (candidate.minX - displayBounds.minX) * scale
            let y = screen.frame.maxY - (candidate.maxY - displayBounds.minY) * scale
            return NSRect(x: x, y: y, width: candidate.width * scale, height: candidate.height * scale)
        }
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension PetPanelController: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@main
struct HomeworkPetApp: App {
    @NSApplicationDelegateAdaptor(PetPanelController.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

struct PetView: View {
    @ObservedObject var store: AssignmentStore
    @ObservedObject var ambient: AmbientState
    let onExpand: (Bool) -> Void
    let onManualMove: () -> Void
    let onDragFinished: () -> Void
    let onExpandedManualMove: () -> Void
    let onQuit: () -> Void
    @State private var expanded = false
    @State private var selectedID: String?
    @State private var showSettings = false
    @StateObject private var bubbleVisibility = IdleBubbleVisibility()

    private let ink = Color(hex: 0x3D3035)
    private let lilac = Color(hex: 0xE28A9D)
    private let cream = Color(hex: 0xFFF8F5)
    private let rose = Color(hex: 0xD66F86)

    var body: some View {
        Group {
            if expanded { expandedPanel } else { compactPet }
        }
        .frame(width: expanded ? 354 : 236, height: expanded ? 540 : 150)
        .background(Color.clear)
        .sheet(isPresented: $showSettings) { settingsSheet }
        .onChange(of: ambient.collapseRequestID) { _, _ in collapsePanel() }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: expanded)
        .onAppear { bubbleVisibility.start() }
    }

    private var compactPet: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle().fill(rose).frame(width: 6, height: 6)
                    Text(store.nearest == nil ? "今天" : "最近要交")
                        .font(.custom("PingFangSC-Semibold", size: 9)).foregroundStyle(rose)
                    Spacer(minLength: 0)
                }
                Text(speechTitle)
                    .font(.custom("PingFangSC-Medium", size: 11)).foregroundStyle(ink).lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill").font(.system(size: 8, weight: .bold))
                    Text(speechSubtitle).font(.custom("PingFangSC-Medium", size: 9)).lineLimit(1)
                }
                .foregroundStyle(store.nearest?.status == "已逾期" ? Color(hex: 0xB4435D) : ink.opacity(0.68))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(width: 130, alignment: .leading)
            .background(cream, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.95), lineWidth: 1.2))
            .overlay(alignment: .trailing) {
                SpeechTail().fill(cream).frame(width: 10, height: 12).offset(x: 5)
            }
            .shadow(color: ink.opacity(0.11), radius: 10, x: 0, y: 5)
            .opacity(bubbleVisibility.isVisible && !ambient.isFrontAppFullScreen ? 1 : 0)
            .scaleEffect(bubbleVisibility.isVisible && !ambient.isFrontAppFullScreen ? 1 : 0.88, anchor: .trailing)
            .allowsHitTesting(bubbleVisibility.isVisible && !ambient.isFrontAppFullScreen)
            .animation(.easeInOut(duration: 0.2), value: bubbleVisibility.isVisible)

            ZStack {
                ReferenceCharacter(isMoving: ambient.isMoving, isExhausted: store.nearest?.isImminent ?? false)
                    .frame(width: 78, height: 104)
                    .scaleEffect(0.8)
                AvatarMoveArea(
                    onTap: { toggleExpanded() },
                    onDragStart: onManualMove,
                    onDragEnd: {
                        bubbleVisibility.revealNow()
                        onDragFinished()
                    },
                    menuEntries: avatarMenuEntries
                )
                .frame(width: 78, height: 104)
            }
            .help("长按头像拖动可移动爱音，点一下展开清单")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
    }

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ReferenceCharacter(isMoving: ambient.isMoving, isExhausted: store.nearest?.isImminent ?? false)
                    .frame(width: 56, height: 62)
                    .overlay {
                        HeaderDragArea(onDragStart: onExpandedManualMove, onTap: { toggleExpanded() })
                    }
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("爱音的作业清单").font(.custom("PingFangSC-Semibold", size: 17)).foregroundStyle(ink)
                        Text(store.message).font(.system(size: 10, design: .rounded)).foregroundStyle(ink.opacity(0.62)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                // 高度固定与头像行一致：既让拖动热区撑满整行、与顶部空白条相接，
                // 又不会像 maxHeight: .infinity 那样把头部行撑开、挤乱下方列表布局。
                .frame(height: 62)
                .overlay { HeaderDragArea(onDragStart: onExpandedManualMove) }
                .help("拖动头部空白可临时挪动清单")
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ink).frame(width: 29, height: 29).background(.white.opacity(0.76), in: Circle())
                }.buttonStyle(.plain).disabled(store.isLoading)
                Button { toggleExpanded() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ink.opacity(0.58)).frame(width: 27, height: 27).background(.white.opacity(0.7), in: Circle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

            HStack(spacing: 8) {
                Label("未交 \(store.openAssignments.count)", systemImage: "list.bullet.circle")
                Spacer()
                Text(listStatus)
            }
            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(ink.opacity(0.62))
            .padding(.horizontal, 17).padding(.bottom, 7)

            if store.openAssignments.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    ReferenceCharacter(isMoving: ambient.isMoving, isExhausted: store.nearest?.isImminent ?? false).frame(width: 100, height: 108)
                    Text(store.assignments.isEmpty ? "还没找到作业" : "太棒啦，作业都交完了！")
                        .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    Text("爱音会继续帮你留意 Canvas。")
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(ink.opacity(0.62))
                }
                Spacer()
            } else {
                if let nearest = store.nearest {
                    dueHeroCard(nearest)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(store.openAssignments.dropFirst().prefix(10))) { homework in
                            homeworkCard(homework)
                        }
                        if store.openAssignments.count > 11 {
                            Text("还有 \(store.openAssignments.count - 11) 项没显示")
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(ink.opacity(0.46))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .overlay {
                    if store.openAssignments.count == 1 && selectedID == nil {
                        Text("目前就这一项，交完就轻松啦")
                            .font(.custom("PingFangSC-Regular", size: 10))
                            .foregroundStyle(ink.opacity(0.46))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 12)
                    }
                }
                if let selected = selectedHomework {
                    detailCard(selected)
                        .padding(.horizontal, 14).padding(.top, 7).padding(.bottom, 11)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill").foregroundStyle(rose)
                Text("截止前一天、3 小时和 30 分钟提醒你")
                    .foregroundStyle(ink.opacity(0.62))
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").foregroundStyle(ink.opacity(0.48))
                }.buttonStyle(.plain)
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.white.opacity(0.5))
        }
        // 标题上方的整条空白也可拖动；高度只覆盖头部内边距，不会碰到刷新/关闭按钮。
        .overlay(alignment: .top) {
            HeaderDragArea(onDragStart: onExpandedManualMove)
                .frame(height: 14)
        }
        .background(
            LinearGradient(colors: [Color(hex: 0xFFFCFA), Color(hex: 0xFFF0F2)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 25, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(.white.opacity(0.95), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        .shadow(color: ink.opacity(0.18), radius: 24, x: 0, y: 12)
        .padding(5)
    }

    private var speechTitle: String {
        guard let next = store.nearest else { return store.assignments.isEmpty ? "我去 Canvas 找找" : "作业都交完啦！" }
        return next.title
    }

    private var speechSubtitle: String {
        guard let next = store.nearest else { return store.assignments.isEmpty ? store.message : "今天可以安心一点啦 ✨" }
        return "\(next.countdown) · \(next.course)"
    }

    private var listStatus: String {
        if store.isLoading { return "正在同步 Canvas" }
        if store.message.contains("失败") { return "显示上次同步" }
        return "按截止时间排序"
    }

    private var selectedHomework: Homework? {
        guard let selectedID else { return nil }
        return store.openAssignments.first(where: { $0.id == selectedID })
    }

    private func dueHeroCard(_ homework: Homework) -> some View {
        let urgent = homework.status == "已逾期"
        let selected = selectedID == homework.id
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedID = selected ? nil : homework.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("最近截止", systemImage: "sparkle")
                        .font(.custom("PingFangSC-Semibold", size: 10))
                        .foregroundStyle(urgent ? Color(hex: 0xAF3D58) : rose)
                    Spacer()
                    Text(homework.countdown)
                        .font(.custom("PingFangSC-Semibold", size: 12))
                        .foregroundStyle(urgent ? Color(hex: 0xAF3D58) : rose)
                }
                Text(homework.title)
                    .font(.custom("PingFangSC-Semibold", size: 15))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(homework.course).lineLimit(1)
                    Circle().fill(ink.opacity(0.28)).frame(width: 3, height: 3)
                    Text("截止 \(homework.dueLabel)").lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.custom("PingFangSC-Regular", size: 9))
                .foregroundStyle(ink.opacity(0.6))
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Color(hex: 0xFFF9F6), Color(hex: 0xFFECEF)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(selected ? rose.opacity(0.55) : .white, lineWidth: 1.3))
        }
        .buttonStyle(.plain)
    }

    private func homeworkCard(_ homework: Homework) -> some View {
        let selected = selectedID == homework.id
        return Button { withAnimation(.easeInOut(duration: 0.18)) { selectedID = selected ? nil : homework.id } } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(homework.status == "已逾期" ? Color(hex: 0xE78E9C) : lilac).frame(width: 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(homework.title).font(.custom("PingFangSC-Medium", size: 12)).foregroundStyle(ink).lineLimit(1)
                    Text(homework.course).font(.custom("PingFangSC-Regular", size: 9)).foregroundStyle(ink.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 3)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(homework.countdown).font(.custom("PingFangSC-Semibold", size: 10))
                        .foregroundStyle(homework.status == "已逾期" ? Color(hex: 0xB4435D) : rose).lineLimit(1)
                    Text("截止 \(homework.dueLabel)").font(.custom("PingFangSC-Regular", size: 8)).foregroundStyle(ink.opacity(0.48)).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? .white : .white.opacity(0.58), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? lilac.opacity(0.7) : .white.opacity(0.9), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func detailCard(_ homework: Homework) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("作业要求").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(ink.opacity(0.7))
            Text(homework.description.isEmpty ? "Canvas 没有附作业说明。" : homework.description)
                .font(.system(size: 10, design: .rounded)).foregroundStyle(ink).lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let value = homework.htmlURL ?? "\(store.canvasURL)/courses/\(homework.courseID)/assignments/\(homework.id)"
                if let url = URL(string: value) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 5) { Text("打开这份作业"); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(hex: 0xC85E78), in: Capsule())
            }.buttonStyle(.plain)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var settingsSheet: some View {
        SettingsView(store: store)
    }

    private var avatarMenuEntries: [AvatarMenuEntry] {
        [
            AvatarMenuEntry(title: "现在同步") { store.refresh() },
            AvatarMenuEntry(title: "设置 Canvas…") { showSettings = true },
            .divider(),
            AvatarMenuEntry(title: "退出桌宠", isDestructive: true, handler: onQuit),
        ]
    }

    private func toggleExpanded() {
        if expanded {
            collapsePanel()
        } else {
            expanded = true
            onExpand(true)
        }
    }

    private func collapsePanel() {
        guard expanded else { return }
        expanded = false
        selectedID = nil
        onExpand(false)
        // 收起清单时把气泡放出来，保持"默认能看到最近作业提示"。
        bubbleVisibility.revealNow()
    }
}

/// 由 PetPanelController 每秒刷新的桌宠环境状态，供视图层跟随调整（如全屏时不放气泡）。
@MainActor
final class AmbientState: ObservableObject {
    @Published var isFrontAppFullScreen = false
    /// 自动滑行或被手动拖动时为 true，头像据此切换成赶路中的贴图。
    @Published var isMoving = false
    /// 控制器检测到"点击了清单外部"时递增，PetView 收起清单。
    @Published var collapseRequestID = 0

    func requestCollapse() {
        collapseRequestID += 1
    }
}

@MainActor
final class IdleBubbleVisibility: ObservableObject {
    @Published private(set) var isVisible = true

    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var revealTask: Task<Void, Never>?

    func start() {
        guard globalClickMonitor == nil, localClickMonitor == nil else { return }
        let mouseClicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseClicks) { [weak self] _ in
            Task { @MainActor in self?.noteClick() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseClicks) { [weak self] event in
            Task { @MainActor in self?.noteClick() }
            return event
        }
    }

    func revealNow() {
        revealTask?.cancel()
        revealTask = nil
        isVisible = true
    }

    /// 点击后气泡静默多久再放出。
    private static let revealDelayNanoseconds: UInt64 = 3 * 60 * 1_000_000_000

    private func noteClick() {
        isVisible = false
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.revealDelayNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.isVisible = true
            self.revealTask = nil
        }
    }
}

struct AvatarMenuEntry {
    let title: String?
    let isDestructive: Bool
    let handler: (() -> Void)?

    init(title: String, isDestructive: Bool = false, handler: (() -> Void)?) {
        self.title = title
        self.isDestructive = isDestructive
        self.handler = handler
    }

    private init(title: String?, isDestructive: Bool, handler: (() -> Void)?) {
        self.title = title
        self.isDestructive = isDestructive
        self.handler = handler
    }

    static func divider() -> AvatarMenuEntry {
        AvatarMenuEntry(title: nil, isDestructive: false, handler: nil)
    }
}

/// 展开窗格标题区的拖动手柄：按住拖动即可临时挪动整个面板。
struct HeaderDragArea: NSViewRepresentable {
    let onDragStart: () -> Void
    var onTap: (() -> Void)? = nil

    func makeNSView(context: Context) -> HeaderDragAreaView {
        let view = HeaderDragAreaView()
        view.onDragStart = onDragStart
        view.onTap = onTap
        return view
    }

    func updateNSView(_ view: HeaderDragAreaView, context: Context) {
        view.onDragStart = onDragStart
        view.onTap = onTap
    }
}

final class HeaderDragAreaView: NSView {
    var onDragStart: (() -> Void)?
    var onTap: (() -> Void)?

    private static let dragEngageDistance: CGFloat = 4
    private var isDragging = false
    private var dragOffsetInWindow = NSPoint.zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragOffsetInWindow = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        if !isDragging {
            let moved = hypot(
                event.locationInWindow.x - dragOffsetInWindow.x,
                event.locationInWindow.y - dragOffsetInWindow.y
            )
            guard moved > Self.dragEngageDistance else { return }
            isDragging = true
            onDragStart?()
        }
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: pointer.x - dragOffsetInWindow.x,
            y: pointer.y - dragOffsetInWindow.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        defer { isDragging = false }
        if !isDragging {
            onTap?()
        }
    }
}

struct AvatarMoveArea: NSViewRepresentable {
    let onTap: () -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    let menuEntries: [AvatarMenuEntry]

    func makeNSView(context: Context) -> AvatarMoveAreaView {
        let view = AvatarMoveAreaView()
        view.onTap = onTap
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.menuEntries = menuEntries
        return view
    }

    func updateNSView(_ view: AvatarMoveAreaView, context: Context) {
        view.onTap = onTap
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.menuEntries = menuEntries
    }
}

/// 头像的交互区：短按展开清单，长按（0.25 秒）后进入拖动模式移动面板，右键弹菜单。
final class AvatarMoveAreaView: NSView {
    var onTap: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var menuEntries: [AvatarMenuEntry] = []

    private static let longPressDuration: TimeInterval = 0.25
    private static let dragEngageDistance: CGFloat = 8
    private var pressStart: Date?
    private var pressLocationInWindow = NSPoint.zero
    private var isDragging = false
    private var dragOffsetInWindow = NSPoint.zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressStart = Date()
        pressLocationInWindow = event.locationInWindow
        isDragging = false
        dragOffsetInWindow = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        if !isDragging {
            guard let pressStart else { return }
            let elapsed = Date().timeIntervalSince(pressStart)
            let moved = hypot(
                event.locationInWindow.x - pressLocationInWindow.x,
                event.locationInWindow.y - pressLocationInWindow.y
            )
            // 长按住再动，或按下后直接拖出一段距离，都进入拖动模式。
            guard elapsed >= Self.longPressDuration || moved > Self.dragEngageDistance else { return }
            isDragging = true
            onDragStart?()
        }
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: pointer.x - dragOffsetInWindow.x,
            y: pointer.y - dragOffsetInWindow.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressStart = nil
            isDragging = false
        }
        guard let pressStart else { return }
        if isDragging {
            onDragEnd?()
        } else if Date().timeIntervalSince(pressStart) < Self.longPressDuration {
            onTap?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, entry) in menuEntries.enumerated() {
            guard let title = entry.title else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(runMenuEntry(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.isEnabled = true
            if entry.isDestructive {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)]
                )
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runMenuEntry(_ sender: NSMenuItem) {
        guard menuEntries.indices.contains(sender.tag), let handler = menuEntries[sender.tag].handler else { return }
        handler()
    }
}

struct SpeechTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.width * 0.35, y: rect.height * 0.38))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.width * 0.34, y: rect.height * 0.64))
            path.closeSubpath()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AssignmentStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Canvas 连接").font(.system(size: 17, weight: .bold, design: .rounded))
            Text("爱音只会从本机许可证文件读取登录信息。")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            Text("Canvas 地址").font(.system(size: 11, weight: .semibold, design: .rounded))
            TextField("https://oc.sjtu.edu.cn", text: $store.canvasURL)
                .textFieldStyle(.roundedBorder)
            Text("许可证文件路径").font(.system(size: 11, weight: .semibold, design: .rounded))
            HStack {
                TextField("本地文件路径", text: $store.tokenPath).textFieldStyle(.roundedBorder)
                Button("选择…") {
                    let picker = NSOpenPanel()
                    picker.canChooseFiles = true
                    picker.canChooseDirectories = false
                    picker.allowsMultipleSelection = false
                    if picker.runModal() == .OK, let url = picker.url { store.tokenPath = url.path }
                }
            }
            HStack {
                Spacer()
                Button("完成") {
                    store.saveSettings()
                    dismiss()
                    store.refresh()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 390)
    }
}

struct ReferenceCharacter: View {
    private static let portrait: NSImage? = Bundle.main.url(forResource: "anon_head", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
    private static let movingPortrait: NSImage? = Bundle.main.url(forResource: "anon_angry", withExtension: "webp")
        .flatMap { NSImage(contentsOf: $0) }
    private static let tiredPortrait: NSImage? = Bundle.main.url(forResource: "anon_tired", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var isMoving = false
    var isExhausted = false

    var body: some View {
        ZStack {
            // 移动赶路优先于紧急疲惫：拖动/滑行时保留赶路表情，停下来才显示疲惫贴图。
            if isMoving, let moving = Self.movingPortrait {
                Image(nsImage: moving)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .transition(.opacity)
            } else if isExhausted, let tired = Self.tiredPortrait {
                Image(nsImage: tired)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .transition(.opacity)
            } else if let portrait = Self.portrait {
                Image(nsImage: portrait)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                Image(systemName: "face.smiling")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color(hex: 0xD99AB2))
                    .padding(15)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isMoving)
        .animation(.easeInOut(duration: 0.15), value: isExhausted)
        .shadow(color: Color(hex: 0x6B4355).opacity(0.18), radius: 5, x: 0, y: 3)
    }
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
