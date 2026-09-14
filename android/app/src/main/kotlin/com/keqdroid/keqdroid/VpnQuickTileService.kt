package com.keqdroid.keqdroid

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.database.ContentObserver
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.net.VpnService
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast

class VpnQuickTileService : TileService() {

    companion object {
        // Монохромный вектор (силуэт на прозрачном фоне): QS-плитки тинтуют иконку,
        // и полноцветный ic_launcher_foreground превращается в белый кружок.
        // Тот же ресурс стоит в android:icon сервиса в манифесте, чтобы и в редакторе
        // плиток (где берётся манифестная иконка) показывался логотип, а не пустой круг.
        private val TILE_ICON_RES = R.drawable.ic_launcher_monochrome

        // Статусы, при которых нажатие означает «выключить». connecting здесь не
        // случайно: см. updateTileFromPrefs — плитка на нём остаётся нажимаемой.
        private val ACTIVE_STATUSES = setOf("connected", "running", "connecting", "starting")
    }

    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) {
            updateTileFromPrefs()
        }
    }

    // Retry mechanism for cases when qsTile is not yet available
    private var retryHandler: Handler? = null
    private val retryRunnable = Runnable { updateTileFromPrefs() }
    private val RETRY_DELAY_MS = 500L
    private var retryCount = 0
    private val MAX_RETRIES = 10

    // BroadcastReceiver for status updates from service
    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == KeqdisVpnService.BROADCAST_VPN_STATUS_CHANGED) {
                updateTileFromPrefs()
            }
        }
    }

    // Короткая привязка к KeqdisVpnService, пока пользователь смотрит шторку.
    // Если процесс убили с активным VPN, в prefs остаётся connecting/connected,
    // и тайл висел бы так вечно (connecting → STATE_UNAVAILABLE даже не нажать).
    // BIND_AUTO_CREATE создаёт свежий инстанс сервиса, его onCreate() сверяет
    // prefs с реальным статусом и чинит их → ContentObserver обновит тайл.
    private var healConnection: ServiceConnection? = null

    private fun healStaleStatusViaBind() {
        if (healConnection != null) return
        val status = getSharedPreferences(KeqdisVpnService.PREFS_QS, MODE_PRIVATE)
            .getString(KeqdisVpnService.KEY_QS_STATUS, "disconnected")
            ?.lowercase()
            ?: "disconnected"
        if (status == "disconnected" || status == "error") return
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {}
            override fun onServiceDisconnected(name: ComponentName?) {}
        }
        healConnection = try {
            if (bindService(
                    Intent(this, KeqdisVpnService::class.java),
                    conn,
                    Context.BIND_AUTO_CREATE,
                )
            ) conn else null
        } catch (e: Exception) {
            NativeLog.w("KEQDIS_QS", "heal bind failed: ${e.message}")
            null
        }
    }

    private fun releaseHealBind() {
        healConnection?.let { runCatching { unbindService(it) } }
        healConnection = null
    }

    override fun onStartListening() {
        super.onStartListening()
        try {
            contentResolver.registerContentObserver(
                VpnStatusProvider.statusUri(this),
                false,
                observer
            )
        } catch (e: Exception) {
            NativeLog.e("KEQDIS", "Failed to register content observer: ${e.message}")
        }

        try {
            val filter = IntentFilter(KeqdisVpnService.BROADCAST_VPN_STATUS_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(statusReceiver, filter, RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(statusReceiver, filter)
            }
        } catch (e: Exception) {
            NativeLog.e("KEQDIS", "Failed to register broadcast receiver: ${e.message}")
        }

        retryCount = 0
        healStaleStatusViaBind()
        updateTileFromPrefs()
    }

    override fun onStopListening() {
        super.onStopListening()
        retryHandler?.removeCallbacks(retryRunnable)
        retryHandler = null
        retryCount = 0
        releaseHealBind()
        try {
            contentResolver.unregisterContentObserver(observer)
        } catch (_: Exception) {}
        try {
            unregisterReceiver(statusReceiver)
        } catch (_: Exception) {}
    }

    override fun onClick() {
        super.onClick()
        // onClick исполняется в фоновом процессе: вылетевшее отсюда исключение
        // система гасит молча, без диалога и без следа на экране — для человека
        // плитка просто «дёргается и не включается». Поэтому ни один шаг ниже не
        // имеет права падать наружу, и каждая ветка пишется в лог.
        runCatching { handleClick() }.onFailure { t ->
            NativeLog.e("KEQDIS_QS", "onClick failed: $t", t)
            toast(R.string.tile_error_start)
        }
    }

    private fun handleClick() {
        val prefs = getSharedPreferences(KeqdisVpnService.PREFS_QS, MODE_PRIVATE)
        val status = (prefs.getString(KeqdisVpnService.KEY_QS_STATUS, "disconnected")
            ?: "disconnected").lowercase()
        NativeLog.i("KEQDIS_QS", "onClick: status=$status")

        // Запись в prefs переживает смерть процесса, а туннель — нет.
        //
        // На агрессивных прошивках (MIUI/HyperOS) приложение убивают, не дав
        // сервису доработать до `onDestroy`, и в `qs_status` навсегда остаётся
        // «connected». Плитка верила записи, слала ACTION_STOP в мёртвый сервис
        // и человек видел ровно «плитка дёрнулась, ничего не случилось».
        // Приложение при этом подключалось нормально — отсюда и жалоба «из
        // шторки тишина, приходится проваливаться внутрь».
        //
        // Сверяем с [KeqdisVpnService.liveStatus]: оно живёт в памяти процесса и
        // после его перезапуска равно «disconnected». Расходится с prefs —
        // значит запись протухла, чиним и идём подключаться.
        val live = KeqdisVpnService.liveStatus.lowercase()
        if (status in ACTIVE_STATUSES && live !in ACTIVE_STATUSES) {
            NativeLog.w(
                "KEQDIS_QS",
                "onClick: stale persisted status '$status' (live='$live') → healing and connecting",
            )
            getSharedPreferences(KeqdisVpnService.PREFS_QS, MODE_PRIVATE)
                .edit()
                .putString(KeqdisVpnService.KEY_QS_STATUS, "disconnected")
                .apply()
        } else if (status in ACTIVE_STATUSES) {
            // Работает (или залип на connecting) — глушим напрямую, без toggle.
            startService(Intent(this, KeqdisVpnService::class.java).apply {
                action = KeqdisVpnService.ACTION_STOP
            })
            return
        }

        val start = KeqdisVpnService.snapshotStartIntent(this)
        if (start == null) {
            NativeLog.i("KEQDIS_QS", "onClick: no usable server snapshot → opening app")
            openAppForConnect()
            return
        }

        // Согласие на VPN спрашивает только окно: VpnService.prepare отдаёт
        // интент под startActivityForResult. Невидимое окно спросит его и
        // само же подключит — открывать ради диалога всё приложение незачем.
        if (KeqdisVpnService.startsTunnel(start) && VpnService.prepare(this) != null) {
            NativeLog.i("KEQDIS_QS", "onClick: no VPN consent → quick connect window")
            openQuickConnect()
            return
        }
        if (directStartBlocked()) {
            NativeLog.i("KEQDIS_QS", "onClick: this firmware blocks the tile → quick connect window")
            openQuickConnect()
            return
        }

        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(start) else startService(start)
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException на Android 12+: право
            // на фоновый старт отняли («Ограничить фоновую активность»,
            // выключенный автозапуск прошивки). Из окна старт разрешён всегда.
            NativeLog.e("KEQDIS_QS", "onClick: service start refused by system: $e")
            rememberDirectStartBlocked()
            openQuickConnect()
            return
        }
        verifyStarted()
    }

    /// Проверяет, что сервис действительно поднялся, и подключает через окно, если нет.
    ///
    /// Нужно потому, что отказ бывает БЕЗ исключения. `startForegroundService`
    /// возвращает управление нормально, а прошивка (ColorOS/MIUI и родня с
    /// «Автозапуском») старт молча глотает — снаружи это ровно «плитка
    /// дёрнулась и тишина», без единого следа. Стоковый Android такой старт
    /// пропускает: согласие на VPN — само по себе право на фоновый старт
    /// (REASON_OP_ACTIVATE_VPN в ActiveServices, с Android 12).
    ///
    /// Сверяемся с [KeqdisVpnService.liveStatus]: сервис выставляет его прямо в
    /// onStartCommand, поэтому «disconnected» через паузу означает, что до
    /// onStartCommand дело не дошло вовсе. Сверяться с рабочим статусом было
    /// нельзя: его ставят уже за opMutex, и застрявший стоп или неторопливое
    /// ядро выглядели бы как запрет системы — человек получал обвинение
    /// прошивке на ровном месте.
    ///
    /// Задержка — компромисс. Меньше секунды не хватает даже здоровому старту
    /// (сервис успевает только создаться), а чем она больше, тем вероятнее,
    /// что шторку уже закрыли и окно из неё не откроется (см. openQuickConnect).
    private fun verifyStarted() {
        android.os.Handler(mainLooper).postDelayed({
            val live = KeqdisVpnService.liveStatus.lowercase()
            if (live !in ACTIVE_STATUSES) {
                NativeLog.e(
                    "KEQDIS_QS",
                    "onClick: service did not come up (live='$live') — likely blocked by the OEM",
                )
                rememberDirectStartBlocked()
                openQuickConnect(retryHelps = true)
            }
        }, 2500)
    }

    /**
     * Не отказала ли уже эта прошивка плитке в прямом старте сервиса.
     *
     * Запомненный отказ ведёт нажатие сразу в окно — без 2,5 с ожидания на
     * каждое. Помним до обновления системы: с ней меняется и прошивка с её
     * запретами. Разрешённый потом автозапуск это не снимет, но окно работает
     * и так; теряется лишь то, что шторка после нажатия сворачивается.
     */
    private fun directStartBlocked(): Boolean =
        getSharedPreferences(KeqdisVpnService.PREFS_QS, MODE_PRIVATE)
            .getString(KeqdisVpnService.KEY_QS_DIRECT_START_BLOCKED_ON, null) == Build.FINGERPRINT

    private fun rememberDirectStartBlocked() {
        getSharedPreferences(KeqdisVpnService.PREFS_QS, MODE_PRIVATE)
            .edit()
            .putString(KeqdisVpnService.KEY_QS_DIRECT_START_BLOCKED_ON, Build.FINGERPRINT)
            .apply()
    }

    /**
     * Подключиться через невидимое окно [QuickConnectActivity].
     *
     * Окно из шторки открывается, только пока она открыта: на Android 14+
     * SystemUI без «жетона» нажатия молча пропускает запуск (CustomTile,
     * «Launching activity before click»), ниже его режет запрет фоновых окон.
     * Если окно так и не открылось, говорим об этом вслух — иначе нажатие
     * кончается ничем. [retryHelps] — отказ только что выяснился по
     * истечении паузы: следующее нажатие пойдёт в окно сразу, пока шторка
     * открыта, и сработает.
     */
    private fun openQuickConnect(retryHelps: Boolean = false) {
        val intent = Intent(this, QuickConnectActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        launchActivity(intent) { launchedAt ->
            android.os.Handler(mainLooper).postDelayed({
                if (QuickConnectActivity.openedAt >= launchedAt) return@postDelayed
                if (KeqdisVpnService.liveStatus.lowercase() in ACTIVE_STATUSES) return@postDelayed
                NativeLog.w("KEQDIS_QS", "quick connect window did not open")
                toast(if (retryHelps) R.string.tile_error_blocked else R.string.tile_error_open_app)
            }, 2000)
        }
    }

    private fun openAppForConnect() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ?.putExtra("action", "connect_from_notification")
            ?: Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra("action", "connect_from_notification")
            }
        launchActivity(launchIntent)
    }

    /// Открыть окно и свернуть шторку. [onLaunched] получает момент запуска
    /// (elapsedRealtime) — уже после снятия блокировки экрана, если она была.
    private fun launchActivity(launchIntent: Intent, onLaunched: ((Long) -> Unit)? = null) {
        val open = Runnable {
            val launchedAt = android.os.SystemClock.elapsedRealtime()
            try {
                // Collapse QS panel and open the app.
                if (Build.VERSION.SDK_INT >= 34) {
                    // Android 14+ - startActivityAndCollapse(Intent) is forbidden, must use PendingIntent
                    val pendingIntent = PendingIntent.getActivity(
                        this,
                        0,
                        launchIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                    startActivityAndCollapse(pendingIntent)
                } else if (Build.VERSION.SDK_INT >= 24) {
                    @Suppress("DEPRECATION")
                    startActivityAndCollapse(launchIntent)
                } else {
                    startActivity(launchIntent)
                }
            } catch (e: Exception) {
                // Прошивки с урезанным фоновым запуском активностей (MIUI/HyperOS
                // и родня) режут запуск из шторки. Пробуем напрямую, а если и это
                // не проходит — говорим вслух, иначе нажатие выглядит как «ничего».
                NativeLog.e("KEQDIS_QS", "startActivityAndCollapse failed: $e")
                runCatching { startActivity(launchIntent) }.onFailure {
                    NativeLog.e("KEQDIS_QS", "startActivity fallback failed: $it")
                    toast(R.string.tile_error_open_app)
                    return@Runnable
                }
            }
            onLaunched?.invoke(launchedAt)
        }

        // На заблокированном экране активность просто не покажется: система
        // требует сначала снять блокировку и лишь потом выполнять действие.
        if (Build.VERSION.SDK_INT >= 24 && isLocked) unlockAndRun(open) else open.run()
    }

    private fun toast(resId: Int) {
        runCatching { Toast.makeText(this, resId, Toast.LENGTH_LONG).show() }
    }

    private fun updateTileFromPrefs() {
        if (Build.VERSION.SDK_INT < 24) return

        val persisted = getSharedPreferences(KeqdisVpnService.PREFS_QS, MODE_PRIVATE)
            .getString(KeqdisVpnService.KEY_QS_STATUS, "disconnected")
            ?.lowercase()
            ?: "disconnected"

        // Та же сверка, что и в [handleClick]: запись пережила процесс, а
        // туннель — нет. Без неё плитка ещё и ГОРИТ включённой при выключенном
        // VPN, то есть врёт до первого нажатия.
        val live = KeqdisVpnService.liveStatus.lowercase()
        val status = if (persisted in ACTIVE_STATUSES && live !in ACTIVE_STATUSES) {
            "disconnected"
        } else {
            persisted
        }

        NativeLog.d(
            "KEQDIS_QS",
            "updateTileFromPrefs: status=$status (persisted=$persisted, live=$live)",
        )

        val tileObj = qsTile
        if (tileObj == null) {
            // Retry mechanism: schedule another attempt if qsTile is not available yet
            if (retryCount < MAX_RETRIES) {
                NativeLog.d("KEQDIS_QS", "updateTileFromPrefs: qsTile is null, scheduling retry (${retryCount + 1}/$MAX_RETRIES)")
                retryHandler?.removeCallbacks(retryRunnable)
                retryHandler = Handler(Looper.getMainLooper())
                retryHandler?.postDelayed(retryRunnable, RETRY_DELAY_MS)
                retryCount++
            } else {
                NativeLog.w("KEQDIS_QS", "updateTileFromPrefs: max retries reached, giving up")
                retryCount = 0
            }
            return
        }

        // Reset retry counter if we successfully got the tile
        retryCount = 0
        retryHandler?.removeCallbacks(retryRunnable)

        tileObj.label = "Keqdis"
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tileObj.icon = android.graphics.drawable.Icon.createWithResource(this, TILE_ICON_RES)
        }
        
        // connecting раньше был STATE_UNAVAILABLE — «идёт подключение, не мешай».
        // Беда в том, что нажатие по недоступной плитке система не доставляет
        // вовсе: стоило процессу умереть на середине коннекта (агрессивные OEM-
        // прошивки это делают), и в prefs навсегда оставался connecting — плитка
        // отвечала на палец только анимацией. Держим её нажимаемой: клик на
        // connecting = остановить, и залипшее состояние снимается руками.
        val connecting = status == "connecting" || status == "starting"
        tileObj.state = when {
            status == "connected" || status == "running" || connecting -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tileObj.subtitle = if (connecting) getString(R.string.tile_connecting) else null
        }
        NativeLog.d("KEQDIS_QS", "updateTileFromPrefs: new tile.state=${tileObj.state}")
        tileObj.updateTile()
    }
}
