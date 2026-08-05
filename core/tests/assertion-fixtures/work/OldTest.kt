class OldTest {
    @Test
    fun `pre-existing weak test, untouched by the diff`() {
        assertDoesNotThrow { legacy.run() }
    }

    @Test
    fun `touched by the diff`() {
        legacy.run()
        legacy.runAgain()
    }
}
