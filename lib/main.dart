// 크리스 앱 — 단계 ② 안드로이드 알림 수집 + ikey 연결
// ① WebView 껍데기 위에, 폰의 카톡·문자 알림을 잡아 서버로 보낸다.
// 서버(대표 확정): https://genya-pwa.onrender.com  (서버는 이미 완성 — 안 건드림)
//  - ikey 발급: WebView에서 window.genyaIssueIkey() → 웹이 callHandler('genyaIkey','ik_…')
//  - 알림 전송: POST /api/inbox/in  헤더 x-inbox-token:<ik_…>  본문 {창구,보낸이,본문}

import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_notification_listener_plus/flutter_notification_listener_plus.dart';
import 'package:http/http.dart' as http;

const String kBaseUrl = 'https://genya-pwa.onrender.com';
const String kPortName = '_kris_listener_';
const String kIkeyKey = 'genya_ikey';

// 수집할 앱 → 창구 이름
String? changukOf(String? pkg) {
  if (pkg == null) return null;
  if (pkg == 'com.kakao.talk') return 'kakao';
  const sms = {
    'com.android.mms',
    'com.android.messaging',
    'com.samsung.android.messaging',
    'com.samsung.android.app.messaging',
    'com.google.android.apps.messaging',
    'com.sec.android.app.messaging',
  };
  if (sms.contains(pkg)) return 'sms';
  return null;
}

// ★알림이 오면 백그라운드 격리자에서 불리는 콜백 — UI 격리자의 포트로 넘긴다.
@pragma('vm:entry-point')
void _onNotification(NotificationEvent evt) {
  final SendPort? send = IsolateNameServer.lookupPortByName(kPortName);
  send?.send(evt);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KrisApp());
}

class KrisApp extends StatelessWidget {
  const KrisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '크리스',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0C162E),
      ),
      home: const WebShell(),
    );
  }
}

