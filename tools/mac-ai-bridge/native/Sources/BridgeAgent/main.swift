import AppKit
import ApplicationServices
import ScreenCaptureKit

struct Failure: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }
struct Job: Decodable { let id: String; let prompt: String; let lease: String }
struct Result: Encodable { let id: String; let lease: String; var answer = ""; var error = ""; var screenshots: [String:String] = [:] }
func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
    return value
}
func find(_ node: AXUIElement, _ identifier: String, depth: Int = 0) -> AXUIElement? {
    if attribute(node, kAXIdentifierAttribute) as? String == identifier { return node }
    guard depth < 20 else { return nil }
    for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let result = find(child, identifier, depth: depth + 1) { return result }
    }
    return nil
}
func pause() async throws { try await Task.sleep(nanoseconds: 200_000_000) }
func screenshot(pid: pid_t) async throws -> String {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.title == "Bridge Mock AI" }) else { throw Failure("owned window unavailable") }
    let config = SCStreamConfiguration()
    config.width = 1280; config.height = 840; config.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure("PNG encoding failed") }
    return png.base64EncodedString()
}
@MainActor
func execute(_ job: Job, executable: String) async -> Result {
    var result = Result(id: job.id, lease: job.lease)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    // Only the bundled, self-owned fixture is supported in this first adapter.
    do {
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        let deadline = Date().addingTimeInterval(30)
        var input: AXUIElement?
        while Date() < deadline && process.isRunning {
            input = find(app, "bridge.prompt")
            if input != nil { break }; try await pause()
        }
        guard let input, let submit = find(app,"bridge.submit") else { throw Failure("fixture controls unavailable") }
        guard AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, job.prompt as CFString) == .success else { throw Failure("input rejected") }
        guard AXUIElementPerformAction(submit, kAXPressAction as CFString) == .success else { throw Failure("submit rejected") }
        result.screenshots["generating"] = try await screenshot(pid: process.processIdentifier)
        while Date() < deadline && process.isRunning {
            if let answer = find(app,"bridge.answer"), let value = attribute(answer,kAXValueAttribute) as? String, value.hasPrefix("Mock answer: ") {
                result.answer = value
                result.screenshots["final"] = try await screenshot(pid: process.processIdentifier)
                return result
            }
            try await pause()
        }
        throw Failure("answer deadline exceeded")
    } catch { result.error = String(describing: error); return result }
}
func request(_ base: URL, _ path: String, token: String, body: Data) async throws -> Data? {
    var req = URLRequest(url: base.appendingPathComponent(path))
    req.httpMethod = "POST"; req.httpBody = body; req.timeoutInterval = 15
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data,response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw Failure("invalid response") }
    if http.statusCode == 204 { return nil }
    guard http.statusCode == 200 else { throw Failure("coordinator HTTP \(http.statusCode)") }
    return data
}
@main struct Main {
    @MainActor static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        if args.contains("--check") {
            print("Accessibility: \(AXIsProcessTrusted()); Screen recording: \(CGPreflightScreenCaptureAccess())")
            return
        }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            fputs("Grant Accessibility and Screen Recording to the launching terminal/agent in System Settings, restart it, then run --check.\n",stderr); exit(1)
        }
        let fixture = URL(fileURLWithPath: args[0]).deletingLastPathComponent().appendingPathComponent("MockAI").path
        if let at = args.firstIndex(of: "--once"), args.count > at + 1 {
            let result = await execute(Job(id: UUID().uuidString,prompt: args[at+1],lease:"local"), executable: fixture)
            if let data = try? JSONEncoder().encode(result) { print(String(decoding: data,as: UTF8.self)) }
            exit(result.error.isEmpty ? 0 : 1)
        }
        let env = ProcessInfo.processInfo.environment
        guard let token = env["BRIDGE_WORKER_TOKEN"], token.count >= 24,
              let base = URL(string: env["BRIDGE_URL"] ?? "http://127.0.0.1:8088"),
              ["127.0.0.1","localhost"].contains(base.host ?? ""), base.scheme == "http" else {
            fputs("Set BRIDGE_WORKER_TOKEN; this POC accepts only a loopback coordinator (use an SSH tunnel).\n",stderr); exit(1)
        }
        do {
            while true {
                if let data = try await request(base,"worker/claim",token:token,body:Data("{}".utf8)) {
                    let job = try JSONDecoder().decode(Job.self,from:data)
                    let result = await execute(job, executable: fixture)
                    // An uncertain completion must stop the worker, not claim more GUI work.
                    _ = try await request(base,"worker/complete",token:token,body:JSONEncoder().encode(result))
                } else { try await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        } catch { fputs("Worker stopped: \(error)\n",stderr); exit(1) }
    }
}
