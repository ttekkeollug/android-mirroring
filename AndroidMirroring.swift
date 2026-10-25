// Android Mirroring: 휴대폰 화면을 Mac 창으로 미러링한다. Dock에는 이 앱 하나만 보인다.
// - 메뉴 막대 아이콘에서 휴대폰별로 연결/해제
// - 미러링 창에서 한/영(Caps Lock)을 누르면 휴대폰 키보드 언어를 전환
import AppKit

// GUI 앱은 셸 PATH를 물려받지 않는다
setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)

func logPath(_ serial: String) -> String { NSTemporaryDirectory() + "android-mirroring-\(serial).log" }

// 미러링 창은 이 앱의 새 인스턴스로 띄운 뒤 곧바로 scrcpy로 바꿔 실행한다.
// 그러면 LaunchServices가 scrcpy 창을 'Android Mirroring'으로 보고 Dock 아이콘이 하나로 합쳐진다.
// 사용법: AndroidMirroring --mirror <serial> <창 제목>
let args = CommandLine.arguments
if args.count == 4, args[1] == "--mirror" {
    let fd = open(logPath(args[2]), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    dup2(fd, STDERR_FILENO)
    let argv = ["scrcpy", "--serial", args[2], "--window-title", args[3],
                "--turn-screen-off", "--stay-awake",
                "--keyboard=uhid", "--shortcut-mod=lsuper,rsuper"].map { strdup($0) } + [nil]
    execvp("scrcpy", argv)
    exit(127)  // scrcpy가 설치되어 있지 않음
}

struct Device { let serial: String; let name: String }

final class Mirror {
    let device: Device
    var pid: pid_t = 0
    var stopping = false
    init(_ device: Device) { self.device = device }
}

var mirrors: [String: Mirror] = [:]  // serial → 미러링

@discardableResult
func run(_ args: [String], wait: Bool = true) -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    guard wait else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func devices() -> [Device] {
    run(["adb", "devices", "-l"]).split(separator: "\n").dropFirst().compactMap { line in
        let f = line.split(separator: " ")
        guard f.count > 1, f[1] == "device" else { return nil }
        let model = f.first { $0.hasPrefix("model:") }?.dropFirst(6).replacingOccurrences(of: "_", with: "-")
        return Device(serial: String(f[0]), name: model ?? String(f[0]))
    }
}

func alert(_ title: String, _ message: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.runModal()
}

func connect(_ d: Device) {
    let m = Mirror(d)
    mirrors[d.serial] = m
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    cfg.arguments = ["--mirror", d.serial, d.name]
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { app, error in
        DispatchQueue.main.async {
            guard let app else {
                mirrors[d.serial] = nil
                alert("\(d.name) 연결 실패", error?.localizedDescription ?? "")
                return
            }
            m.pid = app.processIdentifier
            if m.stopping { disconnect(d.serial) }  // 뜨는 도중에 해제를 누른 경우
        }
    }
}

func disconnect(_ serial: String) {
    guard let m = mirrors[serial] else { return }
    m.stopping = true
    guard m.pid != 0 else { return }
    kill(m.pid, SIGTERM)
    // adb 연결이 끊긴 상태 등에서 SIGTERM에 반응하지 않으면 강제 종료
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { kill(m.pid, SIGKILL) }
}

// 미러링 창이 닫히면(직접 닫기, 연결 해제, 휴대폰 끊김) 정리하고, 예기치 않게 끊겼으면 이유를 보여준다
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
) { n in
    let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    guard let m = mirrors.values.first(where: { $0.pid == pid }) else { return }
    mirrors[m.device.serial] = nil
    let log = (try? String(contentsOfFile: logPath(m.device.serial), encoding: .utf8)) ?? ""
    if !m.stopping && log.contains("ERROR") {
        alert("\(m.device.name) 연결 끊김", log.split(separator: "\n").suffix(3).joined(separator: "\n"))
    }
}

// MARK: - 한/영

var lastSwitch = Date.distantPast

