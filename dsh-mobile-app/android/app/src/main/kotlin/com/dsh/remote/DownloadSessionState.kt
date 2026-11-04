package com.dsh.remote

/** 所有权在 Android 主线程；旧任务的迟到回调不能停止或覆盖新任务。 */
internal class DownloadSessionState {
    var id: String? = null
        private set
    var received: Long = 0
        private set
    var total: Long? = null
        private set

    fun begin(next: String): Boolean {
        if (next.isBlank() || (id != null && id != next)) return false
        if (id == next) return true
        id = next
        received = 0
        total = null
        return true
    }

    fun update(owner: String, bytes: Long, size: Long?): Boolean {
        if (id != owner || bytes < 0) return false
        received = bytes
        total = size?.takeIf { it > 0 && it >= bytes }
        return true
    }

    fun end(owner: String): Boolean {
        if (id != owner) return false
        id = null
        received = 0
        total = null
        return true
    }
}
