import ApplicationServices
import Cocoa
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

/// computer-use helper. JSON on stdout. Not OpenAI / Codex.
/// Observe never activates. Drive restores the user's front app + pointer unless --activate.

struct WindowInfo: Encodable {
    let id: UInt32
    let pid: Int32
    let name: String
    let owner: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    /// nil = unknown (no Screen Recording, so other Spaces cannot be distinguished)
    let on_screen: Bool?

    enum CodingKeys: String, CodingKey {
        case id, pid, name, owner, x, y, w, h, on_screen
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(pid, forKey: .pid)
        try c.encode(name, forKey: .name)
        try c.encode(owner, forKey: .owner)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(w, forKey: .w)
        try c.encode(h, forKey: .h)
        if let on_screen {
            try c.encode(on_screen, forKey: .on_screen)
        } else {
            try c.encodeNil(forKey: .on_screen)
        }
    }
}

struct UserContext {
    let pid: pid_t
    let owner: String
    let mouse: CGPoint
}

enum HelperError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)
    var description: String {
        switch self {
        case .usage(let s), .failed(let s): return s
        }
    }
}

var currentArgv: [String] = CommandLine.arguments

func flag(_ name: String) -> Bool {
    currentArgv.contains("--\(name)")
}

func wantsActivate() -> Bool {
    flag("activate")
}

/// `--global` forces the real-pointer path for click/drag. It is the explicit
/// opt-in to take control, so it bypasses the pid-directed path entirely: the
/// pointer moves, the target app is raised first, and off-Space bounds are not
/// enforced (the raise is what brings the window to the current Space).
func wantsGlobal() -> Bool {
    flag("global")
}

func keepTargetFront() -> Bool {
    flag("keep-target-front")
}

func ourBundleID() -> String? {
    Bundle.main.bundleIdentifier
}

func ourDisplayName() -> String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "this helper"
}

func isOurApp(_ app: NSRunningApplication) -> Bool {
    if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
    guard let ours = ourBundleID() else { return false }
    return app.bundleIdentifier == ours || app.bundleIdentifier == ours + ".mcp"
}

func frontmostUserApp() -> NSRunningApplication? {
    if let front = NSWorkspace.shared.frontmostApplication, !isOurApp(front) {
        return front
    }
    return NSWorkspace.shared.runningApplications.first { app in
        !app.isTerminated && app.activationPolicy == .regular && !isOurApp(app)
    }
}

func mouseLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

func restorePidArg() -> pid_t? {
    if let s = arg("restore-pid"), let v = Int32(s), v != 0 { return pid_t(v) }
    return nil
}

func cursorRunningApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { app in
        guard !app.isTerminated, !isOurApp(app) else { return false }
        let name = (app.localizedName ?? "").lowercased()
        let bid = (app.bundleIdentifier ?? "").lowercased()
        return name == "cursor" || bid.contains("todesktop")
    }
}

func captureUserContext() -> UserContext {
    let app = frontmostUserApp()
    return UserContext(
        pid: app?.processIdentifier ?? 0,
        owner: app?.localizedName ?? "",
        mouse: mouseLocation()
    )
}

func sessionRestoreContext() -> UserContext {
    if let pid = restorePidArg() {
        let x = Double(arg("restore-x") ?? "") ?? mouseLocation().x
        let y = Double(arg("restore-y") ?? "") ?? mouseLocation().y
        return UserContext(pid: pid, owner: arg("restore-owner") ?? "", mouse: CGPoint(x: x, y: y))
    }
    return captureUserContext()
}

func sameApp(_ current: NSRunningApplication, pid: pid_t) -> Bool {
    if current.processIdentifier == pid { return true }
    guard let saved = NSRunningApplication(processIdentifier: pid), !saved.isTerminated else {
        if let owner = arg("restore-owner"), !owner.isEmpty {
            return (current.localizedName ?? "").caseInsensitiveCompare(owner) == .orderedSame
        }
        return false
    }
    if let a = current.bundleIdentifier, let b = saved.bundleIdentifier, a == b { return true }
    if let a = current.localizedName, let b = saved.localizedName, a == b { return true }
    return false
}

/// Front app is neither the session restore app nor the GUI we are driving.
func userTookOver(restorePid: pid_t, targetPid: pid_t?) -> NSRunningApplication? {
    guard let current = NSWorkspace.shared.frontmostApplication, !isOurApp(current) else {
        return nil
    }
    if restorePid != 0, sameApp(current, pid: restorePid) { return nil }
    if let t = targetPid, t != 0, sameApp(current, pid: t) { return nil }
    if let owner = arg("restore-owner"), !owner.isEmpty,
       (current.localizedName ?? "").caseInsensitiveCompare(owner) == .orderedSame {
        return nil
    }
    return current
}

func refuseIfUserTookOver(restorePid: pid_t, targetPid: pid_t?) throws {
    if let app = userTookOver(restorePid: restorePid, targetPid: targetPid) {
        let name = app.localizedName ?? "another app"
        throw HelperError.failed(
            "User is in \(name); not driving (would steal keyboard/focus)."
        )
    }
}

func restoreUserContext(_ ctx: UserContext, targetPid: pid_t? = nil, warpMouse: Bool = false) {
    // Even keep_target_front must not fight the user if they switched away.
    if userTookOver(restorePid: ctx.pid, targetPid: targetPid) != nil {
        return
    }
    if keepTargetFront() { return }
    if warpMouse {
        CGWarpMouseCursorPosition(ctx.mouse)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }
    guard ctx.pid != 0 else { return }
    let current = NSWorkspace.shared.frontmostApplication
    if current.map({ sameApp($0, pid: ctx.pid) }) == true { return }
    // Only take focus back if we actually stole it (driven app is front).
    if let current, let t = targetPid, t != 0, sameApp(current, pid: t) {
        activate(pid: ctx.pid)
        return
    }
}

func withUserPreserved(_ body: () throws -> Void) throws {
    let ctx = sessionRestoreContext()
    let target = optionalPid()
    try refuseIfUserTookOver(restorePid: ctx.pid, targetPid: target)
    defer {
        usleep(50_000)
        restoreUserContext(ctx, targetPid: target, warpMouse: true)
    }
    try body()
}

func cgWindowInfos(onScreenOnly: Bool) -> [[String: Any]] {
    let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly] : [.optionAll]
    return CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
}

var scCache: SCShareableContent?
var scCacheAt = Date.distantPast

func shareableContent() throws -> SCShareableContent {
    if let scCache, Date().timeIntervalSince(scCacheAt) < 0.5 {
        return scCache
    }
    let sem = DispatchSemaphore(value: 0)
    var content: SCShareableContent?
    var err: Error?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { c, e in
        content = c
        err = e
        sem.signal()
    }
    if sem.wait(timeout: .now() + 6) == .timedOut {
        throw HelperError.failed(
            "ScreenCaptureKit timed out. Quit this helper and relaunch so Screen Recording can attach."
        )
    }
    if let content {
        scCache = content
        scCacheAt = Date()
        return content
    }
    throw HelperError.failed(err?.localizedDescription ?? "ScreenCaptureKit failed")
}

func scWindowMap() -> [CGWindowID: SCWindow] {
    guard let content = try? shareableContent() else { return [:] }
    var out: [CGWindowID: SCWindow] = [:]
    for win in content.windows {
        out[win.windowID] = win
    }
    return out
}

func captureWindowSCK(_ id: UInt32) throws -> CGImage {
    let content = try shareableContent()
    guard let win = content.windows.first(where: { $0.windowID == id }) else {
        throw HelperError.failed("ScreenCaptureKit has no window id \(id)")
    }
    let filter = SCContentFilter(desktopIndependentWindow: win)
    let cfg = SCStreamConfiguration()
    let scaleFactor = max(1.0, NSScreen.main?.backingScaleFactor ?? 2)
    cfg.width = max(2, Int((win.frame.width * scaleFactor).rounded()))
    cfg.height = max(2, Int((win.frame.height * scaleFactor).rounded()))
    cfg.showsCursor = false
    let sem = DispatchSemaphore(value: 0)
    var image: CGImage?
    var err: Error?
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, e in
        image = img
        err = e
        sem.signal()
    }
    if sem.wait(timeout: .now() + 10) == .timedOut {
        throw HelperError.failed("ScreenCaptureKit capture timed out")
    }
    if let image { return image }
    throw HelperError.failed(err?.localizedDescription ?? "ScreenCaptureKit captureImage failed")
}

