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
      "contactsGranted" -> result.success(ctx.checkSelfPermission(android.Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED)
      "contacts" -> Thread { val r = contacts(); Handler(Looper.getMainLooper()).post { result.success(r) } }.start()
      else -> result.notImplemented()
    }
  }

  // ★판 394 M5 — 폰 연락처 읽기(READ_CONTACTS). 이름·전화·메일·생일·회사·직함·메모만. 사진·통화기록은 안 읽음. 최대 20000명.
  private fun contacts(): Map<String, Any> {
    if (ctx.checkSelfPermission(android.Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED)
      return mapOf("ok" to false, "err" to "연락처 권한이 없습니다")
    val by = LinkedHashMap<Long, MutableMap<String, Any>>()
    val phones = HashMap<Long, ArrayList<String>>()
    val mails = HashMap<Long, ArrayList<String>>()
    try {
      val cr = ctx.contentResolver
      val uri = android.provider.ContactsContract.Data.CONTENT_URI
      val cols = arrayOf(android.provider.ContactsContract.Data.CONTACT_ID, android.provider.ContactsContract.Data.DISPLAY_NAME, android.provider.ContactsContract.Data.MIMETYPE,
        android.provider.ContactsContract.Data.DATA1, android.provider.ContactsContract.Data.DATA2, android.provider.ContactsContract.Data.DATA4)
      cr.query(uri, cols, null, null, null)?.use { c ->
        while (c.moveToNext()) {
          val id = c.getLong(0); val nm = c.getString(1) ?: continue; val mt = c.getString(2) ?: ""; val d1 = c.getString(3) ?: ""; val d2 = c.getInt(4); val d4 = c.getString(5) ?: ""
          if (!by.containsKey(id) && by.size >= 20000) continue
          val m = by.getOrPut(id) { mutableMapOf<String, Any>("이름" to nm) }
          when (mt) {
            android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE -> phones.getOrPut(id) { ArrayList() }.add(d1)
            android.provider.ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE -> mails.getOrPut(id) { ArrayList() }.add(d1)
            android.provider.ContactsContract.CommonDataKinds.Event.CONTENT_ITEM_TYPE -> if (d2 == android.provider.ContactsContract.CommonDataKinds.Event.TYPE_BIRTHDAY) m["생일"] = d1
            android.provider.ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE -> { if (d1.isNotBlank()) m["회사"] = d1; if (d4.isNotBlank()) m["직함"] = d4 }
            android.provider.ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE -> if (d1.isNotBlank()) m["메모"] = d1.take(120)
          }
        }
      }
    } catch (e: Exception) { return mapOf("ok" to false, "err" to (e.message ?: "연락처를 읽지 못했습니다")) }
    for ((id, m) in by) { m["전화"] = phones[id] ?: ArrayList<String>(); m["메일"] = mails[id] ?: ArrayList<String>() }
    return mapOf("ok" to true, "연락처" to ArrayList(by.values))
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
