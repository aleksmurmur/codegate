class FooTest {
    @Test
    fun `no throw only`() {
        assertDoesNotThrow { service.doThing(1) }
    }

    @Test
    fun `real assertion`() {
        assertEquals(42, service.doThing(1))
    }

    @Test
    fun `existence only`() {
        assertNotNull(service.doThing(1))
    }

    @Test
    fun `asserts nothing`() {
        service.doThing(1)
    }

    @Test
    fun `braces in strings and comments do not break the body`() {
        val s = "} not a closing brace {"
        // } neither is this {
        assertEquals("} not a closing brace {", s)
    }

    @Test
    fun `generic assertThrows is a real assertion`() {
        assertThrows<IllegalStateException> { service.doThing(-1) }
    }

    @Test
    fun `mockmvc andExpect is a real assertion`() {
        putWindow(RESOURCE, 0).andExpect { status { isBadRequest() } }
    }

    @Test
    fun `unbalanced closing brace in a multi-line comment`() {
        /*
         * Historically this ended with a stray }
         * and the assertion below is the real check.
         */
        assertEquals(1, service.doThing(1))
    }

    @Test
    fun `unbalanced opening brace in a multi-line comment`() {
        /*
         * The payload looks like {
         */
        assertEquals(2, service.doThing(2))
    }

    @Test
    fun `raw string spanning lines with a stray brace`() {
        val body = """
            {"a": 1}
            this line has a stray } inside the raw string
        """
        assertEquals(1, service.parse(body))
    }

    @Test
    fun `nested block comment does not overrun the body`() {
        /* outer /* inner } */ still commented { */
        assertEquals(3, service.doThing(3))
    }

    @Test
    @Disabled("intentionally empty stub")
    fun `empty disabled stub is not a finding`() {
    }

    @Test
    fun `assertion delegated to a same-file helper`() {
        payExpectingStatus(1, badRequest = true)
    }

    private fun payExpectingStatus(id: Int, badRequest: Boolean) {
        pay(id).andExpect { status { if (badRequest) isBadRequest() else isOk() } }
    }

    @Test
    fun `expression body whose only assertion is no-throw`() = assertDoesNotThrow { service.doThing(9) }

    // A private fixture builder — asserts nothing by design, and must not be
    // reported. Test classes are full of these.
    private fun makeThing(id: Int): Thing = repository.save(Thing(id = id))
}