func isPidOnScreen(_ pid: pid_t) -> Bool {
    // Same join as listWindows: CG owner pid + SCK isOnScreen by windowID.
    // SCWindow.owningApplication?.processID is often 0/nil, so a pid-only SCK
    // walk disagrees with get_app_state and refuses drive after isolate.
    let map = scWindowMap()
    let onscreenIDs: Set<UInt32> = Set(
        cgWindowInfos(onScreenOnly: true).compactMap { info in
            (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    )
    for info in cgWindowInfos(onScreenOnly: false) {
        let p = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        guard p == pid else { continue }
        let layer = (info[kCGWindowLayer as String] as? Int) ?? -1
        if layer > 0 { continue }
        let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        if let sc = map[CGWindowID(wid)], sc.isOnScreen { return true }
        if onscreenIDs.contains(wid) { return true }
        if (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true { return true }
    }
    for win in map.values {
        let p = pid_t(win.owningApplication?.processID ?? 0)
        if p == pid, win.isOnScreen { return true }
    }
    return false
}

func refuseHidOffspace(pid: pid_t?) throws {
    guard let pid, pid != 0 else { return }
    if wantsActivate() { return }
    if !CGPreflightScreenCaptureAccess() { return }
    if isPidOnScreen(pid) { return }
    throw HelperError.failed(
        "HID click/scroll uses the current screen and would hit your front app, not this off-Space window. "
            + "Drive it with element_index / AX scroll / type / keys (pid-directed), like Codex. "
            + "isolate_window only if you accept a focus steal."
    )
}

func listWindows() throws {
    let screenOk = CGPreflightScreenCaptureAccess()
    let scByID = scWindowMap()
    let sckOk = !scByID.isEmpty
    let onscreenIDs: Set<UInt32> = Set(
        cgWindowInfos(onScreenOnly: true).compactMap { info in
            (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    )
    var out: [WindowInfo] = []
    var seen = Set<UInt32>()
    for info in cgWindowInfos(onScreenOnly: false) {
        let layer = (info[kCGWindowLayer as String] as? Int) ?? -1
        if layer > 0 { continue }
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
        let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
        if w < 40 || h < 40 { continue }
        var name = (info[kCGWindowName as String] as? String) ?? ""
        let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
        if owner.isEmpty { continue }
        if ["Window Server", "Dock", "Control Center", "Notification Centre", "SystemUIServer"].contains(owner) {
            continue
        }
        let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        if wid != 0, seen.contains(wid) { continue }
        if wid != 0 { seen.insert(wid) }
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
        let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? 0
        let listedOn = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
        let sc = scByID[CGWindowID(wid)]
        if name.isEmpty, let title = sc?.title, !title.isEmpty {
            name = title
        }
        let onScreen: Bool?
        if let sc {
            onScreen = sc.isOnScreen
        } else if screenOk || sckOk {
            onScreen = listedOn ?? onscreenIDs.contains(wid)
        } else if onscreenIDs.contains(wid) {
            onScreen = true
        } else {
            onScreen = nil
        }
        out.append(
            WindowInfo(
                id: wid, pid: pid, name: name, owner: owner,
                x: x, y: y, w: w, h: h, on_screen: onScreen
            )
        )
    }
    let data = try JSONEncoder().encode(out)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func activate(pid: pid_t) {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
    let ax = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(ax, kAXMainWindowAttribute as CFString, &ref) == .success,
       let win = ref {
        AXUIElementPerformAction(win as! AXUIElement, kAXRaiseAction as CFString)
    }
    // macOS 14+ : activateIgnoringOtherApps does nothing. activate(from:) is the replacement.
    _ = app.activate(from: NSRunningApplication.current)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        _ = app.activate()
    }
}

func maybeActivate(pid: pid_t?) {
    guard wantsActivate(), let pid else { return }
    activate(pid: pid)
    usleep(80_000)
}

/// Raise the **captured** window, not the app's main window. `activate(pid:)`
/// AX-raises `kAXMainWindowAttribute` and ignores `--wid`, so with a secondary
/// window (or one app spread over several Spaces) the app comes forward while
/// the target stays on another Space — and a real-pointer click at its
/// coordinates then lands on whatever is visible here instead. Falls back to
/// plain activation when there is no wid to target.
func raiseTargetWindow(pid: pid_t, windowID: CGWindowID) {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
    if windowID != 0 {
        let axApp = AXUIElementCreateApplication(pid)
        axEnableIfNeeded(axApp)
        if let win = axCandidateWindows(axApp).first(where: { axCGWindowID($0) == windowID }) {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
    }
    // macOS 14+ : activateIgnoringOtherApps does nothing. activate(from:) is the replacement.
    _ = app.activate(from: NSRunningApplication.current)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        _ = app.activate()
    }
}

/// Take the screen for a global (real-pointer) action, and say whether we did.
/// Global must own the screen, so unlike `maybeActivate` this does not wait for
/// `--activate`: `--global` is itself the explicit opt-in. 200ms matches
/// `isolateCmd`; a shorter wait let the click fire before the window was
/// frontmost, so the first click only activated it.
///
/// Returns false when the app is not frontmost or the captured window is not on
/// this Space. Callers must abort rather than post the event: this path skips
/// the off-Space guard, so an unverified click hits an unrelated application.
func takeControl(pid: pid_t?, windowID: CGWindowID) -> Bool {
    guard let pid, pid != 0 else { return false }
    raiseTargetWindow(pid: pid, windowID: windowID)
    usleep(200_000)
    let appFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    let windowHere = windowID == 0 || cgWindowIsOnScreen(windowID)
    return appFront && windowHere
}

func targetWindowID() -> CGWindowID {
    UInt32(arg("wid") ?? "") ?? 0
}

/// Codex stamps CGEvents with a window id so Mail’s key compose does not eat
/// events meant for Envoyés (same screen rect, different CGWindowID).
func stampTarget(_ ev: CGEvent, pid: pid_t?) {
    if let pid, pid != 0 {
        ev.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
    }
    let wid = targetWindowID()
    if wid != 0 {
        ev.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(wid))
        ev.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(wid))
        if let field = CGEventField(rawValue: 51) {
            ev.setIntegerValueField(field, value: Int64(wid))
        }
    }
}

func post(_ ev: CGEvent, pid: pid_t?) {
    stampTarget(ev, pid: pid)
    if let pid, pid != 0 {
        ev.postToPid(pid)
    } else {
        ev.post(tap: .cghidEventTap)
    }
}

/// Carbon PSN layout. Used with SkyLight `SLPSPostEventRecordTo`.
struct CPSProcessSerialNumber {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

/// Codex `SetFrontProcessOptions` (disassembled from Sky).
let kCPSNoWindows: UInt32 = 0x400

/// Codex `NSEventSubtype` CPS notify values (disassembled from Sky).
let kCPSNotifyKeyFocusTaken: Int16 = Int16(bitPattern: 0x4000)
let kCPSNotifyKeyFocusReturned: Int16 = Int16(bitPattern: 0x8000)

struct SyntheticKeyResult {
    var mode: String = "none"
    var axHasWindow: Bool = false
}

var lastSyntheticKey = SyntheticKeyResult()

func skyLightHandle() -> UnsafeMutableRawPointer? {
    let def = UnsafeMutableRawPointer(bitPattern: -2)
    if let def, dlsym(def, "SLPSPostEventRecordTo") != nil { return def }
    return dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_NOW
    )
}

func slsMainConnectionID() -> Int32 {
    typealias Fn = @convention(c) () -> Int32
    guard let handle = skyLightHandle(), let sym = dlsym(handle, "SLSMainConnectionID") else { return 0 }
    return unsafeBitCast(sym, to: Fn.self)()
}

func slsSpacesForWindow(_ wid: CGWindowID) -> [UInt64] {
    guard wid != 0 else { return [] }
    typealias Fn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    guard let handle = skyLightHandle(), let sym = dlsym(handle, "SLSCopySpacesForWindows") else {
        return []
    }
    let fn = unsafeBitCast(sym, to: Fn.self)
    let arr = [NSNumber(value: wid)] as CFArray
    guard let cf = fn(slsMainConnectionID(), 7, arr)?.takeRetainedValue() else { return [] }
    var out: [UInt64] = []
    for i in 0..<CFArrayGetCount(cf) {
        let p = CFArrayGetValueAtIndex(cf, i)
        let num = Unmanaged<NSNumber>.fromOpaque(p!).takeUnretainedValue()
        out.append(num.uint64Value)
    }
    return out
}

@discardableResult
func slsMoveWindows(_ wids: [CGWindowID], to sid: UInt64) -> String {
    guard sid != 0, !wids.isEmpty else { return "skip" }
    let cid = slsMainConnectionID()
    let nums = wids.map { NSNumber(value: $0) } as CFArray
    var via = ""
    if let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") {
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithWindows:spaceID:")
        if let allocObj = (cls as AnyObject).perform(allocSel)?.takeUnretainedValue() {
            typealias InitFn = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?
            if let method = class_getInstanceMethod(cls, initSel) {
                let fn = unsafeBitCast(method_getImplementation(method), to: InitFn.self)
                if let op = fn(allocObj, initSel, wids.map { NSNumber(value: $0) } as NSArray, sid)?
                    .takeRetainedValue(),
                    let handle = skyLightHandle(),
                    let sym = dlsym(handle, "SLSPerformAsynchronousBridgedWindowManagementOperation")
                {
                    typealias Run = @convention(c) (AnyObject) -> Int64
                    _ = unsafeBitCast(sym, to: Run.self)(op)
                    via = "bridged"
                }
            }
        }
    }
    if via.isEmpty, let handle = skyLightHandle(),
       let sym = dlsym(handle, "SLSMoveWindowsToManagedSpace")
    {
        typealias Fn = @convention(c) (Int32, CFArray, UInt64) -> Void
        unsafeBitCast(sym, to: Fn.self)(cid, nums, sid)
        via = "sls"
    }
    usleep(80_000)
    return via.isEmpty ? "none" : via
}

/// Mail New Message is born on the *current* Space. Park it on the driven window's Space
/// without calling SLSManagedDisplaySetCurrentSpace (that would switch).
func parkOnScreenWindows(pid: pid_t, likeWid: CGWindowID) -> [String: Any] {
    let dest = slsSpacesForWindow(likeWid)
    guard let sid = dest.first, sid != 0 else {
        return ["ok": false, "error": "no space for wid \(likeWid)"]
    }
    var moved: [UInt32] = []
    var stillOn: [UInt32] = []
    var via = ""
    for info in cgWindowInfos(onScreenOnly: false) {
        let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        guard owner == pid else { continue }
        let n = UInt32((info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0)
        guard n != 0, n != likeWid else { continue }
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        guard layer == 0 else { continue }
        if cgWindowIsOnScreen(n), slsSpacesForWindow(n).first != sid {
            via = slsMoveWindows([n], to: sid)
            moved.append(n)
            if cgWindowIsOnScreen(n) { stillOn.append(n) }
        }
    }
    if !stillOn.isEmpty {
        // SLSProcessAssignToSpace returns 0 under SIP but does not move the window;
        // it can make Mail the front app. Do not call it.
    }
    return [
        "ok": stillOn.isEmpty,
        "dest_space": sid,
        "moved": moved,
        "still_on_screen": stillOn,
        "via": via,
    ]
}

func parkCmd() throws {
    guard let pid = optionalPid() else { throw HelperError.usage("park --pid N --wid SOURCE") }
    let like = targetWindowID()
    guard like != 0 else { throw HelperError.usage("park --wid SOURCE") }
    try printJSON(parkOnScreenWindows(pid: pid, likeWid: like))
}

func psnForPid(_ pid: pid_t) -> CPSProcessSerialNumber? {
    typealias Fn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    let rtld = UnsafeMutableRawPointer(bitPattern: -2)
    guard let rtld, let sym = dlsym(rtld, "GetProcessForPID") else { return nil }
    let fn = unsafeBitCast(sym, to: Fn.self)
    var psn = CPSProcessSerialNumber()
    let ok = withUnsafeMutableBytes(of: &psn) { buf -> Bool in
        guard let base = buf.baseAddress else { return false }
        return fn(pid, base) == 0
    }
    return ok ? psn : nil
}

func slpsPostEventRecord(_ psn: inout CPSProcessSerialNumber, _ bytes: inout [UInt8]) {
    typealias Fn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32
    guard let handle = skyLightHandle(), let sym = dlsym(handle, "SLPSPostEventRecordTo") else {
        return
    }
    let fn = unsafeBitCast(sym, to: Fn.self)
    withUnsafeMutableBytes(of: &psn) { psnBuf in
        guard let psnBase = psnBuf.baseAddress else { return }
        bytes.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = fn(psnBase, base)
        }
    }
}

func slpsSetFrontProcess(pid: pid_t, windowID: CGWindowID, options: UInt32) -> Bool {
    typealias Fn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    guard var psn = psnForPid(pid),
          let handle = skyLightHandle(),
          let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return false }
    let fn = unsafeBitCast(sym, to: Fn.self)
    return withUnsafeMutableBytes(of: &psn) { buf -> Bool in
        guard let base = buf.baseAddress else { return false }
        return fn(base, windowID, options) == 0
    }
}

func slpsWriteWindowID(_ bytes: inout [UInt8], _ windowID: CGWindowID) {
    let le = windowID.littleEndian
    withUnsafeBytes(of: le) { raw in
        for i in 0..<4 { bytes[0x3c + i] = raw[i] }
    }
}

/// yabai `window_manager_make_key_window` — session-annotated key/resign pair.
func slpsMakeKeyWindow(pid: pid_t, windowID: CGWindowID) {
    guard var psn = psnForPid(pid), windowID != 0 else { return }
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    slpsWriteWindowID(&bytes, windowID)
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    bytes[0x08] = 0x01
    slpsPostEventRecord(&psn, &bytes)
    bytes[0x08] = 0x02
    slpsPostEventRecord(&psn, &bytes)
}

/// yabai `window_manager_focus_window_without_raise` key-focus records (no SetFrontProcess).
func slpsNotifyWindowKeyFocus(pid: pid_t, from fromID: CGWindowID, to toID: CGWindowID) {
    guard var psn = psnForPid(pid), toID != 0 else { return }
    func record(_ wid: CGWindowID, returned: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x0d
        bytes[0x8a] = returned ? 0x01 : 0x02
        slpsWriteWindowID(&bytes, wid)
        return bytes
    }
    if fromID != 0, fromID != toID {
        var lost = record(fromID, returned: false)
        slpsPostEventRecord(&psn, &lost)
        usleep(40_000)
    }
    var got = record(toID, returned: true)
    slpsPostEventRecord(&psn, &got)
}

/// Codex `notifyAppActivated` / key-focus: `NSEventTypeAppKitDefined` (13) posted to the pid.
func postAppKitDefined(pid: pid_t, windowID: CGWindowID, subtype: Int16, flags: UInt = 0xC0000) {
    guard let ns = NSEvent.otherEvent(
        with: .appKitDefined,
        location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: Int(windowID),
        context: nil,
        subtype: subtype,
        data1: 0,
        data2: 0
    ), let ev = ns.cgEvent else { return }
    post(ev, pid: pid)
}

func axFocusedWindowID(_ pid: pid_t) -> CGWindowID {
    let app = AXUIElementCreateApplication(pid)
    guard let focused = axCopy(app, kAXFocusedWindowAttribute as String) else { return 0 }
    return axCGWindowID(focused as! AXUIElement) ?? 0
}

func cgWindowIsOnScreen(_ wid: CGWindowID) -> Bool {
    guard wid != 0 else { return false }
    for info in cgWindowInfos(onScreenOnly: true) {
        let n = info[kCGWindowNumber as String] as? Int ?? 0
        if UInt32(n) == wid { return true }
    }
    return false
}

func axHasWindowID(_ pid: pid_t, _ wid: CGWindowID) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    axEnableIfNeeded(app)
    return axCandidateWindows(app).contains { axCGWindowID($0) == wid }
}

