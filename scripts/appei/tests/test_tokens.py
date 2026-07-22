import pytest

from appei import tokens


@pytest.fixture(autouse=True)
def config_home(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    return tmp_path


class TestTokenCache:
    def test_round_trip(self):
        tokens.save_token("de.example.org", {"access_token": "abc"})
        assert tokens.load_token("de.example.org") == {"access_token": "abc"}

    def test_path_is_per_server(self, config_home):
        tokens.save_token("de.example.org", {"access_token": "abc"})
        expected = config_home / "cyverse" / "discoenv" / "appei" / "de.example.org"
        assert expected.is_file()

    def test_token_file_is_private(self, config_home):
        path = tokens.save_token("de.example.org", {"access_token": "abc"})
        assert path.stat().st_mode & 0o777 == 0o600

    def test_load_missing_raises_token_error(self):
        with pytest.raises(tokens.TokenError, match="appei login"):
            tokens.load_token("nowhere.example.org")

    def test_delete_token(self):
        tokens.save_token("de.example.org", {"access_token": "abc"})
        assert tokens.delete_token("de.example.org") is True
        assert tokens.delete_token("de.example.org") is False


class TestUsernameFromToken:
    def test_reads_preferred_username_from_jwt_payload(self, make_jwt):
        token = make_jwt({"preferred_username": "adminuser", "iss": "keycloak"})
        assert tokens.username_from_token(token) == "adminuser"

    def test_non_jwt_token_raises_token_error(self):
        with pytest.raises(tokens.TokenError, match="username"):
            tokens.username_from_token("not-a-jwt")

    def test_jwt_without_username_claim_raises_token_error(self, make_jwt):
        with pytest.raises(tokens.TokenError, match="username"):
            tokens.username_from_token(make_jwt({"iss": "keycloak"}))
