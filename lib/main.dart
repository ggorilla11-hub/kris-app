// 크리스 앱 — 단계 ① WebView 껍데기
// 기존 크리스(지니야) 웹을 네이티브 앱 안에서 그대로 띄운다.
// 서버 주소(대표 확정 2026-10-16): https://genya-pwa.onrender.com
// 다음 단계(②~)에서 ikey 연결·알림/통화/메일 수집·푸시가 이 위에 붙는다.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// ★서버 베이스 URL — 한 곳에서만 관리 (명세서 2·3번)
const String kBaseUrl = 'https://genya-pwa.onrender.com';

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
        colorSchemeSeed: const Color(0xFF0C162E), // 크리스 네이비
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

class _WebShellState extends State<WebShell> {
  InAppWebViewController? _controller;
  PullToRefreshController? _pull;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _pull = PullToRefreshController(
      settings: PullToRefreshSettings(color: const Color(0xFF0C162E)),
      onRefresh: () async {
        await _controller?.reload();
      },
    );
  }

  // 안드로이드 뒤로가기: 웹에서 뒤로 갈 수 있으면 웹을 뒤로, 아니면 앱 종료
  Future<bool> _handleBack() async {
    final c = _controller;
    if (c != null && await c.canGoBack()) {
      await c.goBack();
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final shouldExit = await _handleBack();
        if (shouldExit && mounted) {
          await SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0C162E),
        body: SafeArea(
          child: Column(
            children: [
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
                    // 구글 로그인 등 외부 인증 흐름이 WebView 안에서 열리도록
                    useShouldOverrideUrlLoading: false,
                    javaScriptCanOpenWindowsAutomatically: true,
                    allowsInlineMediaPlayback: true,
                  ),
                  onWebViewCreated: (c) => _controller = c,
                  onProgressChanged: (c, p) {
                    if (!mounted) return;
                    setState(() => _progress = p / 100);
                    if (p == 100) _pull?.endRefreshing();
                  },
                  onReceivedError: (c, req, err) {
                    _pull?.endRefreshing();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