func restoreFrontSoft(pid: pid_t) {
    guard pid != 0 else { return }
    if slpsSetFrontProcess(pid: pid, windowID: 0, options: kCPSNoWindows) { return }
    if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
        _ = app.activate()
    }
}

/// Give `--wid` key *inside* that pid (Codex notifyAppActivated + SLPS records).
/// Never SetFrontProcess: that steals the keyboard even with kCPSNoWindows.
func ensureSyntheticKey(pid: pid_t) {
    let wid = targetWindowID()
    guard pid != 0, wid != 0 else { return }
    let fromID = axFocusedWindowID(pid)

    postAppKitDefined(pid: pid, windowID: wid, subtype: 1, flags: 0xC0000)
    postAppKitDefined(pid: pid, windowID: wid, subtype: kCPSNotifyKeyFocusTaken)
    postAppKitDefined(pid: pid, windowID: wid, subtype: kCPSNotifyKeyFocusReturned)
    slpsNotifyWindowKeyFocus(pid: pid, from: fromID, to: wid)
    slpsMakeKeyWindow(pid: pid, windowID: wid)
    usleep(30_000)

    var mode = "events"
    if psnForPid(pid) == nil { mode += "-nopsn" }
    lastSyntheticKey = SyntheticKeyResult(
        mode: mode,
        axHasWindow: axHasWindowID(pid, wid)
    )
}

/// After a drive command: if Mail (etc.) took the keyboard, give it back without AXRaise.
func restoreIfWeStoleFront(targetPid: pid_t?) {
    if keepTargetFront() { return }
    guard let restore = restorePidArg(), restore != 0 else { return }
    guard let current = NSWorkspace.shared.frontmostApplication, !isOurApp(current) else { return }
    if sameApp(current, pid: restore) { return }
    if userTookOver(restorePid: restore, targetPid: targetPid) != nil { return }
    guard let t = targetPid, sameApp(current, pid: t) else { return }
    let wid = targetWindowID()
    if wid != 0, !cgWindowIsOnScreen(wid) {
        restoreFrontSoft(pid: restore)
        return
    }
    activate(pid: restore)
}

func mouseParts(_ button: String) -> (CGMouseButton, CGEventType, CGEventType) {
    switch button {
    case "right": return (.right, .rightMouseDown, .rightMouseUp)
    case "middle": return (.center, .otherMouseDown, .otherMouseUp)
    default: return (.left, .leftMouseDown, .leftMouseUp)
    }
}

func makeMouseEvent(
    _ type: CGEventType,
    _ point: CGPoint,
    button: CGMouseButton,
    clickCount: Int64 = 1
) -> CGEvent? {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let ev = CGEvent(
        mouseEventSource: src,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: button
    ) else { return nil }
    ev.setIntegerValueField(CGEventField.mouseEventClickState, value: clickCount)
    ev.location = point
    return ev
}

func postMouse(
    _ type: CGEventType,
    _ point: CGPoint,
    button: CGMouseButton,
    clickCount: Int64,
    pid: pid_t?
) {
    guard let ev = makeMouseEvent(type, point, button: button, clickCount: clickCount) else { return }
    post(ev, pid: pid)
}

func frameUsable(_ p: CGPoint, _ s: CGSize) -> Bool {
    s.width > 1 && s.height > 1 && s.width < 8000 && s.height < 8000
        && abs(p.x) < 20_000 && abs(p.y) < 20_000
}

/// Click inside one process. Does not move the real pointer or activate the app.
func pidClick(x: Double, y: Double, button: String, count: Int, pid: pid_t) {
    let pt = CGPoint(x: x, y: y)
    let (btn, down, up) = mouseParts(button)
    postMouse(.mouseMoved, pt, button: .left, clickCount: 1, pid: pid)
    usleep(12_000)
    for i in 1...max(1, count) {
        postMouse(down, pt, button: btn, clickCount: Int64(i), pid: pid)
        usleep(12_000)
        postMouse(up, pt, button: btn, clickCount: Int64(i), pid: pid)
        if i < count { usleep(80_000) }
    }
}

func hidClick(x: Double, y: Double, button: String, count: Int, pid: pid_t?) {
    maybeActivate(pid: pid)
    let pt = CGPoint(x: x, y: y)
    let (btn, downT, upT) = mouseParts(button)
    guard let move = makeMouseEvent(.mouseMoved, pt, button: .left) else { return }
    move.post(tap: .cghidEventTap)
    usleep(20_000)
    for i in 1...max(1, count) {
        makeMouseEvent(downT, pt, button: btn, clickCount: Int64(i))?.post(tap: .cghidEventTap)
        usleep(12_000)
        makeMouseEvent(upT, pt, button: btn, clickCount: Int64(i))?.post(tap: .cghidEventTap)
        if i < count { usleep(80_000) }
    }
    usleep(60_000)
}

