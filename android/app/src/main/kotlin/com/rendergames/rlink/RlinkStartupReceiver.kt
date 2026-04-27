package com.rendergames.rlink

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Restores background runtime after reboot/app-update.
 * Server remains unchanged: we only keep local transport stack alive.
 */
class RlinkStartupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }
        try {
            val serviceIntent = Intent(context, RlinkForegroundService::class.java)
                .setAction(RlinkForegroundService.ACTION_START)
            ContextCompat.startForegroundService(context, serviceIntent)
        } catch (e: Exception) {
            Log.w("Rlink", "startup receiver failed: ${e.message}")
        }
    }
}
