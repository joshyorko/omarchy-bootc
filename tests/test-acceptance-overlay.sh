#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Exercise the real offline rule-writing RUN in an isolated filesystem fixture.
# UFW is replaced only at the external firewall boundary: it leaves the same
# lock file as the hosted failure and refuses an enabled firewall or other args.
python3 - "${root}/scripts/ci/acceptance-overlay.Containerfile" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

text = Path(sys.argv[1]).read_text().replace("\\\n", " ")
runs = re.findall(r"^RUN (.+)$", text, re.M)
rules = [run for run in runs if "ufw allow" in run]
assert len(rules) == 1, "expected one offline UFW setup step"
assert "bootc container lint --fatal-warnings" in runs, "fatal lint is required"
with tempfile.TemporaryDirectory(prefix="acceptance-overlay-") as tmp:
    root = Path(tmp)
    for directory in ("etc/ufw", "run", "tmp", "bin"):
        (root / directory).mkdir(parents=True)
    conf = root / "etc/ufw/ufw.conf"
    conf.write_text("ENABLED=yes\nLOGLEVEL=low\n")
    ufw = root / "bin/ufw"
    ufw.write_text('''#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "allow 22/tcp comment disposable acceptance SSH" ]]
grep -Fxq ENABLED=no "$FIXTURE_ROOT/etc/ufw/ufw.conf"
: > "$FIXTURE_ROOT/run/ufw.lock"
printf 'allow ssh fixture\\n' > "$FIXTURE_ROOT/etc/ufw/user.rules"
''')
    ufw.chmod(0o755)
    command = rules[0].replace("/etc/ufw", f"{root}/etc/ufw")
    command = command.replace("/run/ufw.lock", f"{root}/run/ufw.lock")
    env = dict(os.environ, FIXTURE_ROOT=str(root), PATH=f"{root}/bin:{os.environ['PATH']}")
    subprocess.run(["bash", "-euo", "pipefail", "-c", command], env=env, check=True)
    assert conf.read_text() == "ENABLED=yes\nLOGLEVEL=low\n", "firewall state was not restored"
    assert (root / "etc/ufw/user.rules").is_file(), "offline rules were discarded"
    for directory in ("run", "tmp"):
        assert not list((root / directory).iterdir()), f"nonempty runtime directory: /{directory}"
print("PASS: offline UFW setup restores enabled policy and leaves /run and /tmp empty (fixture)")
PY
