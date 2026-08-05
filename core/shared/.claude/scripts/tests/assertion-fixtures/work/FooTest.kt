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

    // A private fixture builder — asserts nothing by design, and must not be
    // reported. Test classes are full of these.
    private fun makeThing(id: Int): Thing = repository.save(Thing(id = id))
}
