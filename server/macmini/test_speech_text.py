import unittest
from speech_text import transcription_result

class SpeechTextTests(unittest.TestCase):
    def test_chinese_text_and_segments_are_simplified_with_raw_output_preserved(self):
        segments=[{"start":0.5,"end":2.5,"text":" 這臺設備正在進行語音識別。"}]
        result=transcription_result(segments,"zh","whisper-test")
        self.assertEqual(result["text"],"这台设备正在进行语音识别。")
        self.assertEqual(result["raw_text"],"這臺設備正在進行語音識別。")
        self.assertEqual(result["text_script"],"Hans")
        self.assertEqual(result["segments"][0]["start"],0.5)
        self.assertEqual(result["segments"][0]["end"],2.5)
        self.assertIn("這",segments[0]["text"])

    def test_other_languages_and_already_simplified_text_stay_unchanged(self):
        for language,text in [("en","Hello world."),("ja","今日は晴れです。"),("zh","语音识别测试。")]:
            result=transcription_result([{"start":0,"end":1,"text":text}],language,"model")
            self.assertEqual(result["text"],text)
            self.assertNotIn("raw_text",result)

if __name__=="__main__":unittest.main()
