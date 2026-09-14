package android.util

object Log {
    val errors = mutableListOf<String>()
    fun e(tag: String, message: String): Int { errors.add("$tag: $message"); return 0 }
    fun w(tag: String, message: String): Int = 0
}
