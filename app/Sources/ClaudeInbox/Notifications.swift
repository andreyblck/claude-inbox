import AppKit
import UserNotifications

/// Telling you the moment a session blocks, so that finding out is not a thing
/// you have to remember to do.
///
/// A banner with Approve and Deny on it is the whole product in one interaction:
/// the decision arrives, you answer it, the session carries on, and no window was
/// ever opened.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let category = "claude.permission"
    private let approve = "claude.approve"
    private let deny = "claude.deny"

    /// Requests already announced. Re-announcing one on every directory change
    /// would turn a dozen sessions into a stream of duplicate banners.
    private var announced: Set<String> = []
    private(set) var authorized = false
    /// Nil until the system has answered. Distinguishing "not asked yet" from
    /// "asked and refused" is the difference between a useful line and a nag.
    private(set) var settled: Bool?

    /// Set by the app so an action can be answered without the panel being open.
    var onDecision: ((String, Bool) -> Void)?

    private var center: UNUserNotificationCenter? {
        // An app running outside a bundle has no notification centre, and asking
        // for one traps rather than returning nil. Only ask when we are bundled.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self

        let approveAction = UNNotificationAction(
            identifier: approve, title: "Approve", options: [])
        let denyAction = UNNotificationAction(
            identifier: deny, title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: category,
                actions: [approveAction, denyAction],
                intentIdentifiers: [],
                options: [.customDismissAction])
        ])

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.authorized = granted
                self.settled = true
            }
        }
    }

    /// Announce anything blocked that has not been announced yet, and forget the
    /// ones that have gone — a request answered elsewhere should be able to come
    /// back later without being silently swallowed.
    func sync(pending: [PendingItem], waiting: [SessionRecord]) {
        guard let center, authorized else { return }
        let live = Set(pending.map(\.req)).union(waiting.map(\.sessionId))
        announced.formIntersection(live)

        for item in pending where !announced.contains(item.req) {
            announced.insert(item.req)
            // Demo rows exist to be looked at, not to interrupt anyone.
            guard item.demo != true else { continue }
            post(
                id: item.req,
                title: Format.projectName(cwd: item.cwd, fallback: item.sessionId, name: nil),
                body: Format.askPhrase(item, max: 120),
                answerable: true)
        }

        // A session in acceptEdits or bypassPermissions almost never raises a
        // permission request, so without these the app is silent through most of
        // a working day. These cannot be answered from here — only the terminal
        // can — so they arrive without buttons.
        for session in waiting where !announced.contains(session.sessionId) {
            announced.insert(session.sessionId)
            guard session.demo != true else { continue }
            post(
                id: session.sessionId,
                title: Format.label(session),
                body: Format.headline(session, max: 120),
                answerable: false)
        }
    }

    private func post(id: String, title: String, body: String, answerable: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if answerable { content.categoryIdentifier = category }
        content.userInfo = ["req": id]
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Take the person to the one screen where this can be changed. Telling
    /// someone a permission is missing without saying where is half a message.
    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.notifications")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// A request answered in the panel should not leave a banner behind offering
    /// to answer it again.
    func withdraw(_ req: String) {
        announced.remove(req)
        center?.removeDeliveredNotifications(withIdentifiers: [req])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The app has no windows of its own, so "frontmost" is never a reason to
        // stay quiet.
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let req = response.notification.request.content.userInfo["req"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let req else { return }
            switch action {
            case self.approve: self.onDecision?(req, true)
            case self.deny: self.onDecision?(req, false)
            default: break  // tapping the banner opens the panel instead
            }
        }
    }
}
