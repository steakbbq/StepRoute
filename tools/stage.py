r"""Build stage\StepRoute from src and write stage\StepRoute.md5 (one 'md5 *StepRoute/file' line per file).

    python -I tools\stage.py

Does not touch the game folder. The coordinator installs from stage\StepRoute.
"""
import hashlib
import os
import shutil
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = os.path.join(ROOT, "src")
STAGE = os.path.join(ROOT, "stage")
OUT = os.path.join(STAGE, "StepRoute")


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    names = sorted(os.listdir(SRC))
    lines = []
    for name in names:
        shutil.copyfile(os.path.join(SRC, name), os.path.join(OUT, name))
        lines.append("%s *StepRoute/%s" % (md5(os.path.join(OUT, name)), name))
    manifest = os.path.join(STAGE, "StepRoute.md5")
    with open(manifest, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    print("manifest md5 %s" % md5(manifest))
    return 0


if __name__ == "__main__":
    sys.exit(main())
