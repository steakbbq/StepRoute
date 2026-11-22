"""Tests for tools/release.py: toc, changelog, zip, and the CurseForge calls against a fake local server.

    python -I -m unittest discover -s tests -p test_release.py -v
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent / "tools"
sys.path.insert(0, str(TOOLS))
import release  # noqa: E402

TOKEN = "tok-SECRET-1234567890"
LUA = b"-- fake addon\nprint('hi')\n"
CHANGELOG = """# Changelog

## 0.1.2 [release]
- Route name is the last step text plus #N.
- STEP log has text= and src=.

## 0.1.1 [beta]
- Shown guide name.

## 0.1.0 [alpha]
- First build.
"""


def make_repo(tmp, version="0.1.2", interface="16001", changelog=CHANGELOG, stage=True, lua=LUA):
    root = Path(tmp)
    (root / "src").mkdir(parents=True, exist_ok=True)
    (root / "stage").mkdir(parents=True, exist_ok=True)
    toc = "## Interface: %s\n## Title: StepRoute\n## Version: %s\n\nStepRoute.lua\n" % (interface, version)
    (root / "src" / "StepRoute.toc").write_bytes(toc.encode())
    (root / "src" / "StepRoute.lua").write_bytes(lua)
    if changelog is not None:
        (root / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
    if stage:
        lines = ["%s *StepRoute/%s" % (hashlib.md5((root / "src" / n).read_bytes()).hexdigest(), n)
                 for n in sorted(os.listdir(root / "src"))]
        (root / "stage" / "StepRoute.md5").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return root


class Fake(ThreadingHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.token = TOKEN
        self.requests = []
        self.reset()

    def reset(self):
        self.versions = [
            {"id": 111, "gameVersionTypeID": 517, "name": "1.60.1"},          # retail type, same name: must NOT be used
            {"id": 777, "gameVersionTypeID": release.FOREVER_TYPE_ID, "name": "1.60.1"},
            {"id": 778, "gameVersionTypeID": release.FOREVER_TYPE_ID, "name": "1.60.2"},
        ]
        self.upload_status = 200
        self.upload_body = {"id": 4242}
        self.requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _record(self, body=b""):
        self.server.requests.append({"method": self.command, "path": self.path, "headers": dict(self.headers), "body": body})

    def do_GET(self):
        self._record()
        if self.headers.get("X-Api-Token") != self.server.token:
            return self._send(401, {"errorCode": 401, "errorMessage": "You must provide an API token"})
        if self.path == "/api/game/wow/versions":
            return self._send(200, self.server.versions)
        self._send(404, {"errorCode": 404, "errorMessage": "nope"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        self._record(body)
        if self.headers.get("X-Api-Token") != self.server.token:
            return self._send(401, {"errorCode": 401, "errorMessage": "bad token"})
        if not re.fullmatch(r"/api/projects/\d+/upload-file", self.path):
            return self._send(404, {"errorCode": 404})
        if self.server.upload_status != 200:
            # a hostile or careless server that echoes the token back
            return self._send(self.server.upload_status, {"errorMessage": "failed for token " + TOKEN})
        self._send(200, self.server.upload_body)


def run_cli(root, args, token=TOKEN, extra_env=None):
    env = dict(os.environ)
    env.pop("CF_API_KEY", None)
    env.pop("CF_PROJECT_ID", None)
    if token is not None:
        env["CF_API_KEY"] = token
    env.update(extra_env or {})
    p = subprocess.run([sys.executable, "-I", str(TOOLS / "release.py"), "--root", str(root)] + args,
                       capture_output=True, text=True, env=env, timeout=60)
    return p.returncode, p.stdout, p.stderr


class Pure(unittest.TestCase):
    def test_interface_to_version(self):
        self.assertEqual(release.interface_to_version(16001), "1.60.1")
        self.assertEqual(release.interface_to_version(11509), "1.15.9")
        self.assertEqual(release.interface_to_version(120105), "12.1.5")

    def test_toc(self):
        with tempfile.TemporaryDirectory() as t:
            root = make_repo(t, interface="16001, 16002")
            self.assertEqual(release.toc_version(root), "0.1.2")
            self.assertEqual(release.wanted_game_versions(root), ["1.60.1", "1.60.2"])
            root = make_repo(t, version="1.2")
            with self.assertRaises(release.ReleaseError):
                release.toc_version(root)

    def test_changelog_sections(self):
        with tempfile.TemporaryDirectory() as t:
            root = make_repo(t)
            kind, body = release.changelog_section(root, "0.1.2")
            self.assertEqual(kind, "release")
            self.assertIn("last step text", body)
            self.assertNotIn("Shown guide name", body)          # stops at the next section
            self.assertEqual(release.changelog_section(root, "0.1.1")[0], "beta")
            self.assertEqual(release.changelog_section(root, "0.1.0")[0], "alpha")

    def test_changelog_header_forms(self):
        with tempfile.TemporaryDirectory() as t:
            root = make_repo(t, changelog="## v0.1.2 [Beta]\n- x\n")
            self.assertEqual(release.changelog_section(root, "0.1.2"), ("beta", "- x"))

    def test_changelog_errors(self):
        with tempfile.TemporaryDirectory() as t:
            for text, why in [
                ("## 0.1.1 [release]\n- x\n", "no section for the version"),
                ("## 0.1.2\n- x\n", "no release type"),
                ("## 0.1.2 [stable]\n- x\n", "unknown release type"),
                ("## 0.1.2 [release]\n\n## 0.1.1 [release]\n- x\n", "empty section"),
            ]:
                root = make_repo(t, changelog=text)
                with self.assertRaises(release.ReleaseError, msg=why):
                    release.changelog_section(root, "0.1.2")
            root = make_repo(t, changelog=None)
            (Path(t) / "CHANGELOG.md").unlink(missing_ok=True)
            with self.assertRaises(release.ReleaseError):
                release.changelog_section(root, "0.1.2")

    def test_check_tag(self):
        with tempfile.TemporaryDirectory() as t:
            root = make_repo(t)
            self.assertEqual(release.check(root, "v0.1.2")["type"], "release")
            self.assertEqual(release.check(root)["version"], "0.1.2")
            with self.assertRaises(release.ReleaseError):
                release.check(root, "v0.1.3")
            with self.assertRaises(release.ReleaseError):
                release.check(root, "0.1.2")

    def test_match_versions_uses_the_forever_type_only(self):
        vs = [{"id": 1, "gameVersionTypeID": 517, "name": "1.60.1"},
              {"id": 2, "gameVersionTypeID": release.FOREVER_TYPE_ID, "name": "1.60.2"}]
        ids, missing, elsewhere = release.match_versions(vs, ["1.60.1", "1.60.2"])
        self.assertEqual(ids, [2])
        self.assertEqual(missing, ["1.60.1"])
        self.assertEqual([v["id"] for v in elsewhere], [1])

    def test_scrub(self):
        self.assertEqual(release.scrub("a %s b" % TOKEN, TOKEN), "a *** b")
        self.assertEqual(release.scrub("a b", ""), "a b")


class Build(unittest.TestCase):
    def test_zip_layout_and_bytes(self):
        with tempfile.TemporaryDirectory() as t:
            root = make_repo(t)
            zip_path, contents = release.build(root, Path(t) / "dist", check_stage=True)
            self.assertEqual(zip_path.name, "StepRoute-0.1.2.zip")
            with zipfile.ZipFile(zip_path) as z:
                self.assertEqual(sorted(z.namelist()), ["StepRoute/StepRoute.lua", "StepRoute/StepRoute.toc"])
                self.assertEqual(z.read("StepRoute/StepRoute.lua"), LUA)
                self.assertEqual(z.read("StepRoute/StepRoute.toc"), (root / "src" / "StepRoute.toc").read_bytes())
                self.assertIsNone(z.testzip())
            self.assertEqual(contents["StepRoute/StepRoute.lua"], hashlib.md5(LUA).hexdigest())

    def test_zip_is_the_same_every_time(self):
        with tempfile.TemporaryDirectory() as t:
            root = make_repo(t)
            a, _ = release.build(root, Path(t) / "d1")
            b, _ = release.build(root, Path(t) / "d2")
            self.assertEqual(a.read_bytes(), b.read_bytes())

    def test_stage_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as t:
            root = make_repo(t)
            (root / "src" / "StepRoute.lua").write_bytes(LUA + b"-- changed after stage\n")
            with self.assertRaises(release.ReleaseError) as cm:
                release.build(root, Path(t) / "dist", check_stage=True)
            self.assertIn("StepRoute/StepRoute.lua", str(cm.exception))
            release.build(root, Path(t) / "dist")               # without the check it builds

    def test_missing_stage_fails_only_with_check(self):
        with tempfile.TemporaryDirectory() as t:
            root = make_repo(t, stage=False)
            release.build(root, Path(t) / "dist")
            with self.assertRaises(release.ReleaseError):
                release.build(root, Path(t) / "dist", check_stage=True)

    def test_cli_build(self):
        with tempfile.TemporaryDirectory() as t:
            root = make_repo(t)
            code, out, err = run_cli(root, ["build", "--out", str(Path(t) / "dist"), "--check-stage"], token=None)
            self.assertEqual(code, 0, err)
            self.assertIn("built", out)
            self.assertIn("same files as stage", out)


class CurseForge(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = Fake()
        cls.site = "http://127.0.0.1:%d" % cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        self.srv.reset()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = make_repo(self.tmp.name)
        self.zip, _ = release.build(self.root, Path(self.tmp.name) / "dist", check_stage=True)

    def tearDown(self):
        self.tmp.cleanup()

    def assert_no_token(self, *texts):
        for t in texts:
            self.assertNotIn(TOKEN, t)

    def test_versions_match(self):
        code, out, err = run_cli(self.root, ["versions", "--site", self.site])
        self.assertEqual(code, 0, err)
        self.assertIn("match 1.60.1 -> id 777", out)
        self.assertNotIn("id 111", out)
        self.assert_no_token(out, err)
        self.assertEqual(self.srv.requests[0]["headers"].get("X-Api-Token"), TOKEN)

    def test_versions_no_exact_match_fails_and_guesses_nothing(self):
        self.srv.versions = [{"id": 111, "gameVersionTypeID": 517, "name": "1.60.1"},
                             {"id": 900, "gameVersionTypeID": release.FOREVER_TYPE_ID, "name": "1.59.9"}]
        code, out, err = run_cli(self.root, ["versions", "--site", self.site])
        self.assertEqual(code, 1)
        self.assertIn("Nothing is guessed", err)
        self.assertIn("1.59.9=900", out)                         # lists what exists
        self.assertIn("other type (NOT used)", out)
        self.assert_no_token(out, err)

    def test_versions_without_token(self):
        code, out, err = run_cli(self.root, ["versions", "--site", self.site], token=None)
        self.assertEqual(code, 1)
        self.assertIn("CF_API_KEY is not set", err)
        code, out, err = run_cli(self.root, ["versions", "--site", self.site, "--skip-if-no-token"], token=None)
        self.assertEqual(code, 0)
        self.assertIn("skipped", out)
        self.assertEqual(self.srv.requests, [])

    def test_wrong_token(self):
        code, out, err = run_cli(self.root, ["versions", "--site", self.site], token="other-token")
        self.assertEqual(code, 1)
        self.assertIn("HTTP 401", err)

    def test_upload_dry_run_sends_nothing(self):
        code, out, err = run_cli(self.root, ["upload", "--dry-run", "--zip", str(self.zip), "--project-id", "123",
                                             "--tag", "v0.1.2", "--site", self.site], token=None)
        self.assertEqual(code, 0, err)
        self.assertIn("dry run", out)
        self.assertIn('"releaseType": "release"', out)
        self.assertIn("last step text", out)
        self.assertEqual(self.srv.requests, [])

    def test_upload_dry_run_with_token_reads_only(self):
        code, out, err = run_cli(self.root, ["upload", "--dry-run", "--zip", str(self.zip), "--project-id", "123",
                                             "--site", self.site])
        self.assertEqual(code, 0, err)
        self.assertIn("777", out)
        self.assertEqual([r["method"] for r in self.srv.requests], ["GET"])
        self.assert_no_token(out, err)

    def test_upload(self):
        code, out, err = run_cli(self.root, ["upload", "--zip", str(self.zip), "--project-id", "123",
                                             "--tag", "v0.1.2", "--site", self.site])
        self.assertEqual(code, 0, err)
        self.assertIn("CurseForge file id 4242", out)
        self.assert_no_token(out, err)
        posts = [r for r in self.srv.requests if r["method"] == "POST"]
        self.assertEqual(len(posts), 1)
        post = posts[0]
        self.assertEqual(post["path"], "/api/projects/123/upload-file")
        self.assertEqual(post["headers"].get("X-Api-Token"), TOKEN)
        self.assertTrue(post["headers"]["Content-Type"].startswith("multipart/form-data; boundary="))
        body = post["body"]
        m = re.search(rb'name="metadata"\r\n\r\n(\{.*?\})\r\n--', body, re.S)
        self.assertIsNotNone(m)
        meta = json.loads(m.group(1))
        self.assertEqual(meta["gameVersions"], [777])
        self.assertEqual(meta["releaseType"], "release")
        self.assertEqual(meta["changelogType"], "markdown")
        self.assertEqual(meta["displayName"], "StepRoute 0.1.2")
        self.assertIn("last step text", meta["changelog"])
        self.assertNotIn("Shown guide name", meta["changelog"])
        self.assertIn(b'name="file"; filename="StepRoute-0.1.2.zip"', body)
        self.assertIn(self.zip.read_bytes(), body)
        self.assertNotIn(TOKEN.encode(), body)                   # the token is only in the header

    def test_upload_error_body_is_scrubbed(self):
        self.srv.upload_status = 500
        code, out, err = run_cli(self.root, ["upload", "--zip", str(self.zip), "--project-id", "123", "--site", self.site])
        self.assertEqual(code, 1)
        self.assertIn("HTTP 500", err)
        self.assertIn("***", err)
        self.assert_no_token(out, err)

    def test_upload_no_game_version_sends_nothing(self):
        self.srv.versions = [{"id": 111, "gameVersionTypeID": 517, "name": "1.60.1"}]
        code, out, err = run_cli(self.root, ["upload", "--zip", str(self.zip), "--project-id", "123", "--site", self.site])
        self.assertEqual(code, 1)
        self.assertEqual([r["method"] for r in self.srv.requests], ["GET"])

    def test_upload_refuses_bad_input(self):
        base = ["upload", "--zip", str(self.zip), "--site", self.site]
        code, out, err = run_cli(self.root, base + ["--project-id", ""])
        self.assertEqual(code, 1)
        self.assertIn("CF_PROJECT_ID", err)
        code, out, err = run_cli(self.root, base + ["--project-id", "abc"])
        self.assertEqual(code, 1)
        code, out, err = run_cli(self.root, base + ["--project-id", "123", "--tag", "v9.9.9"])
        self.assertEqual(code, 1)
        self.assertIn("does not match", err)
        code, out, err = run_cli(self.root, ["upload", "--zip", str(Path(self.tmp.name) / "StepRoute-9.9.9.zip"),
                                             "--project-id", "123", "--site", self.site])
        self.assertEqual(code, 1)
        code, out, err = run_cli(self.root, ["upload", "--zip", str(self.zip), "--project-id", "123"], token=None)
        self.assertEqual(code, 1)
        self.assertIn("CF_API_KEY is not set", err)
        self.assertEqual(self.srv.requests, [])

    def test_token_goes_only_to_curseforge(self):
        code, out, err = run_cli(self.root, ["versions", "--site", "https://example.com"])
        self.assertEqual(code, 1)
        self.assertIn("refusing to send the token", err)
        self.assert_no_token(out, err)


if __name__ == "__main__":
    unittest.main()
