import hashlib, importlib.util, json, pathlib, tempfile, unittest
spec=importlib.util.spec_from_file_location('releases',pathlib.Path(__file__).with_name('android-release.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class PublicationTest(unittest.TestCase):
    def test_publish_retry_rollback_and_signature_guard(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder)/'public';incoming=pathlib.Path(folder)/'incoming';incoming.mkdir()
            for name in ('index.html','downloads.js','downloads.css'): (incoming/name).write_text('asset')
            def payload(content,filename,signer='a'*64):
                (incoming/'app.apk').write_bytes(content)
                meta={'package':'com.pointverse.app','file':filename,'sha256':hashlib.sha256(content).hexdigest(),'size':len(content),'signerSha256':signer}
                (incoming/'release.json').write_text(json.dumps(meta))
            def read():return json.loads((root/'releases.json').read_text())
            payload(b'first','first.apk');module.publish(root,incoming);module.publish(root,incoming)
            self.assertEqual(len(read()['releases']),1)
            payload(b'second','second.apk');module.publish(root,incoming)
            module.publish(root,activate='first.apk');self.assertEqual(read()['latest'],'first.apk');self.assertEqual(len(read()['releases']),2)
            payload(b'changed signer','third.apk','b'*64)
            with self.assertRaises(ValueError):module.publish(root,incoming)
            self.assertEqual(read()['latest'],'first.apk');self.assertFalse((root/'files'/'third.apk').exists())
            payload(b'replaced','first.apk')
            with self.assertRaises(ValueError):module.publish(root,incoming)
            (root/'files'/'second.apk').write_bytes(b'corrupt')
            with self.assertRaises(ValueError):module.publish(root,activate='second.apk')
            self.assertEqual(read()['latest'],'first.apk')

if __name__=='__main__':unittest.main()
