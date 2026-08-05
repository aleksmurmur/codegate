func TestErrorf(t *testing.T) {
	got := Compute(1)
	if got != 42 {
		t.Errorf("got %d, want 42", got)
	}
}

func TestNothing(t *testing.T) {
	Compute(1)
}
