// Android Mirroring: 휴대폰 화면을 Mac 창으로 미러링한다. Dock에는 이 앱 하나만 보인다.
// - 미러링 창 아래 '연결 해제' 막대, 해제하면 연결 창에서 유선/무선 방법을 골라 다시 연결
// - 메뉴 막대 아이콘에서 휴대폰별로 연결/해제
// - 미러링 창에서 한/영(Caps Lock)을 누르면 휴대폰 키보드 언어를 전환
import AppKit
import SwiftUI

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

struct Device { let serial: String; let name: String; let usb: Bool }

final class Mirror {
    let device: Device
    var pid: pid_t = 0
    var stopping = false
    var bar: NSPanel?
    var volume: String?  // 미러링 전 휴대폰 미디어 볼륨, 끝나면 되돌린다
    init(_ device: Device) { self.device = device }
}

var mirrors: [String: Mirror] = [:]  // serial → 미러링

@discardableResult
func run(_ args: [String], wait: Bool = true) -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = out
    p.standardError = out
    guard (try? p.run()) != nil else { return "" }
    guard wait else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// 미러링 중인 기기는 adb 목록에서 잠깐 빠져도 해제할 수 있게 항상 포함한다
func listDevices() -> [Device] {
    let found: [Device] = run(["adb", "devices", "-l"]).split(separator: "\n").dropFirst().compactMap { line in
        let f = line.split(separator: " ")
        guard f.count > 1, f[1] == "device" else { return nil }
        let model = f.first { $0.hasPrefix("model:") }?.dropFirst(6).replacingOccurrences(of: "_", with: "-")
        return Device(serial: String(f[0]), name: model ?? String(f[0]), usb: f.contains { $0.hasPrefix("usb:") })
    }
    return found + mirrors.values.map(\.device).filter { m in !found.contains { $0.serial == m.serial } }
}