class WebShell extends StatefulWidget {
  const WebShell({super.key});

  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> with WidgetsBindingObserver {
  final _storage = const FlutterSecureStorage();
  InAppWebViewController? _controller;
  PullToRefreshController? _pull;
  final ReceivePort _port = ReceivePort();

  double _progress = 0;
  String? _ikey;
  bool _ikeyLoaded = false;
  bool _hasNotifPermission = true; // 배너 숨김 기본값, 실제값은 비동기로 갱신
  DateTime? _lastIssueAt; // ikey 발급 호출 스로틀

  // 중복 전송 방지(최근 200건 키)
  final Set<String> _seen = <String>{};
  final List<String> _seenOrder = <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pull = PullToRefreshController(
      settings: PullToRefreshSettings(color: const Color(0xFF0C162E)),
      onRefresh: () async => _controller?.reload(),
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // 저장된 ikey 먼저 읽기 (있으면 재발급 안 함)
    try {
      _ikey = await _storage.read(key: kIkeyKey);
    } catch (_) {}
    _ikeyLoaded = true;

    // 알림 수신 포트 등록
    IsolateNameServer.removePortNameMapping(kPortName);
    IsolateNameServer.registerPortWithName(_port.sendPort, kPortName);
    _port.listen((message) {
      if (message is NotificationEvent) _handleNotification(message);
    });

    try {
      await NotificationsListener.initialize(callbackHandle: _onNotification);
    } catch (_) {}
    await _ensureServiceRunning();
    if (mounted) setState(() {});
  }

  Future<void> _ensureServiceRunning() async {
    try {
      final granted = (await NotificationsListener.hasPermission) ?? false;
      _hasNotifPermission = granted;
      if (!granted) return;
      final running = (await NotificationsListener.isRunning) ?? false;
      if (!running) {
        await NotificationsListener.startService(
          foreground: true,
          title: '크리스',
          description: '메시지를 크리스 소식함으로 모으고 있어요.',
        );
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 설정에서 권한 켜고 돌아오면 다시 확인·시작
    if (state == AppLifecycleState.resumed) {
      _ensureServiceRunning().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  // ikey 저장
  Future<void> _saveIkey(String ik) async {
    if (!ik.startsWith('ik_')) return;
    try {
      await _storage.write(key: kIkeyKey, value: ik);
    } catch (_) {}
    _ikey = ik;
    if (mounted) setState(() {});
  }

  // 알림 1건 처리 → 서버 전송
  Future<void> _handleNotification(NotificationEvent evt) async {
    final changuk = changukOf(evt.packageName);
    if (changuk == null) return;

    final sender = (evt.title ?? '').trim();
    final body = (evt.text ?? '').trim();
    if (body.isEmpty) return; // 빈 알림은 건너뜀
    if (_isNoise(changuk, body)) return; // 요약·그룹·광고성 노이즈 제외(1:1 위주)

    // 중복 제거(앱+보낸이+본문+분 단위 시각)
    final minute = (evt.createAt ?? DateTime.now())
        .toIso8601String()
        .substring(0, 16);
    final key = '${evt.packageName}|$sender|$body|$minute';
    if (_seen.contains(key)) return;
    _seen.add(key);
    _seenOrder.add(key);
    if (_seenOrder.length > 200) {
      _seen.remove(_seenOrder.removeAt(0));
    }

    final ik = _ikey;
    if (ik == null) return; // 아직 연결(ikey) 전이면 보류

    try {
      await http.post(
        Uri.parse('$kBaseUrl/api/inbox/in'),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'x-inbox-token': ik,
        },
        body: jsonEncode({
          '창구': changuk,
          '보낸이': sender,
          '본문': body,
          // 폰에 쌓였다 늦게 보내도 시각이 정확하도록 함께 전송(선택)
          '받은때': (evt.createAt ?? DateTime.now()).toUtc().toIso8601String(),
        }),
      );
    } catch (_) {
      // 네트워크 실패는 조용히 무시(다음 알림에서 재시도)
    }
  }

  // 수집에서 뺄 노이즈 판별 (요약 알림 · 카톡 그룹/오픈채팅 · 광고성)
  bool _isNoise(String changuk, String body) {
    // "3개의 메시지", "안 읽은 메시지 N개", "새로운 메시지" 류 요약
    if (RegExp(r'\d+\s*개의?\s*(새\s*)?메시지').hasMatch(body)) return true;
    if (body.contains('읽지 않은') || body.contains('안 읽은') ||
        body.contains('새로운 메시지')) return true;
    // 카톡 그룹·오픈채팅은 본문이 "보낸이 : 내용" 형태 → 1:1 위주로 제외
    if (changuk == 'kakao' && RegExp(r'^[^\s:]{1,20}\s?:\s').hasMatch(body)) {
      return true;
    }
    return false;
  }

  Future<bool> _handleBack() async {
    final c = _controller;
    if (c != null && await c.canGoBack()) {
      await c.goBack();
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    IsolateNameServer.removePortNameMapping(kPortName);
    _port.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        if (await _handleBack() && mounted) await SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0C162E),
        body: SafeArea(
          child: Column(
            children: [
              if (!_hasNotifPermission) _permissionBanner(),
              if (_progress < 1.0)
                LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress,
                  minHeight: 2.5,
                  backgroundColor: const Color(0xFF0C162E),
                ),
              Expanded(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(kBaseUrl)),
                  pullToRefreshController: _pull,
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    useOnDownloadStart: true,
                    mediaPlaybackRequiresUserGesture: false,
                    supportZoom: false,
                    transparentBackground: true,
                    javaScriptCanOpenWindowsAutomatically: true,
                    allowsInlineMediaPlayback: true,
                  ),
                  onWebViewCreated: (c) {
                    _controller = c;
                    // 웹 → 네이티브로 ikey를 넘겨받는 창구
                    c.addJavaScriptHandler(
                      handlerName: 'genyaIkey',
                      callback: (args) {
                        if (args.isNotEmpty && args[0] != null) {
                          _saveIkey(args[0].toString());
                        }
                        return {'ok': true};
                      },
                    );
                  },
                  onLoadStop: (c, url) async {
                    _pull?.endRefreshing();
                    // ★로그인·메인 로드 후에만 발급 — 크리스 서버 화면에서, 저장된 ikey 없을 때만.
                    // 로그인 전/다른 호스트(구글 로그인 등)에선 호출 안 함.
                    // (서버는 로그인 전 호출 시 401로 조용히 실패하고 열쇠를 안 줌 → 다음 로드 때 재시도)
                    final host = url?.host ?? '';
                    final onKris = host.endsWith('genya-pwa.onrender.com');
                    final throttled = _lastIssueAt != null &&
                        DateTime.now().difference(_lastIssueAt!).inSeconds < 8;
                    if (_ikeyLoaded && _ikey == null && onKris && !throttled) {
                      _lastIssueAt = DateTime.now();
                      await c.evaluateJavascript(
                        source:
                            "window.genyaIssueIkey && window.genyaIssueIkey();",
                      );
                    }
                  },
                  onProgressChanged: (c, p) {
                    if (!mounted) return;
                    setState(() => _progress = p / 100);
                    if (p == 100) _pull?.endRefreshing();
                  },
                  onReceivedError: (c, req, err) => _pull?.endRefreshing(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _permissionBanner() {
    return Material(
      color: const Color(0xFFD6B25E),
      child: InkWell(
        onTap: () => NotificationsListener.openPermissionSettings(),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.notifications_active, color: Color(0xFF0C162E), size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '알림 접근을 허용하면 폰 메시지가 크리스 소식함에 자동으로 모입니다 — 눌러서 켜기',
                  style: TextStyle(
                    color: Color(0xFF0C162E),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: Color(0xFF0C162E)),
            ],
          ),
        ),
      ),
    );
  }
}
