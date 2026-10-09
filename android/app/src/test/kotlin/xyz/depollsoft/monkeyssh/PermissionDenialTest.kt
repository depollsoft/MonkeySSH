package xyz.depollsoft.monkeyssh

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The denial scenarios permission_handler_android documents for
 * `shouldShowRequestPermissionRationale`, read through [resolveDenial].
 */
class PermissionDenialTest {
    private fun outcome(
        rationaleBefore: Boolean,
        rationaleAfter: Boolean,
        deniedBefore: Boolean,
    ) = resolveDenial(rationaleBefore, rationaleAfter, deniedBefore)

    @Test
    fun firstDialogDismissedStaysDenied() {
        assertEquals(
            DenialOutcome(permanentlyDenied = false, recordDenial = false),
            outcome(rationaleBefore = false, rationaleAfter = false, deniedBefore = false),
        )
    }

    @Test
    fun firstDenialCanAskAgainAndIsRecorded() {
        assertEquals(
            DenialOutcome(permanentlyDenied = false, recordDenial = true),
            outcome(rationaleBefore = false, rationaleAfter = true, deniedBefore = false),
        )
    }

    @Test
    fun dismissAfterOneDenialCanAskAgain() {
        assertEquals(
            DenialOutcome(permanentlyDenied = false, recordDenial = true),
            outcome(rationaleBefore = true, rationaleAfter = true, deniedBefore = true),
        )
    }

    @Test
    fun secondDenialIsPermanent() {
        assertEquals(
            DenialOutcome(permanentlyDenied = true, recordDenial = true),
            outcome(rationaleBefore = true, rationaleAfter = false, deniedBefore = true),
        )
    }

    @Test
    fun secondDenialIsPermanentEvenWithoutAStoredFlag() {
        // A denial made before the flag existed (or after app data was cleared).
        assertEquals(
            DenialOutcome(permanentlyDenied = true, recordDenial = true),
            outcome(rationaleBefore = true, rationaleAfter = false, deniedBefore = false),
        )
    }

    @Test
    fun requestAnsweredWithoutADialogAfterADenialIsPermanent() {
        assertEquals(
            DenialOutcome(permanentlyDenied = true, recordDenial = false),
            outcome(rationaleBefore = false, rationaleAfter = false, deniedBefore = true),
        )
    }

    @Test
    fun denialAfterAskEveryTimeCanAskAgain() {
        // "Ask every time" clears the rationale flag; a denial then sets it again.
        assertEquals(
            DenialOutcome(permanentlyDenied = false, recordDenial = true),
            outcome(rationaleBefore = false, rationaleAfter = true, deniedBefore = true),
        )
    }
}
