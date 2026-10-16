# 크리스 앱 (kris-app)

기존 「크리스(지니야)」 웹앱(PWA)을 **하나의 네이티브 앱**으로 만든다.
교육생은 이 앱 하나만 설치하면 — 크리스 웹 화면도 쓰고, 폰에 오는 카톡·문자·전화·메일도 자동 수집된다.
선별·요약·아침브리핑은 **서버가 이미 다 한다**(앱은 안 건드림).

- 발주처: (주)오원트밸런스 / 크리스 플랫폼
- 서버(확정): **https://genya-pwa.onrender.com**  (WebView·모든 수집 API가 이 주소)
- 앱이 하는 일: ①기존 웹 화면 띄우기 ②폰 알림·통화·메일 수집·전송 ③푸시 수신
- 안 하는 것: 발송·결제·자동응답 (읽기·전송만)

## 기술 스택
- Flutter (Android + iOS 한 코드베이스)
- 화면: `flutter_inappwebview` 로 기존 크리스 웹을 띄움
- 안드 알림캡처: NotificationListenerService / 통화녹음: 폴더 감시 / 푸시: FCM·APNs
- iOS 카톡·문자: 공유확장(Share Extension)
- 보안저장: secure storage (ikey 보관)

## 진행 상황
- ✅ **① WebView 껍데기** — 앱이 켜지면 크리스 웹(genya-pwa.onrender.com)을 전체화면으로 띄움.
  뒤로가기(웹 히스토리)·당겨서 새로고침·로딩바 포함. (`lib/main.dart`)
- ⬜ ② 안드 알림 수집 + ikey 연결 (`/api/inbox/in`, `window.genyaIssueIkey()`)
- ⬜ ③ 통화녹음 수집 + 푸시(FCM) (`/api/inbox/call`, `/api/push/register`)
- ⬜ ④ iOS 공유확장 + 푸시(APNs)
- ⬜ ⑤ 정식 스토어 등록 + 권한 심사노트·개인정보처리방침

## 빌드 (APK)
이 저장소는 **GitHub Actions에서 APK를 자동 빌드**한다(개발 환경에 Flutter/안드 SDK 불필요).
- `main`에 push하거나 Actions 탭에서 **build-apk > Run workflow** 실행
- 완료되면 그 실행의 **Artifacts > `kris-app-apk`** 에서 `app-release.apk` 다운로드
- 그 APK를 폰에 설치해 테스트 (분담: 코드·커밋·APK빌드=후임 / 설치·눌러보기=발주자)

## 인수 기준 (①단계)
- 앱 설치 후 WebView에서 기존 크리스 **로그인·소식함·대화가 그대로 동작**.

## 메모
- `android/` 등 플랫폼 폴더는 CI가 `flutter create`로 생성하므로 저장소에는 담지 않음(.gitignore).
  앱의 실제 코드는 `lib/main.dart` 와 `pubspec.yaml` 두 개가 전부(①단계 기준).
