import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
struct Node: Codable { let depth: Int; let role: String; let title: String; let value: String }
func collect(_ root: AXUIElement) -> [Node] {
    var result: [Node] = []
    var visited: [AXUIElement] = []
    let deadline = Date().addingTimeInterval(10)
    func walk(_ node: AXUIElement, depth: Int) {
        guard depth < 60, visited.count < 6000, Date() < deadline,
              !visited.contains(where: { CFEqual($0,node) }) else { return }
        visited.append(node)
        let role = attr(node,kAXRoleAttribute) as? String ?? ""
        if role == "AXSecureTextField" { return }
        result.append(Node(depth:depth, role:role,
                           title:attr(node,kAXTitleAttribute) as? String ?? "",
                           value:attr(node,kAXValueAttribute) as? String ?? ""))
        for child in attr(node,kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child,depth:depth+1) }
    }
    walk(root,depth:0)
    return result
}
// A completed assistant message has its own copy action. Never infer completion
// from unrelated status text or remove repeated words from the response.
func latestReply(_ nodes: [Node]) -> String? {
    let headings = nodes.indices.filter {
        nodes[$0].role == "AXHeading" && ["ChatGPT 说：", "你说：", "ChatGPT said:", "You said:"].contains(nodes[$0].title)
    }
    guard let start = headings.last,
          ["ChatGPT 说：", "ChatGPT said:"].contains(nodes[start].title) else { return nil }
    var parts: [String] = []
    for node in nodes.dropFirst(start + 1) {
        if node.role == "AXButton" && ["复制", "Copy"].contains(node.title) {
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        if node.role == "AXHeading" { return nil }
        if node.role == "AXStaticText" {
            let value = node.value.isEmpty ? node.title : node.value
            if !value.isEmpty && value != nodes[start].title { parts.append(value) }
        }
    }
    return nil
}
@main struct ScreenProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        func option(_ name: String) -> String? { guard let i=args.firstIndex(of:name),i+1<args.count else {return nil};return args[i+1] }
        if args.contains("--check") {
            print("Accessibility: \(AXIsProcessTrusted()); Screen recording: \(CGPreflightScreenCaptureAccess())");return
        }
        var baseline: Set<String>?
        var previousReply: String?
        var completedReply: String?
        do {
            if let bundle = option("--app"), option("--type") != nil || args.contains("--buttons") {
                let text = option("--type") ?? ""
                guard AXIsProcessTrusted(), let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { throw NSError(domain:"App unavailable or Accessibility permission missing",code:5) }
                let root = AXUIElementCreateApplication(running.processIdentifier)
                AXUIElementSetMessagingTimeout(root,0.5)
                AXUIElementSetAttributeValue(root,"AXManualAccessibility" as CFString,kCFBooleanTrue)
                AXUIElementSetAttributeValue(root,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
                try await Task.sleep(nanoseconds: 500_000_000)
                var fields: [AXUIElement] = []
                var count = 0
                func visit(_ node: AXUIElement, _ depth: Int) {
                    guard depth < 35, count < 4000 else { return }; count += 1
                    let role = attr(node,kAXRoleAttribute) as? String ?? ""
                    if args.contains("--buttons"), role == "AXButton" {
                        print("BUTTON title=\(attr(node,kAXTitleAttribute) as? String ?? "") description=\(attr(node,kAXDescriptionAttribute) as? String ?? "") id=\(attr(node,kAXIdentifierAttribute) as? String ?? "")")
                    }
                    if role == "AXTextArea" || role == "AXTextField" {
                        var settable = DarwinBoolean(false)
                        if AXUIElementIsAttributeSettable(node,kAXValueAttribute as CFString,&settable) == .success && settable.boolValue { fields.append(node) }
                    }
                    for child in attr(node,kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child,depth+1) }
                }
                visit(root,0)
                if args.contains("--buttons") { return }
                if fields.count > 1 {
                    let focused = fields.filter { (attr($0,kAXFocusedAttribute) as? Bool) == true }
                    if focused.count == 1 { fields = focused }
                }
                guard fields.count == 1 else { throw NSError(domain:"No unique writable input; focus the intended chat input and retry",code:6) }
                // Replace the editor contents regardless of placeholder or existing text.
                if args.contains("--send") {
                    let snapshot = collect(root)
                    baseline = Set(snapshot.filter { $0.role == "AXStaticText" }.flatMap { [$0.title,$0.value] })
                    previousReply = latestReply(snapshot)
                }
                let status = AXUIElementSetAttributeValue(fields[0],kAXValueAttribute as CFString,text as CFString)
                guard status == .success else { throw NSError(domain:"AX input rejected: \(status.rawValue)",code:8) }
                try await Task.sleep(nanoseconds: 500_000_000)
                print("Readback: \(String(reflecting: attr(fields[0],kAXValueAttribute) as? String ?? ""))")
                let readback = attr(fields[0],kAXValueAttribute) as? String ?? ""
                let verified = readback == text || readback == text + "\n"
                print("Input verified: \(verified)")
                if args.contains("--send") {
                    guard verified else { throw NSError(domain:"Input verification failed; send button not clicked",code:9) }
                    let expected = option("--send-button")
                    let labels = expected.map { [$0] } ?? ["发送", "发送消息", "发送提示", "Send", "Send message", "Send prompt"]
                    let deadline = Date().addingTimeInterval(30)
                    var pressed = false
                    while Date() < deadline {
                        var candidates: [AXUIElement] = []
                        var scanned = 0
                        func buttons(_ node: AXUIElement, _ depth: Int) {
                            guard depth < 35, scanned < 4000 else { return }; scanned += 1
                            if attr(node,kAXRoleAttribute) as? String == "AXButton" {
                                let title = attr(node,kAXTitleAttribute) as? String ?? ""
                                let description = attr(node,kAXDescriptionAttribute) as? String ?? ""
                                if (labels.contains(title) || labels.contains(description)),
                                   attr(node,kAXEnabledAttribute) as? Bool == true { candidates.append(node) }
                            }
                            for child in attr(node,kAXChildrenAttribute) as? [AXUIElement] ?? [] { buttons(child,depth+1) }
                        }
                        buttons(root,0)
                        guard candidates.count <= 1 else { throw NSError(domain:"Multiple send buttons; nothing clicked",code:10) }
                        if let button = candidates.first {
                            guard AXUIElementPerformAction(button,kAXPressAction as CFString) == .success else { throw NSError(domain:"Send button press rejected",code:11) }
                            pressed = true
                            print("Send button pressed. Check conversation for submission.")
                            break
                        }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    guard pressed else { throw NSError(domain:"No enabled send button found within 30 seconds. Run --buttons to inspect labels; use --send-button LABEL if needed.",code:12) }
                } else { print("Not submitted. Use --send to click the send button after typing.") }

                if !args.contains("--send") { return }
                print("Waiting for response (up to 180 seconds)…")
                let responseDeadline = Date().addingTimeInterval(180)
                var previous = ""
                var stableSince = Date()
                var completed = false
                while Date() < responseDeadline {
                    let snapshot = collect(root)
                    let busy = snapshot.contains { $0.role == "AXButton" && ["停止","Stop","停止生成","Stop generating"].contains($0.title) }
                    let reply = latestReply(snapshot)
                    let fresh = reply != previousReply ? (reply ?? "") : ""
                    if fresh != previous || busy { previous = fresh; stableSince = Date() }
                    if !busy && !fresh.isEmpty && Date().timeIntervalSince(stableSince) >= 5 { completedReply = fresh; completed = true; break }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard completed else { throw NSError(domain:"Response did not reach idle with new text within 180 seconds",code:13) }
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            if args.contains("--list") {
                for w in content.windows where w.windowLayer == 0 {
                    print("\(w.windowID)\t\(w.owningApplication?.bundleIdentifier ?? "")\t\(w.title ?? "")")
                };return
            }
            guard let bundle=option("--app") else { throw NSError(domain:"Use --list, --check, or --app BUNDLE_ID [--window ID] [--output DIR]",code:1) }
            let matches=content.windows.filter { $0.owningApplication?.bundleIdentifier == bundle && $0.windowLayer == 0 }
            let selected: SCWindow?
            if let id=option("--window") {selected=matches.first { String($0.windowID)==id }}
            else { selected=matches.count == 1 ? matches[0] : nil }
            guard let window=selected,let owner=window.owningApplication else { throw NSError(domain:"No unique window; use --list then specify --window",code:2) }
            guard AXIsProcessTrusted(),CGPreflightScreenCaptureAccess() else { throw NSError(domain:"Accessibility and Screen Recording permissions required",code:3) }
            let directory=URL(fileURLWithPath:option("--output") ?? "./artifacts").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let app=AXUIElementCreateApplication(owner.processID)
            AXUIElementSetMessagingTimeout(app,0.5)
            // Capture AX only if the application's window can be matched unambiguously by title.
            let windows=attr(app,kAXWindowsAttribute) as? [AXUIElement] ?? []
            let axMatches=windows.filter { (attr($0,kAXTitleAttribute) as? String) == window.title }
            let axWindows = windows
            let captureRoot: AXUIElement? = axMatches.count == 1 ? axMatches[0] : (axWindows.count == 1 ? axWindows[0] : nil)
            let nodes = captureRoot.map { collect($0) } ?? []
            let config=SCStreamConfiguration();config.width=max(1,Int(window.frame.width*2));config.height=max(1,Int(window.frame.height*2));config.showsCursor=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:window),configuration:config)
            guard let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {throw NSError(domain:"PNG encoding failed",code:4)}
            let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
            request.recognitionLanguages=["zh-Hans","en-US"];request.usesLanguageCorrection=true
            try VNImageRequestHandler(cgImage:image).perform([request])
            let ocr=request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            let texts=nodes.flatMap { [$0.title,$0.value] }.filter { !$0.isEmpty }
            let metadata:[String:Any] = ["app":bundle,"window_id":window.windowID,"title":window.title ?? "","captured_at":ISO8601DateFormatter().string(from:Date()),"ax_window_matched":axMatches.count == 1,"ax_nodes":nodes.count,"note":"AX traversal bounded to 10 seconds / 3000 nodes / depth 30; OCR covers visible screenshot only"]
            var files:[String:Data] = ["window.png":png,"accessibility.json":try encoder.encode(nodes),"accessibility.txt":Data(texts.joined(separator:"\n").utf8),"ocr.txt":Data(ocr.joined(separator:"\n").utf8),"metadata.json":try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys])]
            if baseline != nil {
                guard let answer = completedReply else { throw NSError(domain:"Completed assistant reply missing",code:14) }
                files["answer.txt"] = Data(answer.utf8)
                files["answer-note.txt"] = Data("Candidate reply: new AXStaticText since submission, may include UI labels; idle heuristic, not a server completion guarantee. OCR is in ocr.txt.".utf8)
                print("Candidate reply:\n\(answer)")
            }
            for (name,data) in files {let url=directory.appendingPathComponent(name);try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
            print("Saved: \(directory.path)\nAX nodes: \(nodes.count); OCR lines: \(ocr.count)")
        } catch {fputs("ScreenProbe: \(error)\n",stderr);exit(1)}
    }
}
