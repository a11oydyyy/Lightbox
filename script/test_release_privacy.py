#!/usr/bin/env python3
import os
import pathlib
import subprocess
import tempfile
import unittest
import zipfile

CHECK = pathlib.Path(__file__).with_name("check_release_privacy.py").resolve()
SAFE = "123+test@users.noreply.github.com"


class ReleasePrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        for key in list(self.env):
            if key.startswith(("GIT_AUTHOR_", "GIT_COMMITTER_")):
                del self.env[key]
        self.git("init", "-q")
        self.git("config", "user.name", "test")
        self.git("config", "user.email", SAFE)
        self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, env=self.env)

    def commit(self):
        self.git("-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "fixture")

    def check(self, *args, stdin=None):
        return subprocess.run(["python3", str(CHECK), *args], cwd=self.root,
                              env=self.env, input=stdin, capture_output=True, text=True)

    def test_clean_identity_and_history_pass(self):
        self.assertEqual(self.check("identity").returncode, 0)

    def test_private_ancestor_is_rejected_even_with_clean_tip(self):
        self.env["GIT_AUTHOR_EMAIL"] = "fixture@gmail.com"
        self.commit()
        del self.env["GIT_AUTHOR_EMAIL"]
        self.commit()
        result = self.check("refs", "HEAD")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("fixture@gmail.com", result.stderr)

    def test_private_committer_is_rejected(self):
        self.env["GIT_COMMITTER_EMAIL"] = "fixture@gmail.com"
        self.commit()
        self.assertNotEqual(self.check("refs", "HEAD").returncode, 0)

    def test_private_tagger_is_rejected(self):
        self.git("-c", "user.email=fixture@gmail.com", "tag", "-am", "fixture", "v1")
        self.assertNotEqual(self.check("refs", "v1").returncode, 0)

    def test_push_and_delete(self):
        sha = self.git("rev-parse", "HEAD").decode().strip()
        zero = "0" * 40
        self.assertEqual(self.check("pre-push", stdin=f"HEAD {sha} refs/heads/main {zero}\n").returncode, 0)
        self.assertEqual(self.check("pre-push", stdin=f"(delete) {zero} refs/heads/old {sha}\n").returncode, 0)

    def test_bundle_and_zip_reject_embedded_paths_and_email(self):
        app = self.root / "Fixture.app"
        app.mkdir()
        file = app / "binary"
        for data in (b"before\0/Users/fixture/project/main.swift\0after",
                     b"before\0fixture@gmail.com\0after"):
            file.write_bytes(data)
            self.assertNotEqual(self.check("bundle", str(app)).returncode, 0)
            archive = self.root / "fixture.zip"
            with zipfile.ZipFile(archive, "w") as z:
                z.write(file, "Fixture.app/binary")
            self.assertNotEqual(self.check("archive", str(archive)).returncode, 0)
        file.write_bytes(b"/Lightbox/main.swift\0" + SAFE.encode())
        self.assertEqual(self.check("bundle", str(app)).returncode, 0)


if __name__ == "__main__":
    unittest.main()
