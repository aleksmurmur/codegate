def test_no_assert():
    compute(1)

def test_bare_assert():
    assert compute(1) == 42

def test_existence():
    assert compute(1) is not None