func click(x: Double, y: Double, button: String, count: Int, pid: pid_t?) throws {
    if wantsGlobal() {
        guard takeControl(pid: pid, windowID: targetWindowID()) else {
            throw HelperError.failed(
                "global click aborted: could not bring the captured window to this Space "
                    + "(activation refused, focus changed, or the window is not visible here). "
                    + "Nothing was clicked. Re-check with get_app_state, or use the pid/AX path."
            )
        }
        hidClick(x: x, y: y, button: button, count: count, pid: pid)
        try printJSON(["ok": true, "via": "global", "raised": true])
        return
    }
    if let pid, pid != 0 {
        ensureSyntheticKey(pid: pid)
        pidClick(x: x, y: y, button: button, count: count, pid: pid)
        try printJSON(["ok": true, "via": "pid"])
        return
    }
    try refuseHidOffspace(pid: pid)
    hidClick(x: x, y: y, button: button, count: count, pid: pid)
    try printJSON(["ok": true, "via": "hid"])
}

/// Real-pointer drag at `.cghidEventTap`. Shared by the no-pid path and `--global`.
func hidDrag(from start: CGPoint, to end: CGPoint) {
    let steps = 12
    makeMouseEvent(.leftMouseDown, start, button: .left)?.post(tap: .cghidEventTap)
    usleep(20_000)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        makeMouseEvent(.leftMouseDragged, p, button: .left)?.post(tap: .cghidEventTap)
        usleep(8_000)
    }
    makeMouseEvent(.leftMouseUp, end, button: .left)?.post(tap: .cghidEventTap)
}

func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, pid: pid_t?) throws {
    let start = CGPoint(x: fromX, y: fromY)
    let end = CGPoint(x: toX, y: toY)
    let steps = 12
    if wantsGlobal() {
        guard takeControl(pid: pid, windowID: targetWindowID()) else {
            throw HelperError.failed(
                "global drag aborted: could not bring the captured window to this Space "
                    + "(activation refused, focus changed, or the window is not visible here). "
                    + "Nothing was dragged. Re-check with get_app_state, or use the pid path."
            )
        }
        hidDrag(from: start, to: end)
        try printJSON(["ok": true, "via": "global", "raised": true])
        return
    }
    if let pid, pid != 0 {
        ensureSyntheticKey(pid: pid)
        postMouse(.leftMouseDown, start, button: .left, clickCount: 1, pid: pid)
        usleep(20_000)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: fromX + (toX - fromX) * t, y: fromY + (toY - fromY) * t)
            postMouse(.leftMouseDragged, p, button: .left, clickCount: 1, pid: pid)
            usleep(8_000)
        }
        postMouse(.leftMouseUp, end, button: .left, clickCount: 1, pid: pid)
        try printJSON(["ok": true, "via": "pid"])
        return
    }
    try refuseHidOffspace(pid: pid)
    maybeActivate(pid: pid)
    hidDrag(from: start, to: end)
    try printJSON(["ok": true, "via": "hid"])
}

func pidScroll(x: Double, y: Double, dy: Int32, pid: pid_t) -> Bool {
    ensureSyntheticKey(pid: pid)
    let pt = CGPoint(x: x, y: y)
    postMouse(.mouseMoved, pt, button: .left, clickCount: 1, pid: pid)
    usleep(12_000)
    let src = CGEventSource(stateID: .hidSystemState)
    let sign: Int32 = dy >= 0 ? 1 : -1
    let ticks = max(3, min(30, abs(Int(dy)) / 24))
    var ok = false
    for _ in 0..<ticks {
        guard let ev = CGEvent(
            scrollWheelEvent2Source: src,
            units: .line,
            wheelCount: 1,
            wheel1: 3 * sign,
            wheel2: 0,
            wheel3: 0
        ) else { continue }
        ev.location = pt
        post(ev, pid: pid)
        ok = true
        usleep(16_000)
    }
    return ok
}

func hidScroll(x: Double, y: Double, dy: Int32, pid: pid_t?) {
    maybeActivate(pid: pid)
    let pt = CGPoint(x: x, y: y)
    makeMouseEvent(.mouseMoved, pt, button: .left)?.post(tap: .cghidEventTap)
    usleep(30_000)
    let src = CGEventSource(stateID: .hidSystemState)
    let sign: Int32 = dy >= 0 ? 1 : -1
    let ticks = max(3, min(30, abs(Int(dy)) / 24))
    for _ in 0..<ticks {
        guard let ev = CGEvent(
            scrollWheelEvent2Source: src,
            units: .line,
            wheelCount: 1,
            wheel1: 3 * sign,
            wheel2: 0,
            wheel3: 0
        ) else { continue }
        ev.location = pt
        ev.post(tap: .cghidEventTap)
        usleep(16_000)
    }
}

let keyMap: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "=": 24, "9": 25, "7": 26,
    "minus": 27, "-": 27, "8": 28, "0": 29, "rightbracket": 30, "]": 30, "o": 31,
    "u": 32, "leftbracket": 33, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36,
    "l": 37, "j": 38, "quote": 39, "'": 39, "k": 40, "semicolon": 41, ";": 41,
    "backslash": 42, "\\": 42, "comma": 43, ",": 43, "slash": 44, "/": 44, "n": 45,
    "m": 46, "period": 47, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51,
    "escape": 53, "esc": 53, "command": 55, "cmd": 55, "shift": 56, "capslock": 57,
    "option": 58, "alt": 58, "control": 59, "ctrl": 59, "function": 63, "fn": 63,
    "rightshift": 60, "rightoption": 61, "rightcontrol": 62,
    "f17": 64, "volumeup": 72, "volumedown": 73, "mute": 74, "f18": 79, "f19": 80,
    "f20": 90, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101,
    "f11": 103, "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111,
    "f15": 113, "help": 114, "home": 115, "pageup": 116, "forwarddelete": 117,
    "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122,
    "left": 123, "right": 124, "down": 125, "up": 126,
]

func flagsFrom(_ names: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    for n in names {
        switch n {
        case "cmd", "command", "super": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "alt", "option": f.insert(.maskAlternate)
        case "ctrl", "control": f.insert(.maskControl)
        case "fn", "function": f.insert(.maskSecondaryFn)
        default: break
        }
    }
    return f
}

func pressKey(spec: String, pid: pid_t?) throws {
    maybeActivate(pid: pid)
    if let pid { ensureSyntheticKey(pid: pid) }
    let parts = spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard let last = parts.last else { throw HelperError.usage("empty key") }
    let mods = Array(parts.dropLast())
    guard let code = keyMap[last] else {
        throw HelperError.usage("unknown key \(last)")
    }
    let src = CGEventSource(stateID: .hidSystemState)
    let flags = flagsFrom(mods)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    if let down { post(down, pid: pid) }
    usleep(8_000)
    if let up { post(up, pid: pid) }
    print("{\"ok\":true,\"via\":\"pid\"}")
}

func typeText(_ text: String, pid: pid_t?) {
    maybeActivate(pid: pid)
    if let pid { ensureSyntheticKey(pid: pid) }
    if let idx = Int(arg("index") ?? ""), let pid {
        if let el = try? axElement(index: idx, pid: pid, titleHint: arg("title")) {
            _ = axFocus(el)
            let role = axString(el, kAXRoleAttribute as String)
            if role == "AXWebArea" || role == "AXTextArea" || role == "AXGroup" {
                postAppKitDefined(pid: pid, windowID: targetWindowID(), subtype: kCPSNotifyKeyFocusReturned)
                if let p = axCGPoint(el), let s = axCGSize(el), frameUsable(p, s) {
                    let cx = p.x + min(s.width / 2, 280)
                    let cy = p.y + min(160, max(24, s.height / 4))
                    pidClick(x: cx, y: cy, button: "left", count: 1, pid: pid)
                }
            }
            usleep(30_000)
        }
    }
    // Codex type_text: unicode key events to the pid, not a global Cmd+V.
    let src = CGEventSource(stateID: .hidSystemState)
    for scalar in text.unicodeScalars {
        if scalar == "\n" || scalar == "\r" {
            let code: CGKeyCode = 36
            let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
            if let d { post(d, pid: pid) }
            usleep(8_000)
            if let u { post(u, pid: pid) }
            continue
        }
        let utf16 = Array(String(scalar).utf16)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        utf16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            down?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
            up?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
        }
        if let down { post(down, pid: pid) }
        usleep(4_000)
        if let up { post(up, pid: pid) }
        usleep(4_000)
    }
    print("{\"ok\":true,\"via\":\"pid-unicode\"}")
}

func arg(_ name: String) -> String? {
    let args = currentArgv
    if let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count {
        return args[i + 1]
    }
    return nil
}

func requireDouble(_ name: String) throws -> Double {
    guard let s = arg(name), let v = Double(s) else {
        throw HelperError.usage("missing --\(name)")
    }
    return v
}

func optionalPid() -> pid_t? {
    if let s = arg("pid"), let v = Int32(s) { return v }
    return nil
}

