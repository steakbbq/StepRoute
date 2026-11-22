#!/usr/bin/env python3
"""StepRoute release helper. Python 3 standard library only.

    python tools/release.py check    [--tag vX.Y.Z]
    python tools/release.py build    [--out dist] [--check-stage]
    python tools/release.py versions [--skip-if-no-token] [--site URL]
    python tools/release.py upload   --zip FILE --project-id N [--tag vX.Y.Z] [--dry-run] [--site URL]

check     tag, `## Version:` in the toc and a CHANGELOG.md section must all agree.
build     dist/StepRoute-<version>.zip from src/ (top folder StepRoute/, fixed time stamps).
          --check-stage: the zip files must have the same md5 as stage/StepRoute.md5.
versions  list the CurseForge game versions for the toc `## Interface:` and exit 1 when one has no exact match.
upload    send the zip to CurseForge (game version ids found by name at run time, never guessed).

The API token is read only from the environment variable CF_API_KEY. It is never printed.
Any text from the server is scrubbed of the token before it is printed.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
import uuid
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON = "StepRoute"
SITE = "https://wow.curseforge.com"
# CurseForge gameVersionTypeID of the WoW Forever flavor (the id BigWigsMods/packager uses for "forever")
FOREVER_TYPE_ID = 88568
RELEASE_TYPES = ("release", "beta", "alpha")
TIMEOUT = 60


class ReleaseError(Exception):
    pass


# --------------------------------------------------------------------------- toc, changelog


def toc_fields(root):
    path = Path(root) / "src" / (ADDON + ".toc")
    if not path.is_file():
        raise ReleaseError("missing %s" % path)
    fields = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^##\s*([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*$", line)
        if m:
            fields[m.group(1)] = m.group(2)
    return fields


def toc_version(root):
    v = toc_fields(root).get("Version", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", v):
        raise ReleaseError("toc Version %r is not X.Y.Z" % v)
    return v


def interface_to_version(n):
    """16001 -> 1.60.1 (the CurseForge game version name)."""
    return "%d.%d.%d" % (n // 10000, n // 100 % 100, n % 100)


def wanted_game_versions(root):
    raw = toc_fields(root).get("Interface", "")
    nums = re.findall(r"\d+", raw)
    if not nums:
        raise ReleaseError("toc has no Interface")
    return [interface_to_version(int(n)) for n in nums]


def changelog_section(root, version):
    """(release type, markdown body) of the CHANGELOG.md section `## X.Y.Z [release|beta|alpha]`."""
    path = Path(root) / "CHANGELOG.md"
    if not path.is_file():
        raise ReleaseError("missing CHANGELOG.md")
    lines = path.read_text(encoding="utf-8").splitlines()
    start = None
    kind = None
    for i, line in enumerate(lines):
        m = re.match(r"^##\s+v?(\d+\.\d+\.\d+)\s*(?:\[\s*([A-Za-z]+)\s*\])?\s*$", line)
        if m and m.group(1) == version:
            start, kind = i, (m.group(2) or "").lower()
            break
    if start is None:
        raise ReleaseError("CHANGELOG.md has no section '## %s [release|beta|alpha]'" % version)
    if kind not in RELEASE_TYPES:
        raise ReleaseError("CHANGELOG.md section %s needs a release type: [release], [beta] or [alpha]" % version)
    body = []
    for line in lines[start + 1:]:
        if re.match(r"^##\s", line):
            break
        body.append(line)
    text = "\n".join(body).strip()
    if not text:
        raise ReleaseError("CHANGELOG.md section %s is empty" % version)
    return kind, text


def check(root, tag=None):
    version = toc_version(root)
    if tag is not None and tag != "v" + version:
        raise ReleaseError("tag %s does not match toc Version %s (expected v%s)" % (tag, version, version))
    kind, body = changelog_section(root, version)
    return {"version": version, "type": kind, "changelog": body, "game_versions": wanted_game_versions(root)}


# --------------------------------------------------------------------------- build


def md5_bytes(data):
    return hashlib.md5(data).hexdigest()


def stage_manifest(root):
    path = Path(root) / "stage" / (ADDON + ".md5")
    if not path.is_file():
        raise ReleaseError("missing stage/%s.md5" % ADDON)
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([0-9a-f]{32}) \*(.+)$", line.strip())
        if m:
            out[m.group(2)] = m.group(1)
    return out


def build(root, out_dir, check_stage=False):
    root = Path(root)
    version = toc_version(root)
    src = root / "src"
    names = sorted(p.name for p in src.iterdir() if p.is_file() and not p.name.startswith("."))
    if not names:
        raise ReleaseError("src/ has no files")
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    zip_path = out_dir / ("%s-%s.zip" % (ADDON, version))
    contents = {}
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for name in names:
            data = (src / name).read_bytes()
            info = zipfile.ZipInfo("%s/%s" % (ADDON, name), date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, data)
            contents["%s/%s" % (ADDON, name)] = md5_bytes(data)
    if check_stage:
        stage = stage_manifest(root)
        if stage != contents:
            lines = []
            for key in sorted(set(stage) | set(contents)):
                if stage.get(key) != contents.get(key):
                    lines.append("  %s: stage %s, src %s" % (key, stage.get(key), contents.get(key)))
            raise ReleaseError("stage/%s.md5 does not match src (run tools/stage.py):\n%s" % (ADDON, "\n".join(lines)))
    return zip_path, contents


# --------------------------------------------------------------------------- CurseForge


def scrub(text, token):
    text = str(text)
    if token:
        text = text.replace(token, "***")
    return text


def http(method, url, token, data=None, headers=None):
    # the token goes only to CurseForge (or a local test server), never to another host
    if not (url.startswith(SITE + "/") or url.startswith("http://127.0.0.1:") or url.startswith("http://localhost:")):
        raise ReleaseError("refusing to send the token to %s" % url.split("/api/")[0])
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-Api-Token", token)
    req.add_header("Accept", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        raise ReleaseError("HTTP %d from %s: %s" % (e.code, method + " " + scrub(url, token), scrub(body, token)[:400]))
    except urllib.error.URLError as e:
        raise ReleaseError("cannot reach %s: %s" % (scrub(url, token), scrub(e.reason, token)))


def fetch_versions(site, token):
    status, body = http("GET", site + "/api/game/wow/versions", token)
    try:
        data = json.loads(body)
    except ValueError:
        raise ReleaseError("game versions answer is not JSON")
    if not isinstance(data, list):
        raise ReleaseError("game versions answer is not a list")
    return data


def match_versions(all_versions, wanted, type_id=FOREVER_TYPE_ID):
    """(ids, missing, same_name_other_type): exact name inside the WoW Forever type only."""
    ids, missing, elsewhere = [], [], []
    for name in wanted:
        hit = [v for v in all_versions if v.get("gameVersionTypeID") == type_id and v.get("name") == name]
        if hit:
            ids.append(hit[0]["id"])
        else:
            missing.append(name)
            elsewhere += [v for v in all_versions if v.get("name") == name]
    return ids, missing, elsewhere


def need_token(skip_ok=False):
    token = os.environ.get("CF_API_KEY", "").strip()
    if not token and not skip_ok:
        raise ReleaseError("CF_API_KEY is not set")
    return token


def cmd_versions(args):
    root = Path(args.root)
    wanted = wanted_game_versions(root)
    token = need_token(skip_ok=args.skip_if_no_token)
    if not token:
        print("no CF_API_KEY: game version list skipped (wanted: %s, WoW Forever type %d)"
              % (", ".join(wanted), FOREVER_TYPE_ID))
        return 0
    versions = fetch_versions(args.site, token)
    forever = sorted((v for v in versions if v.get("gameVersionTypeID") == FOREVER_TYPE_ID), key=lambda v: v.get("id", 0))
    print("CurseForge WoW Forever game versions (type %d): %s"
          % (FOREVER_TYPE_ID, ", ".join("%s=%s" % (v.get("name"), v.get("id")) for v in forever) or "none"))
    ids, missing, elsewhere = match_versions(versions, wanted)
    for name, i in zip([w for w in wanted if w not in missing], ids):
        print("match %s -> id %s" % (name, i))
    if missing:
        for v in elsewhere:
            print("same name, other type (NOT used): %s id=%s type=%s" % (v.get("name"), v.get("id"), v.get("gameVersionTypeID")))
        raise ReleaseError("no exact CurseForge game version for: %s (WoW Forever type %d). Nothing is guessed."
                           % (", ".join(missing), FOREVER_TYPE_ID))
    return 0


def multipart(fields, file_field, filename, file_bytes):
    boundary = "----steproute" + uuid.uuid4().hex
    out = []
    for name, value in fields.items():
        out.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n" % (boundary, name)).encode("utf-8"))
        out.append(value.encode("utf-8") + b"\r\n")
    out.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
                "Content-Type: application/zip\r\n\r\n" % (boundary, file_field, filename)).encode("utf-8"))
    out.append(file_bytes + b"\r\n")
    out.append(("--%s--\r\n" % boundary).encode("utf-8"))
    return b"".join(out), "multipart/form-data; boundary=" + boundary


def cmd_upload(args):
    root = Path(args.root)
    info = check(root, args.tag)
    version = info["version"]
    zip_path = Path(args.zip)
    if zip_path.name != "%s-%s.zip" % (ADDON, version):
        raise ReleaseError("zip name %s does not match toc Version %s" % (zip_path.name, version))
    if not zip_path.is_file():
        raise ReleaseError("missing %s" % zip_path)
    project = str(args.project_id or "").strip()
    if not args.dry_run and not re.fullmatch(r"\d+", project):
        raise ReleaseError("CF_PROJECT_ID is empty or not a number")
    token = need_token(skip_ok=args.dry_run)
    if token:
        versions = fetch_versions(args.site, token)
        ids, missing, elsewhere = match_versions(versions, info["game_versions"])
        if missing:
            raise ReleaseError("no exact CurseForge game version for: %s (WoW Forever type %d). Nothing is guessed."
                               % (", ".join(missing), FOREVER_TYPE_ID))
    else:
        ids = []
    metadata = {
        "displayName": "%s %s" % (ADDON, version),
        "gameVersions": ids,
        "releaseType": info["type"],
        "changelog": info["changelog"],
        "changelogType": "markdown",
    }
    data = zip_path.read_bytes()
    if args.dry_run:
        print("dry run: nothing is sent to CurseForge")
        print("file: %s (%d bytes, sha256 %s)" % (zip_path.name, len(data), hashlib.sha256(data).hexdigest()))
        print("project id: %s" % (project or "-"))
        print("metadata: %s" % json.dumps(metadata, indent=2))
        if not token:
            print("no CF_API_KEY: game version ids not looked up")
        return 0
    body, ctype = multipart({"metadata": json.dumps(metadata)}, "file", zip_path.name, data)
    status, answer = http("POST", "%s/api/projects/%s/upload-file" % (args.site, project), token, body,
                          {"Content-Type": ctype})
    try:
        file_id = json.loads(answer).get("id")
    except ValueError:
        file_id = None
    print("uploaded %s as %s %s, CurseForge file id %s" % (zip_path.name, info["type"], version, file_id))
    return 0


# --------------------------------------------------------------------------- main


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--root", default=str(ROOT), help="repo folder (tests use a temp copy)")
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("check")
    a.add_argument("--tag")
    b = sub.add_parser("build")
    b.add_argument("--out", default="dist")
    b.add_argument("--check-stage", action="store_true")
    c = sub.add_parser("versions")
    c.add_argument("--skip-if-no-token", action="store_true")
    c.add_argument("--site", default=SITE)
    d = sub.add_parser("upload")
    d.add_argument("--zip", required=True)
    d.add_argument("--project-id", default=os.environ.get("CF_PROJECT_ID", ""))
    d.add_argument("--tag")
    d.add_argument("--dry-run", action="store_true")
    d.add_argument("--site", default=SITE)
    args = p.parse_args(argv)
    try:
        if args.cmd == "check":
            info = check(args.root, args.tag)
            print("version %s, release type %s, game versions %s" % (info["version"], info["type"], ", ".join(info["game_versions"])))
            print("changelog:\n%s" % info["changelog"])
            return 0
        if args.cmd == "build":
            zip_path, contents = build(args.root, args.out, args.check_stage)
            for k in sorted(contents):
                print("%s *%s" % (contents[k], k))
            print("built %s (%d bytes)%s" % (zip_path, zip_path.stat().st_size, ", same files as stage" if args.check_stage else ""))
            return 0
        if args.cmd == "versions":
            return cmd_versions(args)
        if args.cmd == "upload":
            return cmd_upload(args)
    except ReleaseError as e:
        print("ERROR: %s" % scrub(e, os.environ.get("CF_API_KEY", "").strip()), file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
