# Ghostty VT 엔진

osXterm의 터미널 에뮬레이션 코어는 Ghostty의 공식 `libghostty-vt`를 사용한다. 이 라이브러리는 VT 시퀀스 파싱, 화면 상태, 스크롤백, 입력 인코딩을 제공한다. osXterm은 SSH PTY와 macOS AppKit 입력 및 표시 계층을 소유한다.

`libghostty-vt`는 Ghostty의 완성된 macOS GUI가 아니다. Ghostty의 macOS 앱 전용 `libghostty`와 XCFramework 경로는 전체 Xcode가 필요하며, Command Line Tools만 있는 현재 개발 환경에서는 내장 대상으로 사용하지 않는다.

## 고정 버전과 라이선스

- 공식 저장소: `https://github.com/ghostty-org/ghostty.git`
- 고정 커밋: `4c725242b7dbe8c77c6e227ef1f9540c5ef17921`
- 빌드 Zig: `0.16.0`
- `libghostty-vt` 버전: `0.1.0`
- 라이선스: MIT
- 저작권: Mitchell Hashimoto, Ghostty contributors

정확한 빌드 값은 `Vendor/GhosttyVt/Ghostty.lock`에 있고, 배포물에 포함할 라이선스 원문은 `Vendor/GhosttyVt/LICENSE`에 있다. Ghostty 헤더는 API가 아직 안정화되지 않았다고 명시한다. 따라서 커밋을 명시적으로 올리고 VT 통합 검사를 함께 갱신해야 한다.

## 소스 공급 전략

`Vendor/GhosttyVt/Artifacts/<commit>/<architecture>-macos`에는 현재 개발 환경에서 바로 빌드할 수 있도록 arm64 정적 라이브러리와 공개 헤더를 포함한다. 빌드 스크립트는 같은 고정 소스와 고정 Zig로 이 artifact를 다시 생성한다. x86_64 개발 환경에서는 해당 아키텍처 artifact를 같은 경로 구조로 생성해야 한다.

원본 소스를 Git submodule로 관리하려면 다음처럼 위 커밋을 Gitlink로 고정한다.

```bash
git submodule add https://github.com/ghostty-org/ghostty.git Vendor/ghostty-source
git -C Vendor/ghostty-source checkout 4c725242b7dbe8c77c6e227ef1f9540c5ef17921
git add .gitmodules Vendor/ghostty-source
```

빌드 스크립트는 Git 원격 URL, 정확한 커밋, Zig 버전을 모두 검사한다. 네트워크에서 임의의 최신 Ghostty를 내려받거나 빌드하지 않는다.

## 빌드

현재 제공된 Ghostty 소스와 Zig를 사용하려면 다음처럼 실행한다.

```bash
GHOSTTY_SOURCE=/private/tmp/ghostty-source \
GHOSTTY_ZIG=/private/tmp/osXterm-zig-download/zig-aarch64-macos-0.16.0/zig \
Scripts/build-ghostty-vt.sh
```

일반 개발 환경에서는 submodule과 `Tools/zig-0.16.0/zig`를 준비한 뒤 환경 변수 없이 실행한다.

```bash
Scripts/build-ghostty-vt.sh
```

이 스크립트는 Ghostty가 문서화한 다음 공식 빌드 경로를 사용한다.

```bash
zig build -Demit-lib-vt=true -Demit-xcframework=false -Demit-macos-app=false
```

XCFramework 생성을 명시적으로 끈 이유는 macOS Command Line Tools의 `xcodebuild`가 전체 Xcode를 요구하기 때문이다. 결과물은 해당 머신 아키텍처용 `libghostty-vt.a`, C 헤더, Swift 모듈 맵이며 앱에 정적으로 링크된다. 따라서 앱 실행 시 별도 Ghostty dylib를 찾지 않는다.

## SwiftPM 연결

