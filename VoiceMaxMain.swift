import AppKit

/// Явная точка входа: при сборке `swiftc` без Xcode `@main` у `AppDelegate` иногда **не** вызывает `NSApplicationMain` с привязкой delegate — в итоге приложение «молчит» (нет трея, нет логов).
@main
enum VoiceMaxMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
