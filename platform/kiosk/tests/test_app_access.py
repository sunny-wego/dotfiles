"""Promise: only the right people can open your app.

The allow-list decision (enforced at the proxy before a request reaches the
container) is the platform's core access guarantee. These drive that decision
through its public entry point with a fake data store — no Postgres — so we test
the *behaviour a user experiences*, not how it's stored or cached.
"""
import pytest

from app import access

OWNER = "owner@wego.com"


@pytest.fixture
def store(monkeypatch):
    """A tenant app + its allow-list, swapped in for the metadata DB."""
    state = {"app": {"owner": OWNER, "visibility": "invite-only"}, "acl": []}
    monkeypatch.setattr(access.db, "get_app", lambda slug: state["app"])
    monkeypatch.setattr(access.db, "list_access", lambda slug: list(state["acl"]))
    monkeypatch.setattr(access.db, "add_access",
                        lambda slug, email: state["acl"].append(email.lower()))
    monkeypatch.setattr(access.db, "set_visibility",
                        lambda slug, v: state["app"].__setitem__("visibility", v))
    access.invalidate()  # start each test with a clean decision cache
    return state


def test_a_non_company_account_is_always_denied(store):
    assert access.can_open("board", "intruder@gmail.com") is False


def test_the_owner_can_always_open_their_app(store):
    assert access.can_open("board", OWNER) is True


def test_invite_only_denies_a_company_user_not_on_the_list(store):
    assert access.can_open("board", "someone@wego.com") is False


def test_all_staff_lets_any_company_user_in(store):
    access.set_visibility("board", "all-staff")
    access.invalidate("board")
    assert access.can_open("board", "someone@wego.com") is True


def test_granting_access_takes_effect_immediately(store):
    user = "newhire@wego.com"
    assert access.can_open("board", user) is False   # not yet invited
    access.add_access("board", user)                 # owner grants access
    assert access.can_open("board", user) is True    # no stale "denied" lingers


def test_opening_an_unknown_app_is_denied(store, monkeypatch):
    monkeypatch.setattr(access.db, "get_app", lambda slug: None)
    access.invalidate()
    assert access.can_open("ghost", OWNER) is False
