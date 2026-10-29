import http.client
import json
import os
import threading
import unittest
import base64
import io
import wave
from unittest.mock import patch

os.environ.setdefault("POINTVERSE_AI_TOKEN", "test-token-" * 4)
import ai_gateway as gateway


class GatewayTests(unittest.TestCase):
    def test_vision_accepts_inline_image_and_rejects_remote_fetch(self):
        png = base64.b64encode(b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" + (1).to_bytes(4, "big") * 2 + b"\x08\x02\x00\x00\x00" + b"\x00" * 4).decode()
        def message(url):
            return [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": url}}]}]
        gateway.validate_messages(message("data:image/png;base64," + png))
        for url in ["http://127.0.0.1:15432", "https://example.com/a.png", "file:///etc/passwd", "data:image/png;base64,broken"]:
            with self.assertRaises(ValueError):
                gateway.validate_messages(message(url))
        self.assertEqual(self.request({"messages": message("http://127.0.0.1:15432")})[0], 400)

    def test_vision_rejects_decompression_dimensions_and_multiple_images(self):
        data = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" + (100000).to_bytes(4, "big") * 2 + b"\x00" * 9
        part = {"type": "image_url", "image_url": {"url": "data:image/png;base64," + base64.b64encode(data).decode()}}
        with self.assertRaises(ValueError): gateway.validate_messages([{"role": "user", "content": [part]}])
        with self.assertRaises(ValueError): gateway.validate_messages([{"role": "user", "content": [part, part]}])

    def test_memory_cleanup_unloads_only_alternate_or_both_for_speech(self):
        with patch.object(gateway.http.client, "HTTPConnection") as connection:
            connection.return_value.getresponse.return_value.status = 200
            gateway.unload_chat_models(keep="qwen3.5:4b")
            args = connection.return_value.request.call_args_list
            self.assertEqual(len(args), 1)
            self.assertEqual(json.loads(args[0].args[2])["model"], "qwen3.5:9b")
            connection.return_value.request.reset_mock()
            gateway.unload_chat_models()
            self.assertEqual(connection.return_value.request.call_count, 2)
    def test_cloud_aliases_and_unapproved_model(self):
        self.assertEqual(gateway.selected_chat_model("pointverse-cloud"), "qwen3.5:4b")
        self.assertEqual(gateway.selected_chat_model("pointverse-cloud-enhanced"), "qwen3.5:9b")
        self.assertEqual(gateway.selected_chat_model("unapproved:large"), gateway.MODEL)
    def test_audio_rejects_stereo_and_truncated_data(self):
        for channels in (1, 2):
            data = io.BytesIO()
            with wave.open(data, "wb") as wav:
                wav.setnchannels(channels)
                wav.setsampwidth(2)
                wav.setframerate(16000)
                wav.writeframes(b"\x00\x00" * 1600 * channels)
            audio = data.getvalue()
            if channels == 1:
                self.assertEqual(gateway.validate_audio({"audio": base64.b64encode(audio).decode()}), audio)
            else:
                with self.assertRaises(ValueError):
                    gateway.validate_audio({"audio": base64.b64encode(audio).decode()})
        with self.assertRaises(ValueError):
            gateway.validate_audio({"audio": base64.b64encode(audio[:-10]).decode()})

    def test_qwen_speech_keeps_existing_http_contract_and_cleans_temp_audio(self):
        import types
        from pathlib import Path
        audio=io.BytesIO()
        with wave.open(audio,"wb") as wav:
            wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(16000);wav.writeframes(b"\x00\x00"*1600)
        captured=[]
        def execute(args,**kwargs):
            self.assertEqual(args[0],"/approved/asr-runtime/bin/python");self.assertTrue(args[1].endswith("transcribe-qwen.py"));self.assertEqual(args[2],"/external/models/qwen3-asr-1.7b")
            self.assertEqual(kwargs["timeout"],120);self.assertTrue(Path(args[3]).is_file());captured.append(args[3])
            return types.SimpleNamespace(stdout=json.dumps({"text":"测试语音。","model":"qwen3-asr-1.7b"}).encode())
        with patch.object(gateway,"speech_ready",return_value=True),patch.object(gateway,"resources_ready",return_value=True),patch.object(gateway,"unload_chat_models"),patch.object(gateway,"SPEECH_PYTHON","/approved/asr-runtime/bin/python"),patch.object(gateway,"SPEECH_RUNNER","transcribe-qwen.py"),patch.object(gateway,"SPEECH_MODEL","/external/models/qwen3-asr-1.7b"),patch.object(gateway.subprocess,"run",side_effect=execute):
            conn=http.client.HTTPConnection(*self.server.server_address,timeout=5)
            conn.request("POST","/v1/audio/transcriptions",json.dumps({"audio":base64.b64encode(audio.getvalue()).decode(),"model":"/untrusted/ignored"}),{"Content-Type":"application/json","Authorization":"Bearer "+os.environ["POINTVERSE_AI_TOKEN"]})
            response=conn.getresponse();result=json.loads(response.read());conn.close()
        self.assertEqual(response.status,200);self.assertEqual(result["model"],"qwen3-asr-1.7b");self.assertEqual(result["text"],"测试语音。")
        self.assertFalse(Path(captured[0]).exists())

    def test_unavailable_external_models_do_not_advertise_speech(self):
        with patch.object(gateway,"model_storage_ready",return_value=False):self.assertFalse(gateway.speech_ready())

    @classmethod
    def setUpClass(cls):
        cls.server = gateway.ThreadingHTTPServer(("127.0.0.1", 0), gateway.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def request(self, payload, token=True):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + os.environ["POINTVERSE_AI_TOKEN"]
        conn.request("POST", "/v1/chat/completions", json.dumps(payload), headers)
        response = conn.getresponse()
        result = response.status, json.loads(response.read())
        conn.close()
        return result

    def test_authentication_precedes_inference(self):
        self.assertEqual(self.request({}, token=False)[0], 401)

    def test_disk_pressure_rejects_without_inference(self):
        with patch.object(gateway, "resources_ready", return_value=False):
            status, body = self.request({"messages": [{"role": "user", "content": "hi"}]})
        self.assertEqual(status, 503)
        self.assertEqual(body["error"]["code"], "insufficient_disk_space")

    def test_full_admission_rejects_without_waiting(self):
        slots = threading.BoundedSemaphore(1)
        slots.acquire()
        with patch.object(gateway, "ADMISSION", slots), patch.object(gateway, "resources_ready", return_value=True):
            status, body = self.request({"messages": [{"role": "user", "content": "hi"}]})
        self.assertEqual(status, 503)
        self.assertEqual(body["error"]["code"], "node_busy")

    def test_invalid_token_limit_rejected(self):
        self.assertEqual(self.request({"messages": [{}], "max_tokens": -1})[0], 400)


if __name__ == "__main__":
    unittest.main()
