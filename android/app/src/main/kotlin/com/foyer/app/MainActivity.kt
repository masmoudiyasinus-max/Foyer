package com.foyer.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.foyer.intercom/audio"
    private var wakeLock: PowerManager.WakeLock? = null
    private var alarmWakeLock: PowerManager.WakeLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var currentVolumeCeiling: Double = 0.75

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private var sensorManager: SensorManager? = null
    private var stepSensor: Sensor? = null
    private var stepCount: Int = 0
    private var lastAccelStepTime: Long = 0L
    private var stepWakeLock: PowerManager.WakeLock? = null
    private var methodChannel: MethodChannel? = null
    private var isFromAlarmPending: Boolean = false

    private var locationManager: LocationManager? = null
    private val locationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            val data = mapOf(
                "latitude" to location.latitude,
                "longitude" to location.longitude,
                "accuracy" to location.accuracy.toDouble(),
                "speed" to location.speed.toDouble(),
                "altitude" to location.altitude,
                "timestamp" to location.time
            )
            runOnUiThread {
                methodChannel?.invokeMethod("onLocationUpdate", data)
            }
        }
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private val stepListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent?) {
            if (event == null) return
            if (event.sensor.type == Sensor.TYPE_STEP_DETECTOR) {
                stepCount++
            } else if (event.sensor.type == Sensor.TYPE_ACCELEROMETER) {
                val x = event.values[0]
                val y = event.values[1]
                val z = event.values[2]
                val magnitude = Math.sqrt((x * x + y * y + z * z).toDouble())
                val now = System.currentTimeMillis()
                if (magnitude > 12.5 && (now - lastAccelStepTime) > 350) {
                    lastAccelStepTime = now
                    stepCount++
                }
            }
        }
        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }

    private fun handleAlarmIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("FROM_ALARM", false) == true) {
            try {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                if (alarmWakeLock == null) {
                    @Suppress("DEPRECATION")
                    alarmWakeLock = powerManager.newWakeLock(
                        PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                        "Foyer:AlarmWakeLock"
                    )
                }
                if (alarmWakeLock?.isHeld == true) {
                    alarmWakeLock?.release()
                }
                alarmWakeLock?.acquire(30000L) // 30s dedicated wake
            } catch (t: Throwable) {
                t.printStackTrace()
            }

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    setShowWhenLocked(true)
                    setTurnScreenOn(true)
                    val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? android.app.KeyguardManager
                    keyguardManager?.requestDismissKeyguard(this, null)
                } else {
                    @Suppress("DEPRECATION")
                    window.addFlags(
                        WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                    )
                }
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } catch (t: Throwable) {
                t.printStackTrace()
            }

            if (methodChannel != null) {
                methodChannel?.invokeMethod("onAlarmTriggered", null)
            } else {
                isFromAlarmPending = true
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleAlarmIntent(intent)

        // Lockscreen bypass & screen turn on - safely wrapped for OEM skins (MIUI, HyperOS)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                )
            }
        } catch (t: Throwable) {
            t.printStackTrace()
        }

        // Register Wi-Fi NetworkCallback for automatic BSSID detection & foyer switching
        registerNetworkCallback()

        // Acquire Wi-Fi MulticastLock and High-Performance WifiLock to prevent UDP throttling
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wifiManager?.createMulticastLock("FoyerMulticastLock")
            multicastLock?.setReferenceCounted(true)
            multicastLock?.acquire()

            wifiLock = wifiManager?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "FoyerWifiLock")
            wifiLock?.setReferenceCounted(false)
            wifiLock?.acquire()
        } catch (t: Throwable) {
            t.printStackTrace()
        }
    }

    private fun registerNetworkCallback() {
        try {
            connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()

            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    super.onAvailable(network)
                    notifyCurrentWifiBssid()
                }

                override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                    super.onCapabilitiesChanged(network, networkCapabilities)
                    if (networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                        notifyCurrentWifiBssid()
                    }
                }
            }

            connectivityManager?.registerNetworkCallback(request, networkCallback!!)
        } catch (t: Throwable) {
            t.printStackTrace()
        }
    }

    private fun notifyCurrentWifiBssid() {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            val connectionInfo = wifiManager?.connectionInfo
            val bssid = connectionInfo?.bssid
            if (bssid != null && bssid.isNotEmpty() && bssid != "02:00:00:00:00:00") {
                runOnUiThread {
                    methodChannel?.invokeMethod("onWifiConnected", bssid)
                }
            }
        } catch (t: Throwable) {
            t.printStackTrace()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAlarmIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel

        if (isFromAlarmPending) {
            channel.invokeMethod("onAlarmTriggered", null)
        }

        notifyCurrentWifiBssid()

        channel.setMethodCallHandler { call, result ->
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

            when (call.method) {
                "setSpeakerphoneOn" -> {
                    val enable = call.argument<Boolean>("enable") ?: true
                    try {
                        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                        audioManager.isSpeakerphoneOn = enable
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("AUDIO_ERROR", e.message, null)
                    }
                }

                "routeAudioToAlarm" -> {
                    try {
                        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val playbackAttributes = AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_ALARM)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build()
                            val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                                .setAudioAttributes(playbackAttributes)
                                .build()
                            audioManager.requestAudioFocus(focusRequest)
                        } else {
                            @Suppress("DEPRECATION")
                            audioManager.requestAudioFocus(
                                null,
                                AudioManager.STREAM_ALARM,
                                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                            )
                        }
                        audioManager.isSpeakerphoneOn = true
                        applyVolumeCeiling(audioManager, currentVolumeCeiling)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ALARM_ROUTING_ERROR", e.message, null)
                    }
                }

                "wakeDevice" -> {
                    try {
                        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (wakeLock == null) {
                            @Suppress("DEPRECATION")
                            wakeLock = powerManager.newWakeLock(
                                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                                "Foyer:WakeLock"
                            )
                        }
                        wakeLock?.acquire(10000) // 10 seconds wake

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                            try {
                                setShowWhenLocked(true)
                                setTurnScreenOn(true)
                            } catch (t: Throwable) {
                                t.printStackTrace()
                            }
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WAKE_ERROR", e.message, null)
                    }
                }

                "setVolumeCeiling" -> {
                    val ceiling = call.argument<Double>("ceiling") ?: 0.75
                    try {
                        applyVolumeCeiling(audioManager, ceiling)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("VOLUME_ERROR", e.message, null)
                    }
                }

                "startEmergencyVibration" -> {
                    try {
                        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as android.os.VibratorManager
                            vibratorManager.defaultVibrator
                        } else {
                            @Suppress("DEPRECATION")
                            getSystemService(Context.VIBRATOR_SERVICE) as android.os.Vibrator
                        }
                        val pattern = longArrayOf(0, 800, 300, 800, 300)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            vibrator.vibrate(android.os.VibrationEffect.createWaveform(pattern, 0))
                        } else {
                            @Suppress("DEPRECATION")
                            vibrator.vibrate(pattern, 0)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("VIBRATION_ERROR", e.message, null)
                    }
                }

                "stopEmergencyVibration" -> {
                    try {
                        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as android.os.VibratorManager
                            vibratorManager.defaultVibrator
                        } else {
                            @Suppress("DEPRECATION")
                            getSystemService(Context.VIBRATOR_SERVICE) as android.os.Vibrator
                        }
                        vibrator.cancel()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("VIBRATION_ERROR", e.message, null)
                    }
                }

                "checkInitialAlarm" -> {
                    val pending = isFromAlarmPending || (intent?.getBooleanExtra("FROM_ALARM", false) == true)
                    isFromAlarmPending = false
                    intent?.removeExtra("FROM_ALARM")
                    result.success(pending)
                }

                "startStepDetector" -> {
                    try {
                        stepCount = 0
                        lastAccelStepTime = 0L
                        if (sensorManager == null) {
                            sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
                        }
                        stepSensor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR, true)
                                ?: sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)
                                ?: sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
                        } else {
                            sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)
                                ?: sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
                        }
                        if (stepSensor != null) {
                            sensorManager?.registerListener(stepListener, stepSensor, SensorManager.SENSOR_DELAY_FASTEST)
                        }

                        // Maintain CPU execution in background for up to 10 min Smart Wake check window
                        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (stepWakeLock == null) {
                            stepWakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Foyer:StepWakeLock")
                        }
                        if (stepWakeLock?.isHeld == true) {
                            stepWakeLock?.release()
                        }
                        stepWakeLock?.acquire(10 * 60 * 1000L) // 10 minutes max after first alarm dismissal

                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SENSOR_ERROR", e.message, null)
                    }
                }

                "getStepCount" -> {
                    result.success(stepCount)
                }

                "stopStepDetector" -> {
                    try {
                        sensorManager?.unregisterListener(stepListener)
                        if (stepWakeLock?.isHeld == true) {
                            stepWakeLock?.release()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SENSOR_ERROR", e.message, null)
                    }
                }

                "setAlarmClock" -> {
                    val triggerTimeMs = call.argument<Long>("triggerTimeMs") ?: 0L
                    try {
                        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                        val intent = Intent(this, MainActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                            putExtra("FROM_ALARM", true)
                        }
                        val pendingIntent = PendingIntent.getActivity(
                            this,
                            1001,
                            intent,
                            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
                        )
                        val alarmClockInfo = AlarmManager.AlarmClockInfo(triggerTimeMs, pendingIntent)
                        alarmManager.setAlarmClock(alarmClockInfo, pendingIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ALARM_ERROR", e.message, null)
                    }
                }

                "cancelAlarmClock" -> {
                    try {
                        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                        val intent = Intent(this, MainActivity::class.java)
                        val pendingIntent = PendingIntent.getActivity(
                            this,
                            1001,
                            intent,
                            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
                        )
                        alarmManager.cancel(pendingIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ALARM_ERROR", e.message, null)
                    }
                }

                "getWifiBssid" -> {
                    try {
                        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                        val connectionInfo = wifiManager?.connectionInfo
                        val bssid = connectionInfo?.bssid
                        result.success(bssid)
                    } catch (e: Exception) {
                        result.error("WIFI_ERROR", e.message, null)
                    }
                }

                "canRequestPackageInstalls" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        result.success(packageManager.canRequestPackageInstalls())
                    } else {
                        result.success(true)
                    }
                }

                "openInstallPermissionSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val manageIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                data = Uri.parse("package:$packageName")
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(manageIntent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERROR", e.message, null)
                    }
                }

                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                if (!packageManager.canRequestPackageInstalls()) {
                                    val manageIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                        data = Uri.parse("package:$packageName")
                                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                    }
                                    startActivity(manageIntent)
                                    result.success(false)
                                    return@setMethodCallHandler
                                }
                            }

                            val apkFile = File(filePath)
                            if (apkFile.exists()) {
                                val contentUri = FileProvider.getUriForFile(
                                    this,
                                    "com.foyer.app.fileprovider",
                                    apkFile
                                )
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(contentUri, "application/vnd.android.package-archive")
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                                }
                                startActivity(intent)
                                result.success(true)
                            } else {
                                result.error("FILE_NOT_FOUND", "Fichier APK introuvable : $filePath", null)
                            }
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_PATH", "Chemin de fichier null", null)
                    }
                }

                "startLocationUpdates" -> {
                    try {
                        if (locationManager == null) {
                            locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
                        }
                        val hasFine = checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
                        val hasCoarse = checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
                        if (hasFine || hasCoarse) {
                            if (locationManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true) {
                                locationManager?.requestLocationUpdates(
                                    LocationManager.GPS_PROVIDER,
                                    2000L,
                                    1f,
                                    locationListener
                                )
                            }
                            if (locationManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true) {
                                locationManager?.requestLocationUpdates(
                                    LocationManager.NETWORK_PROVIDER,
                                    2000L,
                                    1f,
                                    locationListener
                                )
                            }
                            val lastGps = locationManager?.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                            val lastNet = locationManager?.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
                            val best = lastGps ?: lastNet
                            if (best != null) {
                                val data = mapOf(
                                    "latitude" to best.latitude,
                                    "longitude" to best.longitude,
                                    "accuracy" to best.accuracy.toDouble(),
                                    "speed" to best.speed.toDouble(),
                                    "altitude" to best.altitude,
                                    "timestamp" to best.time
                                )
                                result.success(data)
                            } else {
                                result.success(null)
                            }
                        } else {
                            result.error("PERMISSION_DENIED", "Permissions de localisation non accordées", null)
                        }
                    } catch (e: Exception) {
                        result.error("LOCATION_ERROR", e.message, null)
                    }
                }

                "stopLocationUpdates" -> {
                    try {
                        locationManager?.removeUpdates(locationListener)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCATION_ERROR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun applyVolumeCeiling(audioManager: AudioManager, ceiling: Double) {
        try {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            val clampedCeiling = ceiling.coerceIn(0.1, 1.0)
            currentVolumeCeiling = clampedCeiling

            val streams = intArrayOf(AudioManager.STREAM_VOICE_CALL, AudioManager.STREAM_MUSIC, AudioManager.STREAM_ALARM)
            for (stream in streams) {
                val max = audioManager.getStreamMaxVolume(stream)
                val target = (max * clampedCeiling).toInt().coerceIn(1, max)
                audioManager.setStreamVolume(stream, target, 0)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onDestroy() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (t: Throwable) {
            t.printStackTrace()
        }
        try {
            if (alarmWakeLock?.isHeld == true) {
                alarmWakeLock?.release()
            }
        } catch (t: Throwable) {
            t.printStackTrace()
        }
        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        } catch (t: Throwable) {
            t.printStackTrace()
        }
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        } catch (t: Throwable) {
            t.printStackTrace()
        }
        try {
            sensorManager?.unregisterListener(stepListener)
            if (stepWakeLock?.isHeld == true) {
                stepWakeLock?.release()
            }
        } catch (t: Throwable) {
            t.printStackTrace()
        }
        try {
            locationManager?.removeUpdates(locationListener)
        } catch (t: Throwable) {
            t.printStackTrace()
        }
        try {
            if (networkCallback != null) {
                connectivityManager?.unregisterNetworkCallback(networkCallback!!)
            }
        } catch (t: Throwable) {
            t.printStackTrace()
        }
        super.onDestroy()
    }
}
