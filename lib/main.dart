// 크리스 앱 — 단계 ② 안드로이드 알림 수집 + ikey 연결
// ① WebView 껍데기 위에, 폰의 카톡·문자 알림을 잡아 서버로 보낸다.
// 서버(대표 확정): https://genya-pwa.onrender.com  (서버는 이미 완성 — 안 건드림)
//  - ikey 발급: WebView에서 window.genyaIssueIkey() → 웹이 callHandler('genyaIkey','ik_…')
//  - 알림 전송: POST /api/inbox/in  헤더 x-inbox-token:<ik_…>  본문 {창구,보낸이,본문}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_notification_listener_plus/flutter_notification_listener_plus.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:workmanager/workmanager.dart';

const String kBaseUrl = 'https://genya-pwa.onrender.com';
const String kPortName = '_kris_listener_';
const String kIkeyKey = 'genya_ikey';
const String kAppVer = '0.5.0';
// ★판 279e LITE(교육생판)는 알림 수집이 없어 「알림 접근 허용」 띠가 영영 안 사라지던 것 — LITE 빌드에서는 띠를 안 그림
const bool kLite = bool.fromEnvironment('KRIS_LITE');
// ★판 279 통화 리스닝 — 갤럭시 「통화 자동 녹음」 폴더
const List<String> kCallDirs = [
  '/storage/emulated/0/Recordings/Call',
  '/storage/emulated/0/Recordings/통화 녹음',
  '/storage/emulated/0/Call',
  '/storage/emulated/0/Record/Call',
];
const String kCallSeenKey = 'call_seen';
const String kCallSinceKey = 'call_since';

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


// ★판 279g 통화녹음 훑기 — 앱 화면(열 때·10분마다)과 ★안드로이드 정기 작업(앱이 닫혀도 약 15분마다)이 함께 씀
Future<bool> callScanGranted() async {
  try {
    if (await Permission.audio.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    return false;
  } catch (_) {
    return true; // 백그라운드에서 권한을 못 물으면 폴더를 직접 읽어 본다
  }
}

// 갤럭시 통화녹음 이름 속 날짜 → ms (KST). 「이호원_251025_1650.m4a」「01012345678_20251025_165012」「…_251025165012」
int? callNameAt(String name) {
  final b = name.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '');
  final mm = RegExp(r'[_\s-]((?:20)?\d{6})[_\s-]?(\d{4}|\d{6})$').firstMatch(b);
  if (mm == null) return null;
  var d = mm.group(1)!; if (d.length == 6) d = '20$d';
  final t = (mm.group(2)! + '00').substring(0, 6);
  final dt = DateTime.tryParse('${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)}T${t.substring(0, 2)}:${t.substring(2, 4)}:${t.substring(4, 6)}+09:00');
  if (dt == null || dt.year < 2015) return null;
  return dt.millisecondsSinceEpoch;
}

