import base64
import io
import json
import os
from pathlib import Path
import plistlib
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
import wave

from model_storage import model_storage_ready
from qwen_speech_result import format_result


class StorageTests(unittest.TestCase):
    def test_missing_volume_never_creates_internal_fallback(self):
        with tempfile.TemporaryDirectory() as name:
            volume=Path(name)/'missing';root=volume/'PointVerse/models'
            self.assertFalse(model_storage_ready(root,str(volume),'expected'))
            self.assertFalse(volume.exists())

    def test_volume_identity_free_space_and_model_containment(self):
        with tempfile.TemporaryDirectory() as name:
            volume=Path(name);root=volume/'models';root.mkdir()
            info={'VolumeUUID':'expected','MountPoint':str(volume),'Internal':False}
            with patch('model_storage.os.path.ismount',return_value=True),patch('model_storage.subprocess.check_output',return_value=plistlib.dumps(info)),patch('model_storage.shutil.disk_usage',return_value=SimpleNamespace(free=20*(1<<30))):
                self.assertTrue(model_storage_ready(root,str(volume),'expected'))
                self.assertFalse(model_storage_ready(root,str(volume),'other-volume'))
                self.assertFalse(model_storage_ready(Path('/tmp'),str(volume),'expected'))
            with patch('model_storage.os.path.ismount',return_value=False):
                self.assertFalse(model_storage_ready(root,str(volume),'expected'))


class ResultTests(unittest.TestCase):
    def test_mixed_languages_keep_raw_text_and_real_chunk_timestamps(self):
        output=SimpleNamespace(generation_tokens=30,segments=[{'text':'這臺設備正在識別。','language':'Chinese','start':0,'end':3},{'text':'Hello world.','language':'English','start':3,'end':5}])
        result=format_result(output,5)
        self.assertEqual(result['text'],'这台设备正在识别。 Hello world.')
        self.assertEqual(result['raw_text'],'這臺設備正在識別。 Hello world.')
        self.assertEqual(result['language'],'mixed');self.assertEqual(result['model'],'qwen3-asr-1.7b')
        self.assertEqual(result['segments'][1]['start'],3);self.assertEqual(result['segments'][1]['language'],'en')
        self.assertEqual(result['timestamp_granularity'],'chunk')

    def test_other_languages_are_not_normalized_as_chinese(self):
        text='今日は晴れです。';output=SimpleNamespace(generation_tokens=10,segments=[{'text':text,'language':'Japanese','start':0,'end':1}])
        result=format_result(output,1);self.assertEqual(result['text'],text);self.assertNotIn('raw_text',result);self.assertEqual(result['language'],'ja')

    def test_truncated_or_out_of_bounds_output_is_not_saved_as_complete(self):
        for output in [SimpleNamespace(generation_tokens=4096,segments=[]),SimpleNamespace(generation_tokens=10,segments=[{'text':'partial','start':0,'end':3}]),SimpleNamespace(generation_tokens=10,segments=[{'text':'bad','start':-1,'end':5}])]:
            with self.assertRaises(ValueError):format_result(output,5)


if __name__=='__main__':unittest.main()