func screenshot() throws {
    guard let out = arg("out"), !out.isEmpty else {
        throw HelperError.usage("screenshot --out PATH")
    }
    let maxEdge = Int(arg("max-edge") ?? "1280") ?? 1280
    let quality = max(0.15, min(0.95, (Double(arg("quality") ?? "72") ?? 72) / 100.0))
    let wid = arg("id").flatMap { UInt32($0) } ?? 0
    var image: CGImage?
    var via = "screencapture"
    if wid != 0 {
        do {
            image = try captureWindowSCK(wid)
            via = "sck"
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw error
            }
        }
    }
    if image == nil {
        if !CGPreflightScreenCaptureAccess() {
            throw HelperError.failed(
                "Screen Recording is not bound to this helper process. Enable it for \(ourDisplayName()), then quit and relaunch the helper."
            )
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-custom-computer-use-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if wid != 0 {
            proc.arguments = ["-l", String(wid), "-x", "-o", "-t", "png", tmp.path]
        } else {
            let x = Int(try requireDouble("x"))
            let y = Int(try requireDouble("y"))
            let w = Int(try requireDouble("w"))
            let h = Int(try requireDouble("h"))
            proc.arguments = ["-R", "\(x),\(y),\(w),\(h)", "-x", "-o", "-t", "png", tmp.path]
        }
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tmp.path),
              let ns = NSImage(contentsOf: tmp),
              let cg = cgImage(from: ns) else {
            throw HelperError.failed(
                "Screenshot failed. Grant Screen Recording to \(ourDisplayName()).app, then relaunch the helper."
            )
        }
        image = cg
        via = "screencapture"
    }
    guard let image else {
        throw HelperError.failed("Screenshot empty")
    }
    let resized = scale(image, maxEdge: maxEdge)
    let rep = NSBitmapImageRep(cgImage: resized)
    guard let data = rep.representation(
        using: .jpeg,
        properties: [.compressionFactor: quality]
    ) else {
        throw HelperError.failed("JPEG encode failed")
    }
    try data.write(to: URL(fileURLWithPath: out), options: .atomic)
    print("{\"ok\":true,\"w\":\(resized.width),\"h\":\(resized.height),\"via\":\"\(via)\"}")
}

func cgImage(from ns: NSImage) -> CGImage? {
    var rect = NSRect(origin: .zero, size: ns.size)
    return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

func axTrusted() throws {
    if !AXIsProcessTrusted() {
        throw HelperError.failed(
            "Accessibility not granted for \(ourDisplayName())."
        )
    }
}

/// Codex `AXEnablementAssertion`: ask the app to publish a full AX tree.
func axEnableIfNeeded(_ app: AXUIElement) {
    _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
}

/// `_AXUIElementGetWindow` — same SPI Codex uses to join AX windows to CGWindowIDs.
func axCGWindowID(_ el: AXUIElement) -> CGWindowID? {
    typealias Fn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
    let handle = UnsafeMutableRawPointer(bitPattern: -2)
    guard let handle, let sym = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
    let fn = unsafeBitCast(sym, to: Fn.self)
    var ident: CGWindowID = 0
    let err = fn(el, &ident)
    return (err == 0 && ident != 0) ? ident : nil
}

func axCopy(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var val: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &val)
    guard err == .success else { return nil }
    return val
}

func axString(_ el: AXUIElement, _ name: String) -> String {
    guard let val = axCopy(el, name) else { return "" }
    if let s = val as? String { return s }
    return ""
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    guard let val = axCopy(el, kAXChildrenAttribute as String) else { return [] }
    return axUIElements(val)
}

func axUIElements(_ val: CFTypeRef) -> [AXUIElement] {
    if let arr = val as? [AXUIElement] { return arr }
    guard CFGetTypeID(val) == CFArrayGetTypeID() else { return [] }
    let cf = val as! CFArray
    let n = CFArrayGetCount(cf)
    var out: [AXUIElement] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let p = CFArrayGetValueAtIndex(cf, i)
        out.append(unsafeBitCast(p, to: AXUIElement.self))
    }
    return out
}

func axCGPoint(_ el: AXUIElement) -> CGPoint? {
    guard let val = axCopy(el, kAXPositionAttribute as String) else { return nil }
    guard CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(val as! AXValue, .cgPoint, &point)
    return point
}

func axCGSize(_ el: AXUIElement) -> CGSize? {
    guard let val = axCopy(el, kAXSizeAttribute as String) else { return nil }
    guard CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    AXValueGetValue(val as! AXValue, .cgSize, &size)
    return size
}

func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    let err = AXUIElementCopyActionNames(el, &names)
    guard err == .success, let names else { return [] }
    return (names as? [String]) ?? []
}

func axTruncate(_ s: String, _ n: Int) -> String {
    if s.count <= n { return s }
    return String(s.prefix(n)) + "…"
}

func axQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func axNorm(_ s: String) -> String {
    let folded = s.lowercased()
        .replacingOccurrences(of: #"[\p{Pd}]"#, with: " ", options: .regularExpression)
        .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
    return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func axLooksLikeMailbox(_ title: String) -> Bool {
    let t = axNorm(title)
    let keys = [
        "envoyes", "inbox", "boite de reception", "brouillons", "drafts",
        "sent", "archives", "indesirables", "corbeille", "junk", "trash",
    ]
    return keys.contains { t.contains($0) }
}

func axLooksLikeCompose(_ title: String) -> Bool {
    let t = axNorm(title)
    return t.contains("nouveau") || t.contains("new message")
}

func axWindowsOf(_ app: AXUIElement) -> [AXUIElement] {
    axEnableIfNeeded(app)
    if let windows = axCopy(app, kAXWindowsAttribute as String) {
        let list = axUIElements(windows)
        if !list.isEmpty { return list }
    }
    var found: [AXUIElement] = []
    func collect(_ el: AXUIElement, depth: Int) {
        if found.count >= 32 || depth > 4 { return }
        let role = axString(el, kAXRoleAttribute as String)
        if role == "AXMenuBar" || role == "AXMenu" { return }
        if depth > 0, role == "AXWindow" || role == "AXStandardWindow" {
            found.append(el)
            return
        }
        for child in axChildren(el) {
            collect(child, depth: depth + 1)
        }
    }
    collect(app, depth: 0)
    return found
}

func axCandidateWindows(_ app: AXUIElement) -> [AXUIElement] {
    var out = axWindowsOf(app)
    if let focused = axCopy(app, kAXFocusedWindowAttribute as String) {
        out.append(focused as! AXUIElement)
    }
    if let main = axCopy(app, kAXMainWindowAttribute as String) {
        out.append(main as! AXUIElement)
    }
    return out
}

func axWindowTitles(_ app: AXUIElement) -> [String] {
    var seen = Set<String>()
    var titles: [String] = []
    for w in axCandidateWindows(app) {
        let t = axString(w, kAXTitleAttribute as String)
        if t.isEmpty || seen.contains(t) { continue }
        seen.insert(t)
        titles.append(t)
    }
    return titles
}

func axWindowFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = axCGPoint(el), let s = axCGSize(el), s.width > 40, s.height > 40 else { return nil }
    return CGRect(x: p.x, y: p.y, width: s.width, height: s.height)
}

func axTitleMatches(_ title: String, hint: String) -> Bool {
    let nt = axNorm(title)
    let nh = axNorm(hint)
    if nt.isEmpty || nh.isEmpty { return false }
    if !axLooksLikeCompose(hint), axLooksLikeCompose(title) { return false }
    if nt.contains(nh) || nh.contains(nt) { return true }
    if let first = nh.split(separator: " ").map(String.init).first, first.count >= 4, nt.contains(first) {
        return true
    }
    return false
}

func axPickWindow(app: AXUIElement, titleHint: String?) -> AXUIElement {
    let windows = axCandidateWindows(app)
    let hint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let wid = targetWindowID()
    if wid != 0 {
        for w in windows {
            if axCGWindowID(w) == wid { return w }
        }
    }
    if !hint.isEmpty {
        for w in windows {
            if axTitleMatches(axString(w, kAXTitleAttribute as String), hint: hint) { return w }
        }
        if !axLooksLikeMailbox(hint), let focused = axCopy(app, kAXFocusedWindowAttribute as String) {
            return focused as! AXUIElement
        }
        return app
    }
    if let wx = Double(arg("wx") ?? ""), let wy = Double(arg("wy") ?? ""),
       let ww = Double(arg("ww") ?? ""), let wh = Double(arg("wh") ?? ""), ww > 40, wh > 40 {
        let target = CGRect(x: wx, y: wy, width: ww, height: wh)
        var best: (CGFloat, AXUIElement)?
        for w in windows {
            guard let r = axWindowFrame(w) else { continue }
            let inter = r.intersection(target)
            let score = inter.width * inter.height
            if score > 40 * 40, best == nil || score > best!.0 {
                best = (score, w)
            }
        }
        if let best { return best.1 }
    }
    if let focused = axCopy(app, kAXFocusedWindowAttribute as String) {
        return focused as! AXUIElement
    }
    if let first = windows.first { return first }
    return app
}

func axChromePriority(_ el: AXUIElement) -> Int {
    let role = axString(el, kAXRoleAttribute as String)
    switch role {
    case "AXToolbar", "AXMenuBar": return 0
    case "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
         "AXTextField", "AXSearchField": return 1
    case "AXGroup": return 2
    case "AXSplitGroup": return 4
    case "AXScrollArea", "AXOutline", "AXTable", "AXWebArea": return 6
    default: return 3
    }
}

/// Mail outlines can have thousands of rows. Asking every child's role so we
/// can sort chrome-first is what made ax-dump hit the 35s socket timeout.
func axWalkChildren(_ el: AXUIElement, role: String) -> [AXUIElement] {
    let raw = axChildren(el)
    if role == "AXOutline" || role == "AXTable" || role == "AXList" {
        if raw.count > 24 {
            return Array(raw.prefix(16)) + Array(raw.suffix(4))
        }
        return raw
    }
    if raw.count <= 1 { return raw }
    return raw.sorted { axChromePriority($0) < axChromePriority($1) }
}

func axWalk(pid: pid_t, titleHint: String?, maxNodes: Int, maxDepth: Int) throws -> (lines: [String], elements: [AXUIElement]) {
    try axTrusted()
    ensureSyntheticKey(pid: pid)
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    axEnableIfNeeded(app)
    let root = axPickWindow(app: app, titleHint: titleHint)
    let hint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let rootRole = axString(root, kAXRoleAttribute as String)
    if !hint.isEmpty, rootRole == "AXApplication" {
        let focused: String
        if let el = axCopy(app, kAXFocusedWindowAttribute as String) {
            focused = axString(el as! AXUIElement, kAXTitleAttribute as String)
        } else {
            focused = ""
        }
        let titles = axWindowTitles(app).joined(separator: ", ")
        let line = "# ax_mismatch hint=\(axQuote(hint)) focused=\(axQuote(focused)) ax_windows=\(axQuote(titles))"
        return ([line], [])
    }
    var lines: [String] = []
    var elements: [AXUIElement] = []

    func visit(_ el: AXUIElement, depth: Int) {
        if elements.count >= maxNodes || depth > maxDepth { return }
        let role = axString(el, kAXRoleAttribute as String)
        if role.isEmpty && depth > 0 { return }
        let title = axTruncate(axString(el, kAXTitleAttribute as String), 80)
        let skipValue = role == "AXWebArea" || role == "AXOutline" || role == "AXTable"
        let value = skipValue ? "" : axTruncate(axString(el, kAXValueAttribute as String), 80)
        let desc = axTruncate(axString(el, kAXDescriptionAttribute as String), 80)
        let allActions = axActions(el)
        let showAll = role == "AXButton" || role == "AXMenuButton" || role == "AXPopUpButton"
            || role == "AXCheckBox" || role == "AXToolbar" || role == "AXRow"
            || role == "AXLink" || role == "AXDisclosureTriangle" || role == "AXScrollBar"
        let actions = showAll
            ? allActions
            : allActions.filter { $0.hasPrefix("AXScroll") }
        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)[\(elements.count)] \(role.isEmpty ? "AXUnknown" : role)"
        if !title.isEmpty { line += " title=\(axQuote(title))" }
        if !value.isEmpty, value != title { line += " value=\(axQuote(value))" }
        if !desc.isEmpty, desc != title, desc != value { line += " description=\(axQuote(desc))" }
        if let p = axCGPoint(el), let s = axCGSize(el) {
            line += " @(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))"
        }
        if !actions.isEmpty { line += " actions=\(actions.joined(separator: ","))" }
        lines.append(line)
        elements.append(el)
        for child in axWalkChildren(el, role: role) {
            visit(child, depth: depth + 1)
            if elements.count >= maxNodes { return }
        }
    }
    visit(root, depth: 0)
    return (lines, elements)
}

