package com.romangarms.autoxlive

import com.romangarms.autoxlive.data.Driver
import com.romangarms.autoxlive.ui.matchesSearch
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveSearchTest {
    private val driver = Driver(
        position = 3,
        name = "Tom Smith",
        startNumber = "12",
        carClass = "SS",
        positionInClass = 1,
        runs = emptyList(),
        officialRunNumber = null,
        bestTimeString = null,
        vehicle = "2019 Mazda Miata",
    )

    private fun matches(query: String, nickname: String? = null) = matchesSearch(driver, nickname, query)

    @Test
    fun carNumbersMatchFromTheStart() {
        assertTrue(matches("1"))
        assertTrue(matches("12"))
        assertTrue(matches("#12"))
        assertFalse(matches("#2"))
        assertFalse(matches("#123"))
    }

    @Test
    fun textMatchesAnywhereIgnoringCase() {
        assertTrue(matches("smith"))
        assertTrue(matches("miata"))
        assertTrue(matches("ss"))
        assertTrue(matches("speedy", nickname = "Speedy T"))
        assertFalse(matches("civic"))
    }

    @Test
    fun everyWordMustMatch() {
        assertTrue(matches("mazda 12"))
        assertTrue(matches("  tom   miata "))
        assertFalse(matches("tom civic"))
    }
}