func frontMirror() -> Mirror? {
    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    return mirrors.values.first { $0.pid == pid }
}

func switchPhoneLanguage(_ m: Mirror) {
    // ponytail: 누름/뗌이 각각 이벤트로 올 수 있어 300ms 디바운스, 아주 빠른 연타는 한 번으로 친다
    guard Date().timeIntervalSince(lastSwitch) > 0.3 else { return }
    lastSwitch = Date()
    run(["adb", "-s", m.device.serial, "shell", "input", "keyevent", "LANGUAGE_SWITCH"], wait: false)
}

// Ctrl+Space 등: macOS가 입력 소스를 바꾸므로 그 알림을 받아 전환한다
DistributedNotificationCenter.default().addObserver(
    forName: .init("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
    object: nil, queue: .main
) { _ in
    if let m = frontMirror() { switchPhoneLanguage(m) }
}

// Caps Lock(한/영): 미러링 창 안에서는 macOS가 입력 소스를 바꾸지 않고 휴대폰에 Caps Lock으로
// 새어 나가므로, 이벤트 탭으로 가로채서 삼키고 대신 언어 전환을 보낸다. (손쉬운 사용 권한 필요)
// 권한이 없으면 안내 창을 한 번 띄우고, 허용될 때까지 2초마다 다시 시도한다
func installCapsLockTap() {
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
        guard AXIsProcessTrusted(), let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: { _, type, event, _ in
                guard type == .flagsChanged,
                      event.getIntegerValueField(.keyboardEventKeycode) == 57,  // Caps Lock
                      let m = frontMirror()
                else { return Unmanaged.passUnretained(event) }
                switchPhoneLanguage(m)
                return nil
            }, userInfo: nil) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        timer.invalidate()
    }.fire()
}

// MARK: - 메뉴 막대

final class Menu: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "candybarphone", accessibilityDescription: "Android Mirroring")
        item.menu = NSMenu()
        item.menu?.delegate = self
    }

    // 메뉴를 열 때마다 기기 목록을 새로 읽는다
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // 미러링 중인 기기는 adb 목록에서 잠깐 빠져도 해제할 수 있게 항상 보여준다
        let found = devices()
        let list = found + mirrors.values.map(\.device).filter { m in !found.contains { $0.serial == m.serial } }
        if list.isEmpty {
            menu.addItem(withTitle: "연결된 휴대폰 없음", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "USB 디버깅 또는 무선 디버깅을 켜세요", action: nil, keyEquivalent: "")
        }
        for d in list {
            let on = mirrors[d.serial] != nil
            let i = NSMenuItem(title: on ? "\(d.name) 연결 해제" : "\(d.name) 연결",
                               action: #selector(toggle(_:)), keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            i.representedObject = d
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc func toggle(_ sender: NSMenuItem) {
        let d = sender.representedObject as! Device
        mirrors[d.serial] == nil ? connect(d) : disconnect(d.serial)
    }

    @objc func quit() {
        mirrors.keys.forEach(disconnect)
        NSApp.terminate(nil)
    }
}

// iPhone 미러링처럼 앱을 열 때마다(이미 실행 중이어도) 바로 미러링을 보여준다
func openMirror() {
    if let m = mirrors.values.first {
        NSRunningApplication(processIdentifier: m.pid)?.activate()
        return
    }
    let list = devices()
    switch list.count {
    case 0: alert("연결된 휴대폰 없음", "휴대폰에서 USB 디버깅 또는 무선 디버깅을 켜고 다시 열어 주세요.")
    case 1: connect(list[0])
    default: menu.item.button?.performClick(nil)  // 여러 대면 메뉴에서 고르게 한다
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) { openMirror() }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openMirror()
        return false
    }
}

// 이 프로세스는 Dock에 보이지 않는 관리자 역할만 하고, Dock 아이콘은 미러링 창이 차지한다
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menu = Menu()
let delegate = AppDelegate()
app.delegate = delegate
installCapsLockTap()
app.run()