func axDump() throws {
    guard let pid = optionalPid() else { throw HelperError.usage("ax-dump --pid N") }
    let maxNodes = Int(arg("max") ?? "600") ?? 600
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    let result = try axWalk(pid: pid, titleHint: arg("title"), maxNodes: maxNodes, maxDepth: 18)
    let picked = axPickWindow(app: app, titleHint: arg("title"))
    var focusedTitle = ""
    if let focused = axCopy(app, kAXFocusedWindowAttribute as String) {
        focusedTitle = axString(focused as! AXUIElement, kAXTitleAttribute as String)
    }
    let payload: [String: Any] = [
        "ok": true,
        "count": result.lines.count,
        "picked_title": axString(picked, kAXTitleAttribute as String),
        "picked_role": axString(picked, kAXRoleAttribute as String),
        "window_titles": axWindowTitles(app),
        "focused_title": focusedTitle,
        "window_ids": axCandidateWindows(app).compactMap { el -> String? in
            let t = axString(el, kAXTitleAttribute as String)
            guard let id = axCGWindowID(el) else { return t.isEmpty ? nil : "\(t)=?" }
            return "\(t)=\(id)"
        },
        "synthetic_key": lastSyntheticKey.mode,
        "synthetic_ax_has_window": lastSyntheticKey.axHasWindow,
        "text": result.lines.joined(separator: "\n"),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func axElement(index: Int, pid: pid_t, titleHint: String?) throws -> AXUIElement {
    let result = try axWalk(pid: pid, titleHint: titleHint, maxNodes: 600, maxDepth: 18)
    guard index >= 0, index < result.elements.count else {
        throw HelperError.failed("element_index \(index) out of range 0..<\(result.elements.count). Call get_app_state again.")
    }
    return result.elements[index]
}

func axFocus(_ el: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue as CFBoolean) == .success
}

func axParent(_ el: AXUIElement) -> AXUIElement? {
    guard let val = axCopy(el, kAXParentAttribute as String) else { return nil }
    return (val as! AXUIElement)
}

/// Mail message rows rarely have AXPress. Selecting the AXTable/AXOutline row works off-Space.
func axSelectRow(_ el: AXUIElement) -> Bool {
    var current: AXUIElement? = el
    var row: AXUIElement?
    for _ in 0..<8 {
        guard let node = current else { break }
        let role = axString(node, kAXRoleAttribute as String)
        if role == "AXRow" { row = node }
        if (role == "AXTable" || role == "AXOutline" || role == "AXList"), let row {
            let arr = [row] as CFArray
            if AXUIElementSetAttributeValue(
                node,
                kAXSelectedRowsAttribute as CFString,
                arr
            ) == .success {
                return true
            }
        }
        current = axParent(node)
    }
    return false
}

func axFrameIntersectsWindow(_ el: AXUIElement) -> Bool {
    guard let p = axCGPoint(el), let s = axCGSize(el), s.width > 1, s.height > 1 else { return true }
    let wx = Double(arg("wx") ?? "") ?? p.x
    let wy = Double(arg("wy") ?? "") ?? p.y
    let ww = Double(arg("ww") ?? "") ?? s.width
    let wh = Double(arg("wh") ?? "") ?? s.height
    let er = CGRect(x: p.x, y: p.y, width: s.width, height: s.height)
    let wr = CGRect(x: wx, y: wy, width: ww, height: wh).insetBy(dx: 2, dy: 2)
    return er.intersects(wr)
}

@discardableResult
func axScrollToVisible(_ el: AXUIElement) -> Bool {
    AXUIElementPerformAction(el, "AXScrollToVisible" as CFString) == .success
}

func axClickIndex() throws {
    guard let pid = optionalPid() else { throw HelperError.usage("click --index N --pid P") }
    guard let idx = Int(arg("index") ?? "") else { throw HelperError.usage("click --index N") }
    maybeActivate(pid: pid)
    ensureSyntheticKey(pid: pid)
    let el = try axElement(index: idx, pid: pid, titleHint: arg("title"))
    if !axFrameIntersectsWindow(el) {
        _ = axScrollToVisible(el)
        usleep(40_000)
    }
    let role = axString(el, kAXRoleAttribute as String)
    let actions = axActions(el)
    var via: [String] = []
    if axSelectRow(el) { via.append("AXSelectedRows") }
    if actions.contains("AXPress") {
        if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
            via.append("AXPress")
        }
    }
    if axFocus(el) { via.append("AXFocused") }
    if actions.contains("AXConfirm") {
        if AXUIElementPerformAction(el, kAXConfirmAction as CFString) == .success {
            via.append("AXConfirm")
        }
    }
    if via.contains("AXSelectedRows") {
        try printJSON(["ok": true, "via": via.joined(separator: "+"), "role": role])
        return
    }
    // AXPress already ran. Do not pid-click the element's screen point: that
    // rect often sits on the current Space (Cursor) when the window is off-Space,
    // and AXMenuItem popups are overlay windows on the active Space.
    if via.contains("AXPress") {
        try printJSON(["ok": true, "via": "AXPress", "role": role])
        return
    }
    let button = arg("button") ?? "left"
    let count = Int(arg("count") ?? "1") ?? 1
    if let p = axCGPoint(el), let s = axCGSize(el), frameUsable(p, s) {
        var cx = p.x + s.width / 2
        var cy = p.y + s.height / 2
        if (role == "AXWebArea" || role == "AXScrollArea"), s.height > 160 {
            cy = p.y + min(160, s.height / 4)
            cx = p.x + min(s.width / 2, 280)
        }
        pidClick(x: cx, y: cy, button: button, count: count, pid: pid)
        try printJSON(["ok": true, "via": "pid", "role": role, "ax": via.joined(separator: "+")])
        return
    }
    if !via.isEmpty {
        try printJSON(["ok": true, "via": via.joined(separator: "+"), "role": role, "hid": false])
        return
    }
    throw HelperError.failed(
        "No AX action and no usable frame on \(role) (actions=\(actions.joined(separator: ","))). "
            + "HID would hit the current Space if this window is off-screen."
    )
}

func axSetValue() throws {
    guard let pid = optionalPid() else { throw HelperError.usage("set-value --index N --pid P --text ...") }
    guard let idx = Int(arg("index") ?? "") else { throw HelperError.usage("set-value --index N") }
    guard let text = arg("text") else { throw HelperError.usage("set-value --text ...") }
    maybeActivate(pid: pid)
    ensureSyntheticKey(pid: pid)
    let el = try axElement(index: idx, pid: pid, titleHint: arg("title"))
    _ = axFocus(el)
    let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString)
    if err != .success {
        throw HelperError.failed("set_value failed (\(err.rawValue))")
    }
    print("{\"ok\":true}")
}