func connect(_ d: Device) {
    let m = Mirror(d)
    m.volume = run(["adb", "-s", d.serial, "shell", "cmd", "media_session", "volume", "--stream", "3", "--get"])
        .components(separatedBy: "volume is ").dropFirst().first?.split(separator: " ").first.map(String.init)
    mirrors[d.serial] = m
    model.refresh()
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    cfg.arguments = ["--mirror", d.serial, d.name]
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { app, error in
        DispatchQueue.main.async {
            guard let app else {
                mirrors[d.serial] = nil
                showConnectWindow("\(d.name) 연결 실패: \(error?.localizedDescription ?? "")")
                return
            }
            m.pid = app.processIdentifier
            m.bar = disconnectBar(m)
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

// 미러링 창이 닫히면(직접 닫기, 연결 해제, 휴대폰 끊김) 정리하고, 예기치 않게 끊겼으면 연결 창에 이유를 보여준다
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
) { n in
    let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    guard let m = mirrors.values.first(where: { $0.pid == pid }) else { return }
    mirrors[m.device.serial] = nil
    m.bar?.close()
    model.refresh()
    // 소리를 맥으로 보내는 동안 휴대폰 스피커 볼륨이 바뀌므로, 스피커로 돌아온 뒤 원래 볼륨으로 되돌린다
    if let v = m.volume {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            run(["adb", "-s", m.device.serial, "shell", "cmd", "media_session", "volume", "--stream", "3", "--set", v])
        }
    }
    let log = (try? String(contentsOfFile: logPath(m.device.serial), encoding: .utf8)) ?? ""
    if !m.stopping && log.contains("ERROR") {
        showConnectWindow("\(m.device.name) 연결 끊김: " + log.split(separator: "\n").suffix(2).joined(separator: " "))
    }
}

// MARK: - 미러링 창 아래 연결 해제 막대

struct DisconnectBar: View {
    let device: Device
    var body: some View {
        HStack {
            Image(systemName: device.usb ? "cable.connector" : "wifi")
            Text(device.name)
            Spacer()
            Button("연결 해제") {
                disconnect(device.serial)
                showConnectWindow()
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

let barHeight: CGFloat = 36

func disconnectBar(_ m: Mirror) -> NSPanel {
    // 클릭해도 미러링 창에서 포커스를 뺏지 않는 패널
    let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
    p.level = .floating
    p.hidesOnDeactivate = false
    p.contentView = NSHostingView(rootView: DisconnectBar(device: m.device))
    return p
}

// 미러링 창을 따라다니며 바로 아래에 붙인다. 미러링 창이 앞에 있을 때만 보인다
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    guard !mirrors.isEmpty else { return }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for m in mirrors.values {
        guard let bar = m.bar else { continue }
        guard front == m.pid,
              let info = windows.first(where: { $0[kCGWindowOwnerPID as String] as? pid_t == m.pid && $0[kCGWindowLayer as String] as? Int == 0 }),
              let r = CGRect(dictionaryRepresentation: info[kCGWindowBounds as String] as! CFDictionary)
        else { bar.orderOut(nil); continue }
        // CG 좌표(위가 0) → Cocoa 좌표(아래가 0). 화면 아래로 넘치면 창 하단에 겹쳐 놓는다
        let y = max(NSScreen.screens[0].frame.height - r.maxY - barHeight, NSScreen.main?.visibleFrame.minY ?? 0)
        bar.setFrame(NSRect(x: r.minX, y: y, width: r.width, height: barHeight), display: true)
        bar.orderFront(nil)
    }
}

// MARK: - 연결 창: 유선/무선 방법을 골라 연결

final class Model: ObservableObject {
    @Published var devices: [Device] = []
    @Published var mirroring: Set<String> = []
    @Published var message: String?
    func refresh() {
        devices = listDevices()
        mirroring = Set(mirrors.keys)
    }
    // adb connect/pair는 몇 초 걸릴 수 있어 백그라운드에서 돌리고 결과를 보여준다
    func adb(_ args: [String]) {
        message = "연결 중…"
        DispatchQueue.global().async {
            let out = run(["adb"] + args).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.message = out; self.refresh() }
        }
    }
}

let model = Model()

struct ConnectView: View {
    @ObservedObject var model: Model
    @State var address = ""
    @State var pairAddress = ""
    @State var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let m = model.message { Text(m).font(.callout).foregroundColor(.secondary) }

            GroupBox("연결된 휴대폰") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.devices.isEmpty {
                        Text("아직 없습니다. 아래 방법 중 하나로 연결하세요.").foregroundColor(.secondary)
                    }
                    ForEach(model.devices, id: \.serial) { d in
                        HStack {
                            Image(systemName: d.usb ? "cable.connector" : "wifi").frame(width: 20)
                            Text(d.name)
                            Text(d.usb ? "유선" : "무선").foregroundColor(.secondary)
                            Spacer()
                            if model.mirroring.contains(d.serial) {
                                Button("연결 해제") { disconnect(d.serial) }
                            } else {
                                Button("미러링 시작") {
                                    connectWindow?.close()
                                    connect(d)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }

            GroupBox(label: Label("유선 (USB)", systemImage: "cable.connector")) {
                Text("""
                1. 휴대폰 개발자 옵션 → USB 디버깅 켜기
                2. 케이블로 Mac에 연결하고 휴대폰에서 'USB 디버깅 허용'
                연결되면 위 목록에 자동으로 나타납니다.
                """).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }

            GroupBox(label: Label("무선 (같은 Wi-Fi)", systemImage: "wifi")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("한 번 페어링한 휴대폰은 개발자 옵션 → 무선 디버깅을 켜면 자동으로 나타납니다.")
                    HStack {
                        TextField("IP 주소:포트 (무선 디버깅 화면에 표시)", text: $address)
                        Button("연결") { model.adb(["connect", address]) }.disabled(address.isEmpty)
                    }
                    Divider()
                    Text("처음 연결: 무선 디버깅 → '페어링 코드로 기기 페어링'")
                    HStack {
                        TextField("IP 주소:포트", text: $pairAddress)
                        TextField("페어링 코드", text: $code).frame(width: 100)
                        Button("페어링") { model.adb(["pair", pairAddress, code]) }
                            .disabled(pairAddress.isEmpty || code.isEmpty)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
        .fixedSize(horizontal: false, vertical: true)  // 안내 문구가 잘리지 않고 줄바꿈되게
        .padding(20)
        .frame(width: 460)
    }
}

var connectWindow: NSWindow?

func showConnectWindow(_ message: String? = nil) {
    model.message = message
    model.refresh()
    if connectWindow == nil {
        let w = NSWindow(contentViewController: NSHostingController(rootView: ConnectView(model: model)))
        w.title = "Android Mirroring"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        // 창이 떠 있는 동안만 Dock에 보이게 한다 (미러링 중에는 미러링 창이 Dock 아이콘을 쓴다)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
        w.center()
        connectWindow = w
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    connectWindow?.makeKeyAndOrderFront(nil)
}

// 연결 창이 열려 있는 동안 휴대폰 목록을 자동으로 새로 고친다 (USB를 꽂거나 무선 디버깅을 켜면 바로 보이게)
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    if connectWindow?.isVisible == true { model.refresh() }
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
        let list = listDevices()
        if list.isEmpty {
            menu.addItem(withTitle: "연결된 휴대폰 없음", action: nil, keyEquivalent: "")
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
        let window = NSMenuItem(title: "연결 방법…", action: #selector(openWindow), keyEquivalent: "")
        window.target = self
        menu.addItem(window)
        let quit = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc func toggle(_ sender: NSMenuItem) {
        let d = sender.representedObject as! Device
        mirrors[d.serial] == nil ? connect(d) : disconnect(d.serial)
    }

    @objc func openWindow() { showConnectWindow() }

    @objc func quit() {
        mirrors.keys.forEach(disconnect)
        NSApp.terminate(nil)
    }
}

// iPhone 미러링처럼 앱을 열 때마다(이미 실행 중이어도) 바로 미러링을 보여준다.
// 휴대폰이 없거나 여러 대면 연결 창에서 고르게 한다
func openMirror() {
    if let m = mirrors.values.first {
        NSRunningApplication(processIdentifier: m.pid)?.activate()
        return
    }
    let list = listDevices()
    list.count == 1 ? connect(list[0]) : showConnectWindow()
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
