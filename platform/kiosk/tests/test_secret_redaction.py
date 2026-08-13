"""Promise: secrets in a user's code never reach the LLM.

Everything handed to the model is redacted first. A miss could ship a real
credential in a prompt, so these pin that the common secret shapes are masked.

NOTE: the sample tokens below are assembled from fragments (`"gh" "p_" ...`) on
purpose — they must match the vendor shapes our redactor targets, which also
means GitHub push-protection would flag them if written as one literal. Keeping
them split means no full token appears verbatim in the repo. Don't "tidy" them
back into single strings.
"""
import pytest

from app.redact import redact

REDACTED = "«REDACTED»"

# Each entry is joined at runtime; no complete token is a literal in this file.
SECRET_FRAGMENTS = [
    ("AKIA", "IOSFODNN7EXAMPLE"),                              # AWS access key id
    ("gh", "p_", "0123456789abcdefghij", "ABCDEFGHIJ012345"),  # GitHub token
    ("xox", "b-", "1234567890-abcdefghijklmnop"),              # Slack token
    ("sk-", "abcdefghijklmnop0123456789"),                     # OpenAI/LiteLLM style
    ("sk-", "ant-", "abcdefghijklmnop0123456789"),             # Anthropic
    ("AIza", "SyA1234567890abcdefghijklmnopqrstuvw"),          # Google API key
    ("eyJ", "hbGciOiJIUzI1NiJ9", ".", "eyJzdWIiOiIxMjM0NTY3", ".", "SflKxwRJSMeKKF2QT4fw"),  # JWT
    ("postgres://admin:", "s3cr3t", "@db.internal:5432/prod"), # conn string w/ creds
]


@pytest.mark.parametrize("fragments", SECRET_FRAGMENTS)
def test_known_secret_shapes_are_masked(fragments):
    secret = "".join(fragments)
    out = redact(f"config value is {secret} keep going")
    assert secret not in out
    assert REDACTED in out


def test_env_style_assignments_are_masked():
    text = "API_KEY=" + "supersecret123\nDB_PASSWORD: hunter2\nCLIENT_SECRET = abcdef"
    out = redact(text)
    for leaked in ("supersecret123", "hunter2", "abcdef"):
        assert leaked not in out


def test_indented_assignments_are_masked():
    # Nested YAML / assignments inside code are indented — these must still be
    # redacted (the anchor used to require column 0, leaking indented secrets).
    text = (
        "database:\n"
        "    db_password: SuperSecret123\n"
        "def connect():\n"
        "    API_TOKEN = 'tok_indented_value'\n"
    )
    out = redact(text)
    for leaked in ("SuperSecret123", "tok_indented_value"):
        assert leaked not in out
    assert REDACTED in out


def test_pem_private_key_block_is_masked():
    body = "MIIEabcdef1234567890"
    pem = f"-----BEGIN RSA PRIVATE KEY-----\n{body}\nzzzz\n-----END RSA PRIVATE KEY-----"
    out = redact(f"here is the key:\n{pem}\nthanks")
    assert body not in out


def test_ordinary_code_is_left_intact():
    text = "def add(a, b):\n    return a + b  # sums two numbers\n"
    assert redact(text) == text
