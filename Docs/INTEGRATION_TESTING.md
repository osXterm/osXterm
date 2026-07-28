# osXterm 로컬 SSH 통합 테스트

`Scripts/run-integration-tests.sh`는 외부 서버나 기존 `~/.ssh` 설정을 사용하지 않고 macOS 안에서 SSH 전송 기능을 실제로 검증한다. 테스트가 성공하면 다음 동작이 로컬 OpenSSH 기준으로 확인된 것이다.

- 전용 `ssh-agent` 소켓을 통한 공개 키 인증
- 대상 서버로의 직접 SSH 연결과 원격 명령 실행
- 직접 SFTP 업로드, 다운로드, 바이트 단위 내용 비교
- 별도 JumpHost를 거치는 `ProxyJump` SSH 연결
- JumpHost를 거치는 SFTP 업로드와 다운로드
- `ExitOnForwardFailure`가 적용된 로컬 포트포워딩
- 포워딩 포트를 통해 대상 sshd에 다시 접속하는 종단간 확인
- SOCKS5 동적 포워딩을 거치는 두 번째 SSH 연결
- 원격 포트포워딩 리스너를 거치는 두 번째 SSH 연결

이 하네스는 osXterm이 사용할 전송 기반 기능을 검증한다. 앱 UI, 터미널의 현재 경로 이벤트, SFTP 사이드바 자동 추적은 별도의 앱 통합 및 UI 테스트 대상이다.

## 요구 사항

- macOS
- 비관리자 사용자 계정
- macOS 기본 OpenSSH 도구
- 사용 가능한 loopback 네트워크와 동적 포트

필요한 도구는 `ssh`, `sshd`, `sftp`, `ssh-agent`, `ssh-add`, `ssh-keygen`, `nc`다. 하나라도 없으면 하네스가 시작 단계에서 정확한 도구 이름과 함께 실패한다.

`sudo`는 필요하지 않으며 사용하면 안 된다. 하네스는 관리자 계정으로 실행되는 경우 의도적으로 중단한다.

## 실행

저장소 루트에서 다음 명령을 실행한다.

```bash
Scripts/run-integration-tests.sh
```

성공 시 각 검증 항목이 `[PASS]`로 출력되고 마지막에 실제 사용한 대상, JumpHost, 포워딩 포트가 표시된다.

```text
[PASS] Two unprivileged loopback sshd instances are listening
[PASS] Dedicated ssh-agent holds the only usable client private key
[PASS] Direct SSH authenticated through the dedicated ssh-agent
[PASS] Direct SFTP upload and download preserved file content
[PASS] ProxyJump reached the target through the jump sshd
[PASS] SFTP upload and download succeeded through ProxyJump
[PASS] Local port forwarding carried a second SSH connection to the target
[PASS] Dynamic SOCKS forwarding carried an SSH connection to the target
[PASS] Remote port forwarding carried a second SSH connection to the target

All osXterm local integration tests passed.
Validated ports: target=62793 jump=64107 forward=55646 socks=51080 remote-forward=60214
```

포트 번호는 실행할 때마다 달라진다.

## 격리와 정리

하네스는 다음 방식으로 개발자의 SSH 환경과 분리된다.

- `/tmp/osxterm-it.XXXXXX` 형식의 `mktemp` 디렉터리를 사용한다.
- `49152` 이상의 사용 가능한 loopback 고포트 다섯 개를 선택하고 중복을 거부한다.
- 두 sshd 모두 `127.0.0.1`에만 바인딩한다.
- 임시 호스트 키와 임시 클라이언트 키를 매번 새로 생성한다.
- 대상과 JumpHost 모두 비밀번호 인증을 끄고 현재 사용자와 생성된 공개 키만 허용한다.
- 전용 `ssh-agent`에 키를 추가한 뒤 클라이언트 개인 키 파일을 즉시 삭제한다.
- 별도 SSH 설정과 `known_hosts`를 사용하며 사용자 `~/.ssh/config`를 읽지 않는다.
- 정상 종료, 오류, 인터럽트 모두 `trap`에서 포워딩, sshd, agent를 종료하고 임시 디렉터리를 제거한다.

테스트 실패 시 정리 전에 각 로그의 마지막 80줄이 출력된다. 임시 개인 키와 서버 프로세스는 실패한 경우에도 남지 않는다.

## 검증 흐름

1. 대상 sshd와 JumpHost sshd를 각각 다른 loopback 포트에서 시작한다.
2. 생성한 클라이언트 키를 전용 agent에 추가하고 디스크의 개인 키를 삭제한다.
3. agent만으로 대상 sshd에 직접 접속한다.
4. 직접 SFTP 세션에서 파일을 올리고 다시 받아 `cmp`로 비교한다.
5. `ProxyJump`를 통해 대상에 접속하고 JumpHost 로그의 공개 키 인증도 확인한다.
6. 같은 JumpHost 경로로 SFTP 업로드와 다운로드를 다시 검증한다.
7. 대상 세션에 로컬 포트포워딩을 만들고 그 포트로 두 번째 SSH 연결을 수행한다.
8. 대상 세션에 SOCKS5 동적 포워딩을 만들고 SOCKS 프록시를 경유한 두 번째 SSH 연결을 수행한다.
9. 대상 세션에 원격 포트포워딩을 만들고 원격 리스너를 통해 두 번째 SSH 연결을 수행한다.

## 문제 해결

### `Operation not permitted`로 sshd가 바인딩되지 않는 경우

일부 코드 실행 샌드박스는 loopback 포트 바인딩도 막는다. 일반 macOS Terminal에서 실행하거나 해당 실행 환경에 로컬 네트워크 바인딩 권한을 허용한다. 하네스 자체는 외부 네트워크에 연결하지 않는다.

### 포트가 이미 사용 중인 경우

하네스는 시작 전에 후보 포트가 비어 있는지 확인한다. 확인 직후 다른 프로세스가 같은 포트를 차지하는 드문 경쟁이 발생하면 sshd 로그와 함께 실패한다. 다시 실행하면 새로운 포트가 선택된다.

### macOS 방화벽 또는 보안 제품이 연결을 막는 경우

두 sshd는 loopback에만 바인딩되므로 외부에서 접근할 수 없다. 그래도 보안 제품이 실행을 차단한다면 `/usr/sbin/sshd`의 로컬 loopback 실행 정책을 확인한다.

## 현재 검증 범위 밖

- 실제 원격 호스트의 네트워크, DNS, 인증서, 호스트 키 정책
- 비밀번호 또는 키 암호문 기반 인증
- 다단계 JumpHost와 HTTP CONNECT 또는 SOCKS5 프록시
- 앱 내부 터미널 렌더링
- OSC 7 기반 현재 경로 추적과 SFTP 사이드바 갱신
- Finder 드래그 앤 드롭, 전송 진행률, 취소, 충돌 UI

이 항목들은 앱 기능 테스트에서 별도로 검증해야 한다. 특히 사이드바 경로 추적 성공은 SSH와 SFTP 연결 성공만으로 입증되지 않는다.
