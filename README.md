# Android Mirroring

iPhone 미러링처럼 안드로이드 휴대폰 화면을 Mac 창에 띄워 마우스·키보드로 조작하는 앱입니다.
[scrcpy](https://github.com/Genymobile/scrcpy) 위에 얹은 얇은 래퍼입니다.

- 미러링 중 휴대폰 화면은 꺼지고 Mac에서 조작
- 연결 중 휴대폰 잠김 방지
- 소리도 Mac으로 출력 (Android 11+)

## 설치

```bash
brew install scrcpy android-platform-tools
```

[Releases](../../releases)에서 `Android-Mirroring.zip`을 받아 압축을 풀고 `/Applications`로 옮깁니다.
서명되지 않은 앱이므로 처음 실행 시 우클릭 → 열기.

## 휴대폰 연결

- **USB**: 개발자 옵션 → USB 디버깅 켜고 케이블 연결
- **무선**: 개발자 옵션 → 무선 디버깅 → `adb pair <IP:포트>` 후 `adb connect <IP:포트>`

`adb devices`에 기기가 보이면 앱을 실행하세요.

## 키보드와 단축키

Mac 키보드가 휴대폰에 **실제 블루투스 키보드처럼** 연결됩니다 (`--keyboard=uhid`).
한글 입력, Ctrl/Option 조합, 방향키 모두 휴대폰으로 그대로 전달됩니다.
Mac에서 평소처럼 한/영을 바꾸면 (Caps Lock, Ctrl+Space 등) 휴대폰도 같이 전환됩니다.
`hangul` helper가 Mac 입력 소스 변경을 감지해 휴대폰에 언어 전환 키를 보냅니다 (소스: `hangul.swift`).

`Cmd`는 미러링 단축키 전용입니다:

| 단축키 | 동작 |
|---|---|
| `Cmd+H` | 홈 |
| `Cmd+B` / 우클릭 | 뒤로 |
| `Cmd+S` | 최근 앱 |
| `Cmd+M` | 메뉴 |
| `Cmd+C` / `Cmd+X` | 휴대폰에서 복사/잘라내기 (Mac 클립보드와 동기화) |
| `Cmd+V` | Mac 클립보드 붙여넣기 |
| `Cmd+↑` / `Cmd+↓` | 볼륨 |
| `Cmd+P` | 전원 |
| `Cmd+O` / `Cmd+Shift+O` | 휴대폰 화면 끄기/켜기 |
| `Cmd+R` | 화면 회전 |
| `Cmd+F` | 전체 화면 |
| `Cmd+N` / `Cmd+Shift+N` | 알림창 열기/닫기 |
| `Cmd+K` | 휴대폰의 물리 키보드 설정 열기 (자판 배열 설정) |

전체 목록: [scrcpy shortcuts](https://github.com/Genymobile/scrcpy/blob/master/doc/shortcuts.md)
