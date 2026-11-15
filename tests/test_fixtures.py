from proto import fixtures


def test_swift_golden_fixture_up_to_date():
    """Sửa logic Python thì phải sinh lại dữ liệu mẫu cho test Swift: uv run python -m proto.fixtures"""
    assert fixtures.OUT.read_text(encoding="utf-8") == fixtures.dumps(fixtures.build())
