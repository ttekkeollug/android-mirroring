// 미러링 창에서 한/영을 누르면 휴대폰 키보드 언어를 전환한다.
// - Caps Lock(한/영): 미러링 창 안에서는 macOS가 입력 소스를 바꾸지 않고 휴대폰에 Caps Lock으로
//   새어 나가므로, 이벤트 탭으로 가로채서 삼키고 대신 언어 전환을 보낸다. (손쉬운 사용 권한 필요)
// - Ctrl+Space 등: macOS가 입력 소스를 바꾸므로 그 알림을 받아 전환한다.
// 사용법: hangul <scrcpy pid>
import AppKit

let scrcpyPid = pid_t(CommandLine.arguments[1])!
let capsLockKey: Int64 = 57
var lastSwitch = Date.distantPast

func mirrorIsFront() -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == scrcpyPid
}

func switchPhoneLanguage() {
    // ponytail: 누름/뗌이 각각 이벤트로 올 수 있어 300ms 디바운스, 아주 빠른 연타는 한 번으로 친다
    guard Date().timeIntervalSince(lastSwitch) > 0.3 else { return }
    lastSwitch = Date()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["adb", "shell", "input", "keyevent", "LANGUAGE_SWITCH"]
    try? p.run()
}

DistributedNotificationCenter.default().addObserver(
    forName: .init("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
    object: nil, queue: .main
) { _ in
    if mirrorIsFront() { switchPhoneLanguage() }
}

// 권한이 없으면 시스템 설정 안내 창을 한 번 띄우고, 허용될 때까지 2초마다 다시 시도한다
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
    guard AXIsProcessTrusted(), let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
        callback: { _, type, event, _ in
            guard type == .flagsChanged,
                  event.getIntegerValueField(.keyboardEventKeycode) == capsLockKey,
                  mirrorIsFront()
            else { return Unmanaged.passUnretained(event) }
            switchPhoneLanguage()
            return nil
        }, userInfo: nil) else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    timer.invalidate()
}.fire()

RunLoop.main.run()
