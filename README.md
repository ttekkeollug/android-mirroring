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
