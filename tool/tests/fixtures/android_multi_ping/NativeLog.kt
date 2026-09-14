package com.keqdroid.keqdroid

import android.util.Log

object NativeLog {
    val warnings = mutableListOf<String>()
    fun e(tag: String, message: String) { Log.e(tag, message) }
    fun w(tag: String, message: String) { warnings.add("$tag: $message") }
}