Future<bool> callScanOnce({bool again = true}) async {
  const st = FlutterSecureStorage();
  final granted = await callScanGranted();
  try {
      String? ik;
      try { ik = await st.read(key: kIkeyKey); } catch (_) {}
      if (ik == null) return granted;
      String folder = '';
      List<File> files = [];
      if (granted) {
        // ★판 279l 통화녹음 폴더를 ★전부 모음 — 첫 폴더만 보던 것(옛 폴더에 갇혀 오늘 통화를 못 봄)
        final dirs = <String>{...kCallDirs};
        for (final root in ['/storage/emulated/0/Recordings', '/storage/emulated/0/Sounds', '/storage/emulated/0/Music', '/storage/emulated/0/Record']) {
          try {
            final rd = Directory(root);
            if (!await rd.exists()) continue;
            await for (final e in rd.list(recursive: true, followLinks: false)) {
              if (e is Directory && RegExp(r'(call|통화)', caseSensitive: false).hasMatch(e.path.split('/').last)) dirs.add(e.path);
            }
          } catch (_) {}
        }
        final names = <String>{};
        final used = <String>[];
        for (final d in dirs) {
          try {
            final dir = Directory(d);
            if (!await dir.exists()) continue;
            final list = await dir.list().where((e) => e is File).cast<File>().where((f) => RegExp(r'\.(m4a|amr|mp3|3gp|aac|wav|ogg)$', caseSensitive: false).hasMatch(f.path)).toList();
            if (list.isEmpty) continue;
            used.add('${d.replaceFirst('/storage/emulated/0/', '')}(${list.length})');
            for (final f in list) { if (names.add(f.uri.pathSegments.last)) files.add(f); }
          } catch (_) {}
        }
        folder = used.join(', ');
      }
      // 처음 켤 때는 지난 하루치부터
      int since = 0;
      try { since = int.tryParse(await st.read(key: kCallSinceKey) ?? '') ?? 0; } catch (_) {}
      if (since == 0 && granted) {
        since = DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch;
        try { await st.write(key: kCallSinceKey, value: '$since'); } catch (_) {}
      }
      List<String> seen = [];
      try { seen = List<String>.from(jsonDecode(await st.read(key: kCallSeenKey) ?? '[]')); } catch (_) {}
      final fresh = <File>[];
      String newest = ''; int newestAt = 0; String err = ''; int fail = 0;
      for (final f in files) {
        try {
          int m = 0;
          try { m = (await f.lastModified()).millisecondsSinceEpoch; } catch (e) { err = 'mtime:$e'; }
          final name = f.uri.pathSegments.last;
          // ★판 279j 파일 이름의 날짜(…_251025_143012)도 봄 — 수정 시각을 못 읽어도 새 통화를 놓치지 않게
          final mm = callNameAt(name);
          if (mm != null && mm <= DateTime.now().millisecondsSinceEpoch + 86400000) m = mm;
          if (m > newestAt) { newestAt = m; newest = name; }
          if (m >= since && !seen.contains(name)) fresh.add(f);
        } catch (e) { err = 'list:$e'; }
      }
      // ★판 279f 방금 한 통화가 먼저 — 최신부터 한 번에 10개
      // ★판 279k 방금 한 통화가 먼저 — 이름 속 날짜(없으면 수정 시각) 기준
      // ★판 279l 사람 이름이 적힌 통화(저장된 연락처)부터, 그 안에서 최신부터 — 카톡·메일처럼
      int at(File f) { final v = callNameAt(f.uri.pathSegments.last); if (v != null) return v; try { return f.lastModifiedSync().millisecondsSinceEpoch; } catch (_) { return 0; } }
      bool named(File f) { final b = f.uri.pathSegments.last.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '').replaceAll(RegExp(r'^(통화\s*녹음|call\s*recording)\s*', caseSensitive: false), ''); return RegExp(r'[가-힣A-Za-z]').hasMatch(b.split('_').first); }
      fresh.sort((a, b) { final na = named(a), nb = named(b); if (na != nb) return na ? -1 : 1; return at(b).compareTo(at(a)); });
      int sent = 0;
      for (final f in fresh.take(10)) {
        // 아직 녹음 중일 수 있는 파일(1분 안에 바뀐 것)은 다음 번에
        try { if (DateTime.now().difference(f.lastModifiedSync()).inSeconds < 60) continue; } catch (_) {}
        final name = f.uri.pathSegments.last;
        try {
          final len = await f.length();
          if (len > 75 * 1024 * 1024) { seen.add(name); continue; }
          final bytes = await f.readAsBytes();
          final r = await http.post(
            Uri.parse('$kBaseUrl/api/inbox/call-audio'),
            headers: {
              'Content-Type': 'application/octet-stream',
              'x-inbox-token': ik!,
              'x-call-file': Uri.encodeComponent(name),
            },
            body: bytes,
          ).timeout(const Duration(minutes: 5));
          if (r.statusCode == 200) { seen.add(name); sent++; } else { fail++; err = 'http ${r.statusCode}'; }
        } catch (e) { fail++; err = 'up:$e'; }
      }
      if (seen.length > 600) seen = seen.sublist(seen.length - 500);
      try { await st.write(key: kCallSeenKey, value: jsonEncode(seen)); } catch (_) {}
      try {
        final rs = await http.post(
          Uri.parse('$kBaseUrl/api/inbox/call-status'),
          headers: {'Content-Type': 'application/json; charset=utf-8', 'x-inbox-token': ik!},
          body: jsonEncode({'권한': granted, '폴더': folder, '파일수': files.length, '새': sent, '앱판': kAppVer,
            '후보': fresh.length, '실패': fail, '오류': err.length > 160 ? err.substring(0, 160) : err,
            '최신': newest, '최신때': newestAt, '기준때': since,
            '앞': fresh.take(3).map((f) => f.uri.pathSegments.last).join(' | ')}),
        ).timeout(const Duration(seconds: 20));
        // ★판 279i 서버가 「처음부터 다시」라 하면(통화 리스닝이 꺼져 있던 동안 본 것으로 적힌 녹음) 지난 하루치를 다시 보냄
        try {
          final jr = jsonDecode(utf8.decode(rs.bodyBytes));
          if (jr is Map && jr['다시'] == true) {
            await st.write(key: kCallSeenKey, value: '[]');
            await st.write(key: kCallSinceKey, value: '${DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch}');
            if (again) return await callScanOnce(again: false);
          }
        } catch (_) {}
      } catch (_) {}
  } catch (_) {}
  return granted;
}