func axSecondary() throws {
    guard let pid = optionalPid() else { throw HelperError.usage("ax-action --index N --pid P --action Press") }
    guard let idx = Int(arg("index") ?? "") else { throw HelperError.usage("ax-action --index N") }
    guard let action = arg("action") else { throw HelperError.usage("ax-action --action Name") }
    if action == "AXRaise" || action.lowercased() == "raise" {
        throw HelperError.failed("AXRaise would steal focus. Use isolate_window only if the user accepts that.")
    }
    maybeActivate(pid: pid)
    ensureSyntheticKey(pid: pid)
    let el = try axElement(index: idx, pid: pid, titleHint: arg("title"))
    let err = AXUIElementPerformAction(el, action as CFString)
    if err != .success {
        let available = axActions(el).joined(separator: ", ")
        throw HelperError.failed("action \(action) failed (\(err.rawValue)). Available: \(available)")
    }
    print("{\"ok\":true}")
}

func axPageAction(_ direction: String) -> String {
    switch direction {
    case "up", "u": return "AXScrollUpByPage"
    case "left", "l": return "AXScrollLeftByPage"
    case "right", "r": return "AXScrollRightByPage"
    default: return "AXScrollDownByPage"
    }
}

func axIsVerticalBar(_ el: AXUIElement) -> Bool {
    guard let s = axCGSize(el) else { return true }
    return s.height > s.width + 4
}

/// Direct AXScrollBar children only — do not walk outline rows.
func axDirectScrollBars(_ el: AXUIElement, vertical: Bool) -> [AXUIElement] {
    axChildren(el).filter { child in
        axString(child, kAXRoleAttribute as String) == "AXScrollBar"
            && axIsVerticalBar(child) == vertical
    }
}

func axNearbyScrollBars(_ el: AXUIElement, vertical: Bool) -> [AXUIElement] {
    var bars = axDirectScrollBars(el, vertical: vertical)
    if !bars.isEmpty { return bars }
    if let parent = axParent(el) {
        bars = axDirectScrollBars(parent, vertical: vertical)
        if !bars.isEmpty { return bars }
        if let grand = axParent(parent) {
            return axDirectScrollBars(grand, vertical: vertical)
        }
    }
    return []
}

/// Codex: scroll the named element, or the nearest ancestor that actually scrolls.
func axScrollContainer(from el: AXUIElement) -> AXUIElement {
    var cur: AXUIElement? = el
    var fallback = el
    for _ in 0..<20 {
        guard let node = cur else { break }
        let role = axString(node, kAXRoleAttribute as String)
        let actions = axActions(node)
        let pages = actions.contains { $0.hasPrefix("AXScroll") && $0.hasSuffix("ByPage") }
        if role == "AXScrollArea" || pages
            || !axDirectScrollBars(node, vertical: true).isEmpty
            || !axDirectScrollBars(node, vertical: false).isEmpty {
            return node
        }
        if role == "AXWebArea" || role == "AXOutline" || role == "AXTable" || role == "AXList" {
            fallback = node
        }
        cur = axParent(node)
    }
    return fallback
}

func axBarFingerprint(_ el: AXUIElement, vertical: Bool) -> [Double] {
    axNearbyScrollBars(el, vertical: vertical).compactMap { bar in
        (axCopy(bar, kAXValueAttribute as String) as? NSNumber)?.doubleValue
    }
}

func axChildFingerprint(_ el: AXUIElement) -> String {
    let role = axString(el, kAXRoleAttribute as String)
    let kids = axChildren(el)
    let sample: [AXUIElement]
    if role == "AXOutline" || role == "AXTable" || role == "AXList" {
        sample = Array(kids.prefix(3)) + (kids.count > 3 ? Array(kids.suffix(1)) : [])
    } else {
        sample = Array(kids.prefix(6))
    }
    return sample.map { child in
        let t = axTruncate(axString(child, kAXTitleAttribute as String), 24)
        let p = axCGPoint(child)
        return "\(t):\(Int(p?.y ?? -1))"
    }.joined(separator: ",")
}

func axScrollMoved(beforeBars: [Double], afterBars: [Double], beforeKids: String, afterKids: String) -> Bool {
    if !beforeBars.isEmpty, beforeBars.count == afterBars.count {
        for (a, b) in zip(beforeBars, afterBars) where abs(a - b) > 0.004 {
            return true
        }
    }
    return beforeKids != afterKids && !afterKids.isEmpty
}

func axNudgeScroll(_ el: AXUIElement, direction: String, pages: Int) -> String? {
    _ = axFocus(el)
    let vertical = direction != "left" && direction != "l" && direction != "right" && direction != "r"
    let want = axPageAction(direction)
    if axActions(el).contains(want) {
        var ok = false
        for _ in 0..<max(1, pages) {
            if AXUIElementPerformAction(el, want as CFString) == .success { ok = true }
            usleep(40_000)
        }
        if ok { return "AXScroll" }
    }
    let downOrRight = !(direction == "up" || direction == "u" || direction == "left" || direction == "l")
    for bar in axNearbyScrollBars(el, vertical: vertical) {
        let inc = downOrRight ? "AXIncrement" : "AXDecrement"
        if axActions(bar).contains(inc) {
            var ok = false
            for _ in 0..<(max(1, pages) * 12) {
                if AXUIElementPerformAction(bar, inc as CFString) == .success { ok = true }
                usleep(12_000)
            }
            if ok { return "AXIncrement" }
        }
        if let cur = axCopy(bar, kAXValueAttribute as String) as? NSNumber {
            let delta = 0.35 * Double(max(1, pages))
            let next = downOrRight
                ? min(1.0, cur.doubleValue + delta)
                : max(0.0, cur.doubleValue - delta)
            if AXUIElementSetAttributeValue(
                bar,
                kAXValueAttribute as CFString,
                NSNumber(value: next)
            ) == .success {
                return "AXValue"
            }
        }
    }
    return nil
}

func axScroll() throws {
    guard optionalPid() != nil else { throw HelperError.usage("scroll --index N --pid P --direction down") }
    guard let idx = Int(arg("index") ?? "") else {
        throw HelperError.failed("scroll needs element_index from the last AX tree (list, web area, or a row inside it).")
    }
    let direction = (arg("direction") ?? "down").lowercased()
    var pages = 1
    if let p = Double(arg("pages") ?? ""), p > 0 { pages = max(1, min(6, Int(p.rounded()))) }
    let vertical = direction != "left" && direction != "l" && direction != "right" && direction != "r"
    let el = try axElement(index: idx, pid: optionalPid()!, titleHint: arg("title"))
    let target = axScrollContainer(from: el)
    let beforeBars = axBarFingerprint(target, vertical: vertical)
    let beforeKids = axChildFingerprint(target)

    if let via = axNudgeScroll(target, direction: direction, pages: pages) {
        usleep(50_000)
        let afterBars = axBarFingerprint(target, vertical: vertical)
        let afterKids = axChildFingerprint(target)
        if axScrollMoved(beforeBars: beforeBars, afterBars: afterBars, beforeKids: beforeKids, afterKids: afterKids) {
            try printJSON(["ok": true, "via": via, "pages": pages, "index": idx])
            return
        }
    }

    if let p = axCGPoint(target), let s = axCGSize(target), s.width > 8, s.height > 8, let pid = optionalPid() {
        let x = p.x + s.width * 0.5
        let y = p.y + min(s.height * 0.5, 200)
        let pagePx = max(320, Int((Double(arg("wh") ?? "") ?? s.height) * 0.45))
        var dy = pagePx * pages
        if direction == "down" || direction == "d" { dy = -dy }
        else if direction == "up" || direction == "u" { /* keep positive */ }
        else { dy = 0 }
        if dy != 0 {
            _ = pidScroll(x: x, y: y, dy: Int32(dy), pid: pid)
            usleep(50_000)
            let afterBars = axBarFingerprint(target, vertical: vertical)
            let afterKids = axChildFingerprint(target)
            if axScrollMoved(beforeBars: beforeBars, afterBars: afterBars, beforeKids: beforeKids, afterKids: afterKids) {
                try printJSON(["ok": true, "via": "pid-wheel", "pages": pages, "index": idx])
                return
            }
        }
    }

    throw HelperError.failed(
        "scroll did not move element \(idx) (\(axString(target, kAXRoleAttribute as String))). "
            + "AX page/scrollbar unchanged. For web pages, AXScrollToVisible on a descendant via "
            + "perform_secondary_action is the action that actually brings a node into view."
    )
}

func scale(_ image: CGImage, maxEdge: Int) -> CGImage {
    let srcW = image.width
    let srcH = image.height
    let longest = max(srcW, srcH)
    if longest <= maxEdge { return image }
    let factor = CGFloat(maxEdge) / CGFloat(longest)
    let nw = max(1, Int(CGFloat(srcW) * factor))
    let nh = max(1, Int(CGFloat(srcH) * factor))
    let color = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: nw,
        height: nh,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: color,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return image }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
    return ctx.makeImage() ?? image
}

