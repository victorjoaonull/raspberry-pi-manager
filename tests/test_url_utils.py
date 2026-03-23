from lib.url_utils import format_url, is_valid_url_or_ip


def test_format_url_adds_http():
    assert format_url("example.com") == "http://example.com"
    assert format_url("http://a.b") == "http://a.b"


def test_is_valid_url_or_ip():
    assert is_valid_url_or_ip("http://x.com") is True
    assert is_valid_url_or_ip("https://x.com/path") is True
    assert is_valid_url_or_ip("192.168.1.1") is True
    assert is_valid_url_or_ip("192.168.1.1:8080") is True
    assert is_valid_url_or_ip("localhost") is True
    assert is_valid_url_or_ip("host:443") is True
    assert is_valid_url_or_ip("not a url !!!") is False
    assert is_valid_url_or_ip("") is True