// ★판 298 폰 문자 — 설계사가 크리스에서 승인한 고객 문자를 ★이 폰 번호로 보냄(문자 회사 열쇠 필요 없음)
const MethodChannel kSmsCh = MethodChannel('kris_sms');
String _smsHelloLast = '';
DateTime? _smsHelloAt;

Future<bool> smsGranted() async {
  try { return (await kSmsCh.invokeMethod<bool>('granted')) ?? false; } catch (_) { return false; }
}

Future<bool> smsSendOnce() async {
  const st = FlutterSecureStorage();
  String? ik;
  try { ik = await st.read(key: kIkeyKey); } catch (_) {}
  final granted = await smsGranted();
  if (ik == null) return granted;
  final h = {'Content-Type': 'application/json; charset=utf-8', 'x-inbox-token': ik};
  // 허용 상태를 서버에 알림(바뀌었을 때·30분마다)
  final now = DateTime.now();
  if (_smsHelloLast != '$granted' || _smsHelloAt == null || now.difference(_smsHelloAt!).inMinutes >= 30) {
    try {
      await http.post(Uri.parse('$kBaseUrl/api/phone/sms-hello'), headers: h, body: jsonEncode({'권한': granted, '앱판': kAppVer})).timeout(const Duration(seconds: 15));
      _smsHelloLast = '$granted'; _smsHelloAt = now;
    } catch (_) {}
  }
  if (!granted) return granted;
  try {
    final r = await http.get(Uri.parse('$kBaseUrl/api/phone/sms-next'), headers: h).timeout(const Duration(seconds: 20));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final list = (j is Map && j['문자'] is List) ? (j['문자'] as List) : const [];
    for (final m in list) {
      if (m is! Map) continue;
      Map res;
      try {
        final x = await kSmsCh.invokeMethod('send', {'to': '${m['to'] ?? ''}', 'body': '${m['body'] ?? ''}'});
        res = (x is Map) ? Map.from(x) : {'ok': false, 'err': '응답 없음'};
      } catch (e) { res = {'ok': false, 'err': '$e'}; }
      try {
        await http.post(Uri.parse('$kBaseUrl/api/phone/sms-done'), headers: h,
          body: jsonEncode({'id': m['id'], 'ok': res['ok'] == true, 'err': '${res['err'] ?? ''}'})).timeout(const Duration(seconds: 20));
      } catch (_) {}
    }
  } catch (_) {}
  return granted;
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      DartPluginRegistrant.ensureInitialized();
    } catch (_) {}
    try {
      await callScanOnce().timeout(const Duration(minutes: 9));
    } catch (_) {}
    try {
      await smsSendOnce().timeout(const Duration(minutes: 3));
    } catch (_) {}
    return true;
  });
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // ★판 279g 앱이 닫혀 있어도 약 15분마다 통화녹음을 올림(안드로이드가 정한 가장 짧은 간격)
  try {
    Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
    Workmanager().registerPeriodicTask(
      'kris-call-scan',
      'callScan',
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } catch (_) {}
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
  bool _hasCallPermission = true; // ★판 279 통화녹음 읽기 권한
  bool _callBusy = false;
  Timer? _callTimer;
  bool _hasSmsPermission = true; // ★판 298 문자 보내기 권한
  bool _smsBusy = false;
  Timer? _smsTimer;
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
    // ★판 279 통화녹음 — 열 때 한 번 + 10분마다
    _scanCalls();
    _callTimer = Timer.periodic(const Duration(minutes: 10), (_) => _scanCalls());
    // ★판 298 폰 문자 — 열 때 + 30초마다(앱이 열려 있는 동안 승인한 문자가 바로 나가게)
    _sendSms();
    _smsTimer = Timer.periodic(const Duration(seconds: 30), (_) => _sendSms());
  }

  Future<void> _sendSms() async {
    if (_smsBusy) return;
    _smsBusy = true;
    try {
      final granted = await smsSendOnce();
      if (mounted && granted != _hasSmsPermission) setState(() => _hasSmsPermission = granted);
    } catch (_) {
    } finally {
      _smsBusy = false;
    }
  }

  Future<void> _askSmsPermission() async {
    try {
      final st = await Permission.sms.request();
      if (!st.isGranted && (st.isPermanentlyDenied || st.isRestricted)) await openAppSettings();
    } catch (_) {}
    _sendSms();
  }

  // ── ★판 279 통화 리스닝: 통화녹음 폴더의 새 파일을 크리스 서버로 (서버가 글로 바꾸고 원본은 지움) ──
  Future<bool> _callGranted() async {
    try {
      if (await Permission.audio.isGranted) return true;
      if (await Permission.storage.isGranted) return true;
    } catch (_) {}
    return false;
  }

  Future<void> _askCallPermission() async {
    try {
      var st = await Permission.audio.request();
      if (!st.isGranted) {
        final st2 = await Permission.storage.request();
        if (st2.isGranted) st = st2;
      }
      if (!st.isGranted && (st.isPermanentlyDenied || st.isRestricted)) {
        await openAppSettings();
      }
    } catch (_) {}
    _scanCalls();
  }

  Future<void> _scanCalls() async {
    if (_callBusy) return;
    _callBusy = true;
    try {
      final granted = await callScanOnce();
      if (mounted && granted != _hasCallPermission) setState(() => _hasCallPermission = granted);
    } finally {
      _callBusy = false;
    }
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
      _scanCalls();
      _sendSms();
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
    _scanCalls();
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
          'x-inbox-token': ik!,
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
    _callTimer?.cancel();
    _smsTimer?.cancel();
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
              if (!_hasSmsPermission) _smsBanner(),
              if (!_hasCallPermission) _callBanner(),
              if (!kLite && !_hasNotifPermission) _permissionBanner(),
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
                    // ★2026-10-18 구글 로그인 「403 disallowed_useragent」 막기 — 안드 WebView UA 에 붙는 "; wv" 를
                    //   구글이 보고 임베디드 브라우저로 판정해 OAuth 를 거부한다. 일반 크롬 모바일 UA 로 바꿔 보낸다.
                    //   (내용은 그대로 웹, 서버 코드 변화 없음. 되돌리기 = 이 줄 삭제)
                    userAgent:
                        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
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
                    // ★판 394 M5 — 웹 「크리스 앱에서 바로 가져오기」 → 연락처 권한 → 폰 연락처를 크리스로(설계사가 「네」 해야 등록)
                    c.addJavaScriptHandler(
                      handlerName: 'krisContacts',
                      callback: (args) async {
                        try {
                          var st = await Permission.contacts.status;
                          if (!st.isGranted) st = await Permission.contacts.request();
                          if (!st.isGranted) return {'ok': false, 'err': '연락처 권한을 허용해 주셔야 가져올 수 있습니다(설정 → 앱 → 크리스 → 권한 → 연락처).'};
                          final x = await kSmsCh.invokeMethod('contacts');
                          final m = (x is Map) ? Map<String, dynamic>.from(x) : <String, dynamic>{};
                          if (m['ok'] != true) return {'ok': false, 'err': '${m['err'] ?? '연락처를 읽지 못했습니다'}'};
                          final ik = _ikey;
                          if (ik == null) return {'ok': false, 'err': '크리스 앱 연결 열쇠가 아직 없습니다. 잠시 뒤 다시 눌러 주세요.'};
                          final r = await http.post(Uri.parse('$kBaseUrl/api/phone/contacts'),
                              headers: {'Content-Type': 'application/json; charset=utf-8', 'x-inbox-token': ik},
                              body: jsonEncode({'연락처': m['연락처'] ?? []})).timeout(const Duration(seconds: 60));
                          final j = jsonDecode(utf8.decode(r.bodyBytes));
                          return (j is Map) ? j : {'ok': false, 'err': '서버 답을 읽지 못했습니다'};
                        } catch (e) {
                          return {'ok': false, 'err': '연락처 보내기 실패: $e'};
                        }
                      },
                    );
                    // ★판 298 웹에서 「발송해」 뒤 바로 폰 문자 보내기
                    c.addJavaScriptHandler(
                      handlerName: 'krisSmsNow',
                      callback: (args) {
                        _sendSms();
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

  Widget _smsBanner() {
    return Material(
      color: const Color(0xFFBFDBFE),
      child: InkWell(
        onTap: _askSmsPermission,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.sms, color: Color(0xFF0C162E), size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '문자 보내기 허용 — 내가 승인한 고객 문자를 크리스가 내 번호로 보내요 (눌러서 허용)',
                  style: TextStyle(color: Color(0xFF0C162E), fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
              Icon(Icons.chevron_right, color: Color(0xFF0C162E)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _callBanner() {
    return Material(
      color: const Color(0xFFFDE68A),
      child: InkWell(
        onTap: _askCallPermission,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.phone_in_talk, color: Color(0xFF0C162E), size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '통화 녹음 읽기 허용 — 고객 통화를 크리스가 글로 정리해 소식함에 넣어요 (눌러서 허용)',
                  style: TextStyle(color: Color(0xFF0C162E), fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
              Icon(Icons.chevron_right, color: Color(0xFF0C162E)),
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