func printJSON(_ obj: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func userContextCmd() throws {
    let ctx = captureUserContext()
    var payload: [String: Any] = [
        "front_pid": Int(ctx.pid),
        "front_owner": ctx.owner,
        "mouse": [ctx.mouse.x, ctx.mouse.y],
    ]
    if let cur = cursorRunningApp() {
        payload["cursor_pid"] = Int(cur.processIdentifier)
        payload["cursor_owner"] = cur.localizedName ?? "Cursor"
    }
    try printJSON(payload)
}

func restoreFocusCmd() throws {
    let pid = optionalPid() ?? 0
    let x = Double(arg("x") ?? "") ?? mouseLocation().x
    let y = Double(arg("y") ?? "") ?? mouseLocation().y
    let target = arg("target-pid").flatMap { Int32($0) }.map { pid_t($0) }
    let ctx = UserContext(pid: pid, owner: "", mouse: CGPoint(x: x, y: y))
    if let app = userTookOver(restorePid: pid, targetPid: target) {
        try printJSON([
            "ok": true,
            "skipped": true,
            "reason": "user_took_over",
            "front_owner": app.localizedName ?? "",
        ])
        return
    }
    restoreUserContext(ctx, targetPid: target)
    try printJSON(["ok": true, "restored_pid": Int(pid)])
}

func isolateCmd() throws {
    guard let pid = optionalPid() else { throw HelperError.usage("isolate --pid N [--mode raise|fullscreen]") }
    let mode = (arg("mode") ?? "raise").lowercased()
    activate(pid: pid)
    usleep(200_000)
    scCache = nil
    scCacheAt = Date.distantPast
    if mode == "fullscreen" {
        try axTrusted()
        let app = AXUIElementCreateApplication(pid)
        let win = axPickWindow(app: app, titleHint: arg("title"))
        let err = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanTrue as CFBoolean)
        if err != .success {
            throw HelperError.failed("Could not fullscreen (AXFullScreen \(err.rawValue)). Window was still raised.")
        }
    }
    try printJSON([
        "ok": true,
        "mode": mode,
        "pid": Int(pid),
        "stole_focus": true,
        "restored": false,
    ])
}

func doctor() throws {
    let prompt = flag("prompt")
    let trusted: Bool
    if AXIsProcessTrusted() {
        trusted = true
    } else if prompt {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let opts = [promptKey: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    } else {
        trusted = false
    }
    let screenOk = CGPreflightScreenCaptureAccess()
    if prompt, !screenOk {
        _ = CGRequestScreenCaptureAccess()
    }
    let postOk = CGPreflightPostEventAccess()
    if prompt, !postOk {
        _ = CGRequestPostEventAccess()
    }
    let raw = cgWindowInfos(onScreenOnly: true)
    var owners: [String] = []
    for info in raw {
        let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
        if !owner.isEmpty { owners.append(owner) }
    }
    let unique = Array(Set(owners)).sorted()
    var sckOk = false
    var sckTitled = 0
    var sckWindows = 0
    var sckError = ""
    do {
        let content = try shareableContent()
        sckOk = true
        sckWindows = content.windows.count
        sckTitled = content.windows.filter { !($0.title ?? "").isEmpty }.count
    } catch {
        sckError = String(describing: error)
    }
    let axHint: String
    if trusted {
        axHint = "Accessibility is on for this signed app."
    } else {
        axHint = "Open System Settings from the Accessibility sheet and enable \(ourDisplayName()) (there is no in-dialog Allow on current macOS)."
    }
    let payload: [String: Any] = [
        "ax_trusted": trusted,
        "screen_recording": CGPreflightScreenCaptureAccess(),
        "sck_ok": sckOk,
        "sck_windows": sckWindows,
        "sck_titled": sckTitled,
        "sck_error": sckError,
        "post_event": CGPreflightPostEventAccess(),
        "window_owners": unique,
        "window_count": unique.count,
        "hint": axHint,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func run() throws {
    let args = currentArgv
    guard args.count >= 2 else {
        throw HelperError.usage(
            "usage: helper list|screenshot|ax-dump|click|drag|scroll|key|type|set-value|ax-action|user-context|restore-focus|isolate|activate|on-screen|park|doctor|serve"
        )
    }
    switch args[1] {
    case "ping":
        print("{\"ok\":true}")
    case "list":
        try listWindows()
    case "screenshot":
        try screenshot()
    case "ax-dump":
        try axDump()
    case "doctor":
        try doctor()
    case "on-screen":
        guard let pid = optionalPid() else { throw HelperError.usage("on-screen --pid N") }
        try printJSON(["ok": true, "pid": Int(pid), "on_screen": isPidOnScreen(pid)])
    case "park":
        try parkCmd()
    case "user-context":
        try userContextCmd()
    case "restore-focus":
        try restoreFocusCmd()
    case "isolate":
        try isolateCmd()
    case "activate":
        guard let pid = optionalPid() else { throw HelperError.usage("activate --pid N") }
        activate(pid: pid)
        print("{\"ok\":true}")
    case "click":
        if arg("index") != nil {
            try axClickIndex()
        } else {
            try click(
                x: try requireDouble("x"),
                y: try requireDouble("y"),
                button: arg("button") ?? "left",
                count: Int(arg("count") ?? "1") ?? 1,
                pid: optionalPid()
            )
        }
    case "set-value":
        try axSetValue()
    case "ax-action":
        try axSecondary()
    case "drag":
        try drag(
            fromX: try requireDouble("from-x"),
            fromY: try requireDouble("from-y"),
            toX: try requireDouble("to-x"),
            toY: try requireDouble("to-y"),
            pid: optionalPid()
        )
    case "scroll":
        try axScroll()
    case "key":
        let pid = optionalPid()
        guard let spec = arg("spec") else { throw HelperError.usage("key --spec Return") }
        try pressKey(spec: spec, pid: pid)
    case "type":
        let pid = optionalPid()
        guard let text = arg("text") else { throw HelperError.usage("type --text ...") }
        typeText(text, pid: pid)
    default:
        throw HelperError.usage("unknown command \(args[1])")
    }
}

func defaultSocketPath() -> String {
    let name =
        (Bundle.main.object(forInfoDictionaryKey: "CuaSupportDir") as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "cursor-desktop"
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(name)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("helper.sock").path
}

func captureRun() -> (stdout: String, stderr: String, code: Int32) {
    let outPipe = Pipe()
    let errPipe = Pipe()
    fflush(stdout)
    fflush(stderr)
    let oldOut = dup(STDOUT_FILENO)
    let oldErr = dup(STDERR_FILENO)
    dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    dup2(errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    var code: Int32 = 0
    do {
        try run()
    } catch {
        fputs("\(error)\n", stderr)
        code = 1
    }
    fflush(stdout)
    fflush(stderr)
    try? outPipe.fileHandleForWriting.close()
    try? errPipe.fileHandleForWriting.close()
    dup2(oldOut, STDOUT_FILENO)
    dup2(oldErr, STDERR_FILENO)
    Darwin.close(oldOut)
    Darwin.close(oldErr)
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (out, err, code)
}

func readSocketLine(_ fd: Int32) -> Data? {
    var buf: [UInt8] = []
    var b: UInt8 = 0
    while true {
        let n = recv(fd, &b, 1, 0)
        if n <= 0 { return buf.isEmpty ? nil : Data(buf) }
        if b == 10 { break }
        buf.append(b)
        if buf.count > 2_000_000 { break }
    }
    return Data(buf)
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var remaining = data.count
        var ptr = raw.bindMemory(to: UInt8.self).baseAddress
        while remaining > 0, let p = ptr {
            let n = send(fd, p, remaining, 0)
            if n <= 0 { return }
            remaining -= n
            ptr = p.advanced(by: n)
        }
    }
}

func handleClient(_ cfd: Int32) {
    defer { Darwin.close(cfd) }
    guard let line = readSocketLine(cfd),
          let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let argv = obj["argv"] as? [String], !argv.isEmpty else {
        writeAll(cfd, Data("{\"ok\":false,\"stderr\":\"bad request\"}\n".utf8))
        return
    }
    if argv[0] == "quit" {
        writeAll(cfd, Data("{\"ok\":true,\"stdout\":\"{\\\"ok\\\":true}\\n\"}\n".utf8))
        exit(0)
    }
    let saved = currentArgv
    currentArgv = [ProcessInfo.processInfo.processName] + argv
    let result = captureRun()
    currentArgv = saved
    let resp: [String: Any] = [
        "ok": result.code == 0,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "code": Int(result.code),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: resp),
          var text = String(data: data, encoding: .utf8) else { return }
    text += "\n"
    writeAll(cfd, Data(text.utf8))
}

func serveLoop() throws {
    let path = arg("socket") ?? defaultSocketPath()
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HelperError.failed("socket create failed") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
        guard let base = dest.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
        path.withCString { src in
            _ = strncpy(base, src, dest.count - 1)
        }
    }
    let bindOk = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindOk == 0 else { throw HelperError.failed("bind \(path) failed") }
    guard listen(fd, 8) == 0 else { throw HelperError.failed("listen failed") }
    chmod(path, 0o600)
    // Serial background clients: ScreenCaptureKit callbacks must not run while
    // handleClient is blocked on the main queue (deadlock).
    let clients = DispatchQueue(label: "cua.helper.clients")
    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 { continue }
            clients.sync {
                handleClient(cfd)
            }
        }
    }
    RunLoop.main.run()
}

func redirectFd(path: String, fd: Int32) {
    let nfd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard nfd >= 0 else { return }
    _ = dup2(nfd, fd)
    Darwin.close(nfd)
}

let outFinal = arg("reply")
let errFinal = arg("reply-err")
let outPartial = outFinal.map { $0 + ".partial" }
let errPartial = errFinal.map { $0 + ".partial" }
if let outPartial { redirectFd(path: outPartial, fd: STDOUT_FILENO) }
if let errPartial { redirectFd(path: errPartial, fd: STDERR_FILENO) }

func publishRedirects() {
    fflush(stdout)
    fflush(stderr)
    let fm = FileManager.default
    if let outFinal, let outPartial {
        try? fm.removeItem(atPath: outFinal)
        try? fm.moveItem(atPath: outPartial, toPath: outFinal)
    }
    if let errFinal, let errPartial, fm.fileExists(atPath: errPartial) {
        try? fm.removeItem(atPath: errFinal)
        try? fm.moveItem(atPath: errPartial, toPath: errFinal)
    }
}

do {
    if currentArgv.dropFirst().first == "serve" {
        try serveLoop()
    } else {
        try run()
        publishRedirects()
    }
} catch {
    fputs("\(error)\n", stderr)
    publishRedirects()
    exit(1)
}
