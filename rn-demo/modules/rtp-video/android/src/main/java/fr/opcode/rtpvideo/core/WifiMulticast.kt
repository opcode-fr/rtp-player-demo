package fr.opcode.rtpvideo.core

import android.content.Context
import android.net.wifi.WifiManager

/**
 * Sans ce verrou, le Wi-Fi d'Android filtre les paquets multicast pour économiser la batterie.
 * À garder pendant toute la lecture d'un flux multicast, puis release().
 * Permission requise : CHANGE_WIFI_MULTICAST_STATE.
 */
fun Context.acquireMulticastLock(): WifiManager.MulticastLock {
    val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    return wifi.createMulticastLock("rtp-video").apply {
        setReferenceCounted(false)
        acquire()
    }
}
