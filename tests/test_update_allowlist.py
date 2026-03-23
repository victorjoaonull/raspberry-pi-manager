from lib.update_allowlist import is_allowed_update_script


def test_rejects_wrong_basename(tmp_path):
    p = tmp_path / "evil.sh"
    p.write_text("#!/bin/bash\necho x\n")
    assert is_allowed_update_script(str(p), app_root_path="/tmp") is False


def test_accepts_under_app_root(tmp_path):
    root = tmp_path / "app"
    root.mkdir()
    script = root / "update_app.sh"
    script.write_text("#!/bin/bash\necho ok\n")
    assert is_allowed_update_script(str(script), app_root_path=str(root)) is True


def test_accepts_env_install_dir(tmp_path, monkeypatch):
    root = tmp_path / "custom"
    root.mkdir()
    script = root / "update_app.sh"
    script.write_text("#!/bin/bash\n")
    monkeypatch.setenv("APP_INSTALL_DIR", str(root))
    try:
        assert is_allowed_update_script(str(script), app_root_path="/nope") is True
    finally:
        monkeypatch.delenv("APP_INSTALL_DIR", raising=False)


def test_rejects_path_outside_roots(tmp_path, monkeypatch):
    monkeypatch.delenv("APP_INSTALL_DIR", raising=False)
    monkeypatch.delenv("PI_MANAGER_INSTALL_DIR", raising=False)
    bad = tmp_path / "update_app.sh"
    bad.write_text("#!/bin/bash\n")
    assert is_allowed_update_script(str(bad), app_root_path="/nonexistent-root-xyz") is False
