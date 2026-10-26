#!/usr/bin/env python3
"""Exercise real launcher processes on Linux without starting Isaac Sim."""
import base64
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import unittest


@unittest.skipUnless(sys.platform == "linux", "requires Linux setsid and /proc")
class LauncherLifecycle(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="isaac-connect-ctl-test-")
        self.root = Path(self.directory.name)
        self.launcher = Path(os.environ.get("ISAAC_CTL_UNDER_TEST", Path(__file__).with_name("isaac-ctl")))
        self.marker = self.root / "child.json"
        self.stub = self.root / "isaacsim"
        self.stub.write_text(
            "#!/usr/bin/python3\n"
            "import json,os,socket,time\n"
            "from pathlib import Path\n"
            "s=socket.socket(); s.bind(('127.0.0.1',int(os.environ['ISAACSIM_STREAM_PORT']))); s.listen()\n"
            "Path(os.environ['ISAAC_TEST_MARKER']).write_text(json.dumps({'pid':os.getpid(),"
            "'sid':os.getsid(0),'pgid':os.getpgrp(),'tunables':os.environ.get('GLIBC_TUNABLES','')}))\n"
            "time.sleep(90)\n"
        )
        self.stub.chmod(0o755)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        (self.root / "runtime").mkdir()
        (self.root / "ctl.conf").write_text("")
        self.env = dict(os.environ)
        self.env.pop("GLIBC_TUNABLES", None)
        self.env.pop("LD_PRELOAD", None)
        self.env.update({
            "XDG_RUNTIME_DIR": str(self.root / "runtime"),
            "ISAAC_CTL_CONF": str(self.root / "ctl.conf"),
            "ISAAC_CTL_LOG": str(self.root / "child.log"),
            "ISAACSIM_BIN": str(self.stub),
            "ISAACSIM_STREAM_IP": "127.0.0.1",
            "ISAACSIM_STREAM_PORT": str(port),
            "ISAACSIM_NVST_DIR": str(self.root / "nvst"),
            "ISAAC_TEST_MARKER": str(self.marker),
        })

    def ctl(self, *args):
        return subprocess.run(["bash", str(self.launcher), *args], env=self.env,
                              capture_output=True, text=True, timeout=20)

    def assert_live_detached(self):
        child = json.loads(self.marker.read_text())
        pid = child["pid"]
        self.assertEqual(child["sid"], pid)
        self.assertEqual(child["pgid"], pid)
        self.assertNotEqual(child["sid"], os.getsid(0))
        self.assertEqual((self.root / "runtime/isaac-ctl.pid").read_text().strip(), str(pid))
        os.kill(pid, 0)  # The launcher command has returned; its detached child survives.
        status = self.ctl("status")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn(f"running pid={pid}", status.stdout)
        return child

    def assert_stopped(self):
        result = self.ctl("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        status = self.ctl("status")
        self.assertEqual(status.returncode, 1, status.stderr)
        self.assertEqual(status.stdout.strip(), "stopped")
        self.assertFalse((self.root / "runtime/isaac-ctl.pid").exists())

    def test_launch_survives_parent_exit_and_stops(self):
        result = self.ctl("launch", "--wait")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ready", result.stdout)
        child = self.assert_live_detached()
        self.assertIn("glibc.rtld.optional_static_tls=2097152", child["tunables"])
        repeat = self.ctl("launch")
        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertIn(f"already running pid={child['pid']}", repeat.stdout)
        self.assert_stopped()

    def test_custom_profile_survives_without_full_app_guards(self):
        command = "exec /usr/bin/python3 " + shlex.quote(str(self.stub))
        encoded = base64.b64encode(command.encode()).decode()
        result = self.ctl("run", encoded, "--wait")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ready", result.stdout)
        self.assertEqual(self.assert_live_detached()["tunables"], "")
        self.assert_stopped()

    def test_invalid_profile_does_not_start_a_process(self):
        result = self.ctl("run", "!invalid-base64!")
        self.assertEqual(result.returncode, 2)
        self.assertIn("base64-decode", result.stderr)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.ctl("status").returncode, 1)

    def tearDown(self):
        # Stop only this test's marker-identified process if an assertion failed.
        if self.marker.exists():
            pid = json.loads(self.marker.read_text())["pid"]
            try:
                command = (Path("/proc") / str(pid) / "cmdline").read_bytes()
                if str(self.stub).encode() in command:
                    os.kill(pid, 15)
                    for _ in range(20):
                        if not (Path("/proc") / str(pid)).exists():
                            break
                        time.sleep(0.1)
            except (FileNotFoundError, ProcessLookupError):
                pass
        self.directory.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
