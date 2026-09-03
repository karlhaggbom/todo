import AppKit
import os

/// Lightweight in-app diagnostics for hunting the blank-window bug.
/// Everything here is cheap: a few os_log lines and a periodic AppKit
/// window-health probe. Stream with:
///   log stream --predicate 'subsystem == "com.local.todo"'
enum Diag {
    static let log = Logger(subsystem: "com.local.todo", category: "diag")

    /// Number of JiraBoardContent body evaluations (logged every 10th).
    @MainActor static var boardBodyEvals = 0

    /// One-line health report for every app window. If the SwiftUI content
    /// detaches from the window, `content`/`subs`/`alpha` reveal it.
    @MainActor
    static func windowHealth() {
        for w in NSApp.windows {
            let content = w.contentView.map { String(describing: type(of: $0)) } ?? "nil"
            let subs = w.contentView?.subviews.count ?? -1
            log.info("WIN frame=\(String(describing: w.frame), privacy: .public) occl=\(w.occlusionState.rawValue) alpha=\(w.alphaValue) visible=\(w.isVisible) key=\(w.isKeyWindow) content=\(content, privacy: .public) subs=\(subs)")
        }
    }

    /// Start the periodic window probe (idempotent).
    @MainActor
    static func startProbe(every seconds: TimeInterval = 2) {
        guard probeTimer == nil else { return }
        let timer = Timer(timeInterval: seconds, repeats: true) { _ in
            Task { @MainActor in windowHealth() }
        }
        probeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        log.info("probe started")
    }

    @MainActor private static var probeTimer: Timer?

    /// Recursively log the AppKit view tree of the key window.
    @MainActor
    static func deepDump() {
        log.info("=== DEEP DUMP ===")
        guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            log.info("DEEP DUMP: no visible window")
            return
        }
        func walk(_ v: NSView, depth: Int) {
            let desc = String(describing: type(of: v))
            log.info("VIEW \(String(repeating: ".", count: min(depth, 20)), privacy: .public)\(desc, privacy: .public) frame=\(String(describing: v.frame), privacy: .public) hidden=\(v.isHidden) alpha=\(v.alphaValue) subs=\(v.subviews.count)")
            guard depth < 12 else { return }
            for s in v.subviews { walk(s, depth: depth + 1) }
        }
        if let cv = w.contentView { walk(cv, depth: 0) }
        else { log.info("DEEP DUMP: nil contentView") }
    }

    /// Capture our own window to /tmp (own-window capture needs no TCC
    /// permission) so the window's pixels can be inspected from outside.
    /// This is our only reliable pixel-level ground truth.
    @MainActor
    static func selfCapture() {
        guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            log.info("selfcapture: no visible window")
            return
        }
        let wid = CGWindowID(w.windowNumber)
        let bounds = CGRect.null
        guard let img = CGWindowListCreateImage(bounds, [.optionIncludingWindow], wid, [.boundsIgnoreFraming, .bestResolution]) else {
            log.error("selfcapture FAILED wid=\(wid) — no renderable surface")
            return
        }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            log.error("selfcapture: png encode failed")
            return
        }
        let name = "/tmp/todo-selfcapture-\(Int(Date().timeIntervalSince1970)).png"
        do { try data.write(to: URL(fileURLWithPath: name)) } catch { return }
        log.info("selfcapture wrote \(name, privacy: .public) size=\(img.width)x\(img.height)")
    }

    /// Render the key window's content tree through the PDF (printing) path.
    /// If this produces content while selfCapture shows blank pixels, the
    /// tree is fine and the failure is in on-screen compositing.
    @MainActor
    static func selfRender() {
        guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let cv = w.contentView else { return }
        let pdf = cv.dataWithPDF(inside: cv.bounds)
        let name = "/tmp/todo-render-\(Int(Date().timeIntervalSince1970)).pdf"
        try? pdf.write(to: URL(fileURLWithPath: name))
        log.info("selfRender wrote \(name, privacy: .public) bytes=\(pdf.count)")
    }

    /// Log window moves and screen changes with timestamps so we can
    /// correlate display hops with rendering state.
    @MainActor
    static func observeMoves() {
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { note in
            let w = note.object as? NSWindow
            Task { @MainActor in
                log.info("WINDOW DID MOVE -> \(String(describing: w?.frame), privacy: .public) screen=\(w?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")].flatMap { ($0 as? NSNumber).map(\.stringValue) } ?? "nil", privacy: .public)")
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in log.info("WINDOW DID CHANGE SCREEN") }
        }
    }
}