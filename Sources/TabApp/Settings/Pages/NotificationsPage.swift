import AppKit
import TabCore

extension SettingsModel {
    func buildNotifications(_ b: SettingsPageBuilder) {
        let notifications = store.settings.notifications
        func toggle(_ id: String, _ value: Bool, enabled: Bool = true, _ set: @escaping (inout NotificationSettings, Bool) -> Void) {
            b.row(id, b.toggle(id, value, enabled: enabled) { [store] on in store.updateNotifications(id) { set(&$0, on) } })
        }

        // In-App Notifications
        b.row("notification-position", b.position("notification-position", notifications.position) { [store] position in
            store.updateNotifications("notification-position") { $0.position = position }
        }, description: "Displayed \(notifications.position.title)")

        // Program Activity
        toggle("activity-tabs", notifications.showActivityInTabs) { $0.showActivityInTabs = $1 }
        toggle("activity-system", notifications.systemNotifications) { $0.systemNotifications = $1 }
        toggle("activity-badge", notifications.dockBadge) { $0.dockBadge = $1 }
        toggle("activity-sounds", notifications.playSounds) { $0.playSounds = $1 }
        for status in ActivityStatus.allCases {
            b.row("status-\(status.rawValue)", .disclosure { [weak self] in self?.open(SettingsSubpage(status)) },
                  description: notifications.channels(status), icon: StatusIcon.image(status), iconSide: 28)
        }

        // System Notifications
        toggle("terminal-notifications", notifications.terminalNotifications) { $0.terminalNotifications = $1 }

        // A status's page
        for status in ActivityStatus.allCases {
            let id = status.rawValue
            let current = notifications[status]
            b.row("\(id)-enabled", b.toggle("\(id)-enabled", current.enabled) { [store] on in
                store.updateNotifications("\(id)-enabled") { $0[status].enabled = on }
            }, icon: StatusIcon.image(status), iconSide: 28)
            toggle("\(id)-tabs", current.showInTabs, enabled: current.enabled) { $0[status].showInTabs = $1 }
            toggle("\(id)-system", current.systemNotifications, enabled: current.enabled) { $0[status].systemNotifications = $1 }
            toggle("\(id)-badge", current.dockBadge, enabled: current.enabled) { $0[status].dockBadge = $1 }
            toggle("\(id)-play", current.playSound, enabled: current.enabled) { $0[status].playSound = $1 }
            let sounds = NotificationSound.allCases.map { Choice(id: $0.rawValue, title: $0.title) }
            b.row("\(id)-sound", .row([
                b.popUp("\(id)-sound", sounds, selected: current.sound.rawValue) { [store] raw in
                    guard let sound = NotificationSound(rawValue: raw) else { return }
                    store.updateNotifications("\(id)-sound") { $0[status].sound = sound }
                    BubbleSounds.play(sound)
                },
                b.button("Play \(current.sound.title)", icon: .play) { BubbleSounds.play(current.sound) },
            ]))
        }
    }
}

/// A status's icon: a white Tab Icon on a colored disc, like Settings' page icons.
enum StatusIcon {
    private static var cache: [ActivityStatus: NSImage] = [:]

    @MainActor
    static func image(_ status: ActivityStatus) -> NSImage {
        if let image = cache[status] { return image }
        let (icon, top, bottom): (AppIcon, UInt32, UInt32)
        switch status {
        case .working: (icon, top, bottom) = (.ellipsis, 0x5BB2FF, 0x1F6FEB)
        case .blocked: (icon, top, bottom) = (.ban, 0xFFC94A, 0xF29D1B)
        case .error: (icon, top, bottom) = (.triangleAlert, 0xFF8A65, 0xE5484D)
        case .done: (icon, top, bottom) = (.circleCheck, 0x8EDB6B, 0x3FA84A)
        }
        let side: CGFloat = 28
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let disc = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSGradient(starting: color(top), ending: color(bottom))?.draw(in: disc, angle: -90)
            NSColor.black.withAlphaComponent(0.12).setStroke()
            disc.lineWidth = 0.5
            disc.stroke()
            guard let glyph = icon.image(size: 14, color: .white) else { return true }
            let size = glyph.size
            glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        cache[status] = image
        return image
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
