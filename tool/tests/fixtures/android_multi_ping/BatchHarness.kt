package com.keqdroid.keqdroid

import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

// A listening SOCKS endpoint whose target connection is refused. Readiness
// succeeds, but each real HTTP probe fails: this must NOT request batch splitting.
private class RefusingSocks : AutoCloseable {
    private val listener = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    val port: Int get() = listener.localPort
    val requests = AtomicInteger()
    private val worker = thread(isDaemon = true) {
        try {
            while (!listener.isClosed) {
                listener.accept().use { socket ->
                    socket.soTimeout = 1000
                    val input = socket.getInputStream()
                    val output = socket.getOutputStream()
                    val version = input.read()
                    if (version == -1) return@use // production readiness probe
                    check(version == 5)
                    val methods = input.read()
                    check(methods > 0)
                    repeat(methods) { check(input.read() >= 0) }
                    output.write(byteArrayOf(5, 0))
                    output.flush()
                    check(input.read() == 5)
                    check(input.read() == 1)
                    check(input.read() == 0)
                    val addressSize = when (input.read()) {
                        1 -> 4
                        3 -> input.read()
                        4 -> 16
                        else -> error("unexpected SOCKS address")
                    }
                    repeat(addressSize + 2) { check(input.read() >= 0) }
                    requests.incrementAndGet()
                    output.write(byteArrayOf(5, 5, 0, 1, 0, 0, 0, 0, 0, 0))
                    output.flush()
                }
            }
        } catch (e: SocketException) {
            if (!listener.isClosed) throw e
        }
    }
    override fun close() {
        listener.close()
        worker.join(2000)
        check(!worker.isAlive)
    }
}

fun main(args: Array<String>) {
    val scenario = args[0]
    val root = File(args[1])
    val libs = File(root, "libs").apply { mkdirs() }
    val configs = File(root, "configs").apply { mkdirs() }
    val binary = File(libs, "libxray.so").apply { writeText("not executed") }
    val unusedPort = ServerSocket(0).use { it.localPort }
    val probes = listOf(
        EphemeralXrayPing.MultiProbe("one", unusedPort),
        EphemeralXrayPing.MultiProbe("two", unusedPort),
    )
    fun run(
        items: List<EphemeralXrayPing.MultiProbe> = probes,
        configDir: File = configs,
        timeout: Int = 40,
    ) = EphemeralXrayPing.urlTestMulti(
        libs.absolutePath, configDir, root.absolutePath, "{\"fixture\":true}",
        items, "https://127.0.0.1:443/unused", timeout, keepAlive = false,
    )
    when (scenario) {
        "empty" -> {
            check(run(emptyList()).isEmpty())
            check(NativeHelper.starts == 0)
        }
        "missing-binary" -> {
            binary.delete()
            check(run().isEmpty())
            check(NativeHelper.starts == 0)
            check(android.util.Log.errors.single().contains("not found"))
        }
        "negative-pid", "zero-pid" -> {
            NativeHelper.pid = if (scenario == "zero-pid") 0 else -1
            check(run().isEmpty())
            check(NativeHelper.starts == 1)
            check(android.os.Process.killed.isEmpty())
            check(android.util.Log.errors.single().contains("failed to start"))
        }
        "start-exception" -> {
            NativeHelper.failure = IllegalStateException("native fixture failure")
            check(run().isEmpty())
            check(NativeHelper.starts == 1)
            check(android.os.Process.killed.isEmpty())
            check(android.util.Log.errors.single().contains("native fixture failure"))
        }
        "config-exception" -> {
            check(run(configDir = File(configs, "missing/parent")).isEmpty())
            check(NativeHelper.starts == 0)
            check(android.os.Process.killed.isEmpty())
            check(android.util.Log.errors.single().contains("urlTestMulti failed"))
        }
        "port-not-ready" -> {
            check(run().isEmpty())
            check(android.os.Process.killed == listOf(NativeHelper.pid))
            check(android.util.Log.errors.single().contains("not ready"))
        }
        "per-probe-failures" -> {
            RefusingSocks().use { one ->
                RefusingSocks().use { two ->
                    val results = run(listOf(
                        EphemeralXrayPing.MultiProbe("one", one.port),
                        EphemeralXrayPing.MultiProbe("two", two.port),
                    ), timeout = 1500)
                    check(results.map { it.id } == listOf("one", "two"))
                    check(results.all { !it.result.success && !it.result.error.isNullOrEmpty() })
                    check(one.requests.get() >= 1 && two.requests.get() >= 1)
                    check(android.util.Log.errors.isEmpty())
                    check(android.os.Process.killed == listOf(NativeHelper.pid))
                }
            }
        }
        else -> error("unknown scenario: $scenario")
    }
    check(configs.walkTopDown().none { it.isFile }) { "session configuration leaked" }
    println("PASS $scenario")
}
