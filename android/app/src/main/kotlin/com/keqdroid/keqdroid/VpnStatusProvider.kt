package com.keqdroid.keqdroid

import android.content.Context
import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri

/**
 * ContentProvider для синхронизации статуса VPN между KeqdisVpnService и VpnQuickTileService.
 * 
 * Использование:
 *   1. VPN сервис вызывает: getContentResolver().notifyChange(VpnStatusProvider.statusUri(this), null)
 *   2. TileService наблюдает за тем же URI через ContentObserver
 *   3. При каждом изменении статус читается из SharedPreferences и тайл обновляется
 */
class VpnStatusProvider : ContentProvider() {

    companion object {
        fun statusUri(context: Context): Uri =
            Uri.parse("content://${context.packageName}.vpnstatus/status")
    }

    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0
}
