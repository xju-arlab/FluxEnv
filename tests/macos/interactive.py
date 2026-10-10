#!/usr/bin/env python3
"""Run the mocked installer in a PTY to verify the real interactive prompts."""
import errno
import os
import pty
import select
import subprocess
import sys
import time

entry, scenario = sys.argv[1:]
task_root = os.environ["FLUXENV_TEST_ROOT"]
questions = [
    ("是否修改这台 Mac 的设备名？", "y\n"),
    ("请输入新设备显示名", "   \n"),
    ("请输入新设备显示名", "交互测试 Mac\n"),
    ("Bonjour/主机名 [", "bad name\n"),
    ("Bonjour/主机名 [", "interactive-mac\n"),
    ("确认修改以上三个名字？", "y\n" if scenario == "rename" else "n\n"),
    ("是否现在用浏览器设备码登录 Hugging Face？", "n\n"),
]
extra_args = []
if scenario in ("auth", "auth_reuse"):
    questions = [("Authorize in browser [Enter]:", "\n")] if scenario == "auth" else []
    extra_args = ["--hf-login", "--skip-device-name"]
master, slave = pty.openpty()
process = subprocess.Popen(
    ["/bin/bash", entry, "--config", os.path.join(task_root, "config.env"), *extra_args],
    stdin=slave, stdout=slave, stderr=slave,
)
os.close(slave)
deadline = time.monotonic() + 20
pending = b""
transcript = b""
index = 0
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            pending += chunk
            transcript += chunk
            if index < len(questions):
                prompt, response = questions[index]
                marker = prompt.encode("utf-8")
                if marker in pending:
                    pending = pending.split(marker, 1)[1]
                    os.write(master, response.encode("utf-8"))
                    index += 1
        elif process.poll() is not None:
            break
    if process.poll() is None:
        process.kill()
    status = process.wait()
    if status != 0 or index != len(questions):
        sys.stderr.write(transcript.decode("utf-8", errors="replace"))
        raise SystemExit("interactive installer failed or did not ask every prompt")
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
