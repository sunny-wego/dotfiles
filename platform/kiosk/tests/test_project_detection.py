"""Promise: the platform understands what kind of app you uploaded.

Detection drives the generated Dockerfile and the port it exposes, so getting
the runtime/port right is what makes "upload and it just runs" work.
"""
from app.detect import detect


def _write(tmp_path, files):
    for name, body in files.items():
        p = tmp_path / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)
    return str(tmp_path)


def test_an_express_api_is_detected_as_node(tmp_path):
    root = _write(tmp_path, {"package.json": '{"dependencies":{"express":"^4"}}'})
    d = detect(root)
    assert d.runtime == "node"
    assert d.framework == "express"


def test_a_nextjs_app_is_detected_as_node_fullstack(tmp_path):
    root = _write(tmp_path, {"package.json": '{"dependencies":{"next":"14","react":"18"}}'})
    d = detect(root)
    assert d.runtime == "node"
    assert d.framework == "next"


def test_a_fastapi_service_is_detected_as_python_on_8000(tmp_path):
    root = _write(tmp_path, {"requirements.txt": "fastapi\nuvicorn\n"})
    d = detect(root)
    assert d.runtime == "python"
    assert d.framework == "fastapi"
    assert d.suggested_port == 8000


def test_a_streamlit_app_gets_its_own_port(tmp_path):
    root = _write(tmp_path, {"requirements.txt": "streamlit\n"})
    d = detect(root)
    assert d.runtime == "python"
    assert d.suggested_port == 8501


def test_an_unrecognisable_upload_is_reported_as_unknown(tmp_path):
    root = _write(tmp_path, {"README.md": "# just docs"})
    d = detect(root)
    assert d.runtime == "unknown"
