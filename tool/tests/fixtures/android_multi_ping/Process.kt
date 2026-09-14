package android.os

object Process {
    val killed = mutableListOf<Int>()
    fun killProcess(pid: Int) { killed.add(pid) }
}
