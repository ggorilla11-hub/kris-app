// ★판 298 폰 문자 — 크리스가 설계사 폰 번호로 문자를 보냄(설계사가 앱에서 승인한 것만).
// CI 가 `flutter create --template=plugin packages/kris_sms` 로 플러그인 뼈대를 만든 뒤 이 파일로 덮어씀.
// 채널 이름 kris_sms · 메서드 granted() · send({to, body}) → {ok, err?}
package com.ohwantbalance.kris_sms

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class KrisSmsPlugin : FlutterPlugin, MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var ctx: Context

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    ctx = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "kris_sms")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  private fun granted(): Boolean =
    ctx.checkSelfPermission(android.Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "granted" -> result.success(granted())
      "send" -> send(call.argument<String>("to") ?: "", call.argument<String>("body") ?: "", result)
      else -> result.notImplemented()
    }
  }

  private fun send(to: String, body: String, result: Result) {
    if (to.isBlank() || body.isBlank()) { result.success(mapOf("ok" to false, "err" to "번호나 글이 비었습니다")); return }
    if (!granted()) { result.success(mapOf("ok" to false, "err" to "문자 보내기 권한이 없습니다")); return }
    val main = Handler(Looper.getMainLooper())
    try {
      val sm: SmsManager = if (Build.VERSION.SDK_INT >= 31) ctx.getSystemService(SmsManager::class.java) else @Suppress("DEPRECATION") SmsManager.getDefault()
      val parts = sm.divideMessage(body)
      val action = "com.ohwantbalance.kris_sms.SENT." + System.nanoTime()
      val left = AtomicInteger(parts.size)
      val failCode = AtomicInteger(0)
      val done = AtomicBoolean(false)
      val rcv = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
          if (resultCode != Activity.RESULT_OK) failCode.set(resultCode)
          if (left.decrementAndGet() <= 0 && done.compareAndSet(false, true)) {
            try { ctx.unregisterReceiver(this) } catch (e: Exception) {}
            val code = failCode.get()
            main.post { result.success(if (code == 0) mapOf("ok" to true) else mapOf("ok" to false, "err" to "통신사가 받지 않았습니다(코드 $code)")) }
          }
        }
      }
      if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(rcv, IntentFilter(action), Context.RECEIVER_NOT_EXPORTED)
      else ctx.registerReceiver(rcv, IntentFilter(action))
      val pis = ArrayList<PendingIntent>()
      for (k in parts.indices) {
        pis.add(PendingIntent.getBroadcast(ctx, (System.nanoTime() % 100000).toInt() + k, Intent(action).setPackage(ctx.packageName), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
      }
      if (parts.size <= 1) sm.sendTextMessage(to, null, body, pis[0], null)
      else sm.sendMultipartTextMessage(to, null, parts, pis, null)
      main.postDelayed({
        if (done.compareAndSet(false, true)) {
          try { ctx.unregisterReceiver(rcv) } catch (e: Exception) {}
          result.success(mapOf("ok" to true, "err" to "결과 확인 시간 초과 — 폰에는 넘겼습니다"))
        }
      }, 30000)
    } catch (e: Exception) {
      result.success(mapOf("ok" to false, "err" to (e.message ?: "보내기 오류")))
    }
  }
}
