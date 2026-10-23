import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let input = NSTextField()
    let output = NSTextField(wrappingLabelWithString: "Ready")
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Bridge Mock AI"
        input.frame = NSRect(x: 24, y: 340, width: 590, height: 32)
        input.setAccessibilityIdentifier("bridge.prompt")
        let button = NSButton(title: "Generate", target: self, action: #selector(generate))
        button.frame = NSRect(x: 24, y: 290, width: 120, height: 32)
        button.setAccessibilityIdentifier("bridge.submit")
        output.frame = NSRect(x: 24, y: 24, width: 590, height: 240)
        output.setAccessibilityIdentifier("bridge.answer")
        for view in [input, button, output] { window.contentView!.addSubview(view) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func generate() {
        let prompt = input.stringValue
        output.stringValue = "Generating…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.output.stringValue = "Mock answer: \(prompt)"
        }
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
