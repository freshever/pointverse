import json
import tempfile
import threading
import unittest
import uuid
import sys
from pathlib import Path
from unittest.mock import patch
import media_backend as media
from model_adapters import OpenAICompatibleAdapter, LocalProcessAdapter

class MediaTests(unittest.TestCase):
    def test_embedding_limits_and_prefix_contract(self):
        self.assertEqual(media.validate("embeddings", {"input": "你好"})["input_type"], "passage")
        for value in ([], ["x"] * 17, ["x" * 2001], [1]):
            with self.assertRaises(ValueError): media.validate("embeddings", {"input": value})
        with self.assertRaises(ValueError): media.validate("embeddings", {"input": "x", "input_type": "untrusted"})

    def test_image_size_seed_and_idempotency_key_are_bounded(self):
        payload = {"prompt": "a tree", "request_id": str(uuid.uuid4())}
        self.assertEqual(media.validate("image", payload)["prompt"], "a tree")
        for change in ({"size": "4096x4096"}, {"n": 2}, {"seed": True}, {"request_id": "../escape"}):
            with self.assertRaises(ValueError): media.validate("image", {**payload, **change})

    def test_image_jobs_are_owner_scoped_and_retry_safe(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(media, "STORE", Path(temp)), patch.object(media, "DB", Path(temp) / "jobs.sqlite"), patch.object(media.threading, "Thread"):
            jobs = media.ImageJobs(threading.Semaphore(1), threading.Semaphore(3), lambda: True, lambda: None, lambda x: x)
            owner, other = str(uuid.uuid4()), str(uuid.uuid4())
            payload = media.validate("image", {"prompt": "a tree", "request_id": str(uuid.uuid4())})
            first = jobs.create(owner, payload)
            self.assertEqual(jobs.create(owner, payload)["id"], first["id"])
            self.assertIsNone(jobs.get(other, first["id"]))
            self.assertEqual(jobs.get(owner, first["id"])["status"], "queued")
            self.assertIsNone(jobs.create(owner, {**payload, "request_id": str(uuid.uuid4())}))
            self.assertIsNone(jobs.cancel(other, first["id"]))
            self.assertEqual(jobs.cancel(owner, first["id"])["status"], "cancelled")
            # A restart never turns partial running output into success.
            with jobs.connection() as db: db.execute("UPDATE jobs SET state='running'")
            restarted = media.ImageJobs(threading.Semaphore(1), threading.Semaphore(3), lambda: True, lambda: None, lambda x: x)
            self.assertEqual(restarted.get(owner, first["id"])["error"], "worker_restarted")

    def test_external_adapter_requires_operator_enable_and_explicit_consent(self):
        with patch("model_adapters.http.client.HTTPSConnection") as connection:
            adapter = OpenAICompatibleAdapter("https://api.example.com/v1", "fixed-model", "POINTVERSE_PROVIDER_TEST")
            with self.assertRaises(PermissionError): adapter.execute({"messages": []}, allow_external=True)
            adapter = OpenAICompatibleAdapter("https://api.example.com/v1", "fixed-model", "POINTVERSE_PROVIDER_TEST", enabled=True)
            with self.assertRaises(PermissionError): adapter.execute({"messages": []})
            connection.assert_not_called()
        for url in ("http://api.example.com", "https://127.0.0.1", "https://user:secret@api.example.com"):
            with self.assertRaises(ValueError): OpenAICompatibleAdapter(url, "fixed", "POINTVERSE_PROVIDER_TEST")

    def test_local_cancellation_stops_the_child_process(self):
        adapter = LocalProcessAdapter((sys.executable, "-c", "import json,sys,time;json.load(sys.stdin);time.sleep(30)"), timeout=5, cancelled=lambda: True)
        with self.assertRaisesRegex(RuntimeError, "inference_cancelled"):
            adapter.execute({})

if __name__ == "__main__": unittest.main()
