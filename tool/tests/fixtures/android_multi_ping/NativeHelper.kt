package com.keqdroid.keqdroid

import java.io.File

// The JNI process boundary only. All batch/port/HTTP/cleanup code is production.
object NativeHelper {
    var starts = 0
    var pid = 1_999_999_999
    var failure: Exception? = null
    fun startCore(binary: String, config: String, assets: String, tun: String, core: String): Int {
        starts++
        check(File(binary).isFile)
        check(File(config).readText() == "{\"fixture\":true}")
        failure?.let { throw it }
        return pid
    }
}