빌드 후 `GhosttyVt` C bridge 타깃을 `OsXTermCore`가 의존한다. bridge는 Ghostty의 불안정한 C struct를 Swift에 직접 노출하지 않고, 터미널 생성, 원본 VT write, resize, 화면 및 PWD snapshot, PTY reply를 작은 API로 감싼다. `Package.swift`의 핵심 형태는 다음과 같다.

```swift
let ghosttyVtArtifact = "Vendor/GhosttyVt/Artifacts/4c725242b7dbe8c77c6e227ef1f9540c5ef17921/arm64-macos/lib"

.target(
    name: "GhosttyVt",
    path: "Vendor/GhosttyVt",
    sources: ["Sources/GhosttyVtShim.c"],
    publicHeadersPath: "include",
    cSettings: [
        .headerSearchPath(
            "Artifacts/4c725242b7dbe8c77c6e227ef1f9540c5ef17921/arm64-macos/include"
        )
    ],
    linkerSettings: [
        .unsafeFlags(["-L", ghosttyVtArtifact]),
        .linkedLibrary("ghostty-vt")
    ]
)
```

그 다음 `OsXTermCore`의 dependencies에 `"GhosttyVt"`를 추가한다. 현재 arm64 artifact는 이미 포함되어 있지만, 새 아키텍처나 Ghostty pin 변경 뒤에는 `Scripts/build-ghostty-vt.sh`를 실행해야 한다.

터미널 세션은 PTY의 원본 바이트를 `ghostty_terminal_vt_write`로 전달하고, 리사이즈를 `ghostty_terminal_resize`로 전달한다. Ghostty의 device query reply는 callback에서 모아 SSH PTY로 다시 보낸다. OSC 7, OSC 9, OSC 1337 PWD는 Ghostty 상태에서 읽어 SFTP sidebar의 현재 경로를 갱신한다.

현재 AppKit surface는 Ghostty가 관리하는 screen의 셀별 grapheme 및 스타일을 읽어 MesloLGS NF `NSAttributedString`으로 표시한다. ANSI foreground/background 색상, 256색 palette, bold, italic, underline, faint, inverse, invisible, strike-through를 화면에 반영하고, 선택한 Ghostty 테마의 palette를 palette 색상에 사용한다. Ghostty의 뷰포트 스크롤 상태와 커서 좌표 및 모양도 함께 읽어, 터미널 박스 크기를 변경하지 않고 내부 스크롤백과 커서 오버레이를 그린다. 현재 기본 스크롤백은 5,000줄이다. plain-text projection은 검색 및 상태 판정용으로 유지하며 raw keyboard 및 paste bytes는 PTY에 보낸다. 이는 Ghostty VT 코어 내장이다. Ghostty 앱 자체의 Metal renderer와 `libghostty` surface는 이 환경에서 사용하지 않는다. 그 API는 아직 일반 목적 embedding API가 아니며 full Xcode 기반 빌드가 필요하다.

## Ghostty 테마 통합

`OsXTermCore.GhosttyThemeCatalog`는 Ghostty의 설정과 테마 파일을 읽어 설정 화면에 동적으로 표시한다.

- `$XDG_CONFIG_HOME/ghostty/config.ghostty` 또는 `config`
- macOS 설정 경로인 `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty` 또는 `config`
- 사용자 테마: `$XDG_CONFIG_HOME/ghostty/themes`
- 설치된 Ghostty.app의 `Contents/Resources/ghostty/themes`

Ghostty 설정의 `theme` 값, `light:...,dark:...` 구문, `config-file` 포함 파일, 테마의 `background`, `foreground`, `cursor-color`, 선택 영역 색상, 256색 `palette`를 처리한다. 설정 화면의 `Ghostty config: ...` 항목은 현재 Ghostty 설정을 그대로 사용하고, 개별 테마를 선택하면 해당 테마 파일의 색상을 사용한다. 테마 선택은 osXterm 설정에 저장되며 Ghostty 원본 설정 파일은 자동으로 덮어쓰지 않는다.
