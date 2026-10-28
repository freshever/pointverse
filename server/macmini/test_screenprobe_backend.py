import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import screenprobe_backend as backend

class DesktopTests(unittest.TestCase):
    def test_unarmed_never_starts_process(self):
        with patch.object(backend, "ready", return_value=False), patch.object(backend.subprocess, "Popen") as process:
            with self.assertRaises(RuntimeError):
                backend.complete([{"role":"user", "content":"hello"}])
            process.assert_not_called()

    def test_response_conversion_and_one_shot(self):
        with tempfile.TemporaryDirectory() as root:
            arm = Path(root)/"armed"
            arm.write_text(json.dumps({"allow_next":True}))
            def fake_process(args, **kwargs):
                folder = Path(args[-1])/"capture"
                folder.mkdir()
                (folder/"answer.txt").write_text("从前有座山。")
                class Process:
                    returncode = 0
                    def wait(self, timeout): pass
                return Process()
            with patch.object(backend, "ARM_FILE", arm), patch.object(backend, "ready", return_value=True), patch.object(backend.subprocess, "Popen", side_effect=fake_process):
                result = backend.complete([{"role":"system", "content":"Reply in Chinese"}, {"role":"user", "content":"任何测试文字"}])
            self.assertEqual(result["choices"][0]["message"]["content"], "从前有座山。")
            self.assertFalse(arm.exists())

if __name__ == "__main__": unittest.main()
