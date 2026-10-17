package xyz.depollsoft.monkeyssh

import org.junit.Assert.assertEquals
import org.junit.Test

/** Which queued requests share the answer from the dialog ahead of them. */
class PermissionQueueTest {
    private fun queue() = ArrayDeque(listOf("location#2", "camera#1", "location#3"))

    @Test
    fun answeredDialogSettlesQueuedRequestsForTheSamePermission() {
        // Without this, location#2 would show the dialog again right away, and a
        // second quick denial would become permanent.
        val queue = queue()

        val settled = takeSettledBy(queue, answered = true) { it.startsWith("location") }

        assertEquals(listOf("location#2", "location#3"), settled)
        assertEquals(listOf("camera#1"), queue.toList())
    }

    @Test
    fun interruptedDialogLeavesTheQueueToAskAgain() {
        val queue = queue()

        val settled = takeSettledBy(queue, answered = false) { it.startsWith("location") }

        assertEquals(emptyList<String>(), settled)
        assertEquals(listOf("location#2", "camera#1", "location#3"), queue.toList())
    }
}
