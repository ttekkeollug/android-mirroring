// Mac에서 한/영(Caps Lock, Ctrl+Space 등)을 바꾸면 휴대폰도 같이 전환한다.
// macOS가 한/영 키를 먼저 가로채서 휴대폰에는 전달되지 않기 때문.
// 사용법: hangul <scrcpy pid>  — 미러링 창이 앞에 있을 때만 동작
import AppKit

let scrcpyPid = pid_t(CommandLine.arguments[1])!

DistributedNotificationCenter.default().addObserver(
    forName: .init("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
    object: nil, queue: .main
) { _ in
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == scrcpyPid else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["adb", "shell", "input", "keyevent", "LANGUAGE_SWITCH"]
    try? p.run()
}
RunLoop.main.run()
