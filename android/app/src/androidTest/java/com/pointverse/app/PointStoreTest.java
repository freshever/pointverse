package com.pointverse.app;

import android.test.InstrumentationTestCase;
import java.io.*;
import java.util.*;

@SuppressWarnings("deprecation")
public final class PointStoreTest extends InstrumentationTestCase {
    private PointStore store;
    private String name;
    @Override protected void setUp() throws Exception {
        super.setUp(); name="test-"+UUID.randomUUID()+".db";
        store=new PointStore(getInstrumentation().getTargetContext(),name);
    }
    @Override protected void tearDown() throws Exception {
        store.close(); getInstrumentation().getTargetContext().deleteDatabase(name);
        removeTree(store.audio.getParentFile()); super.tearDown();
    }
    private void removeTree(File f) { File[] files=f.listFiles(); if(files!=null) for(File c:files) removeTree(c); f.delete(); }
    private File fixture() throws Exception {
        File file=store.newRecording();
        try(InputStream input=getInstrumentation().getContext().getAssets().open("tone.m4a"); OutputStream out=new FileOutputStream(file)) {
            byte[] buffer=new byte[4096]; int n; while((n=input.read(buffer))!=-1) out.write(buffer,0,n);
        }
        return file;
    }
    public void testSavedOriginalCanBePlayed() throws Exception {
        store.commitAudio(fixture());
        android.media.MediaPlayer player=new android.media.MediaPlayer();
        try {
            player.setDataSource(store.audioFile(store.list("").get(0)).getAbsolutePath());
            player.prepare(); assertTrue(player.getDuration()>0); player.start(); assertTrue(player.isPlaying());
        } finally { player.release(); }
    }
    public void testCloudAudioIsPCM16Mono16kWAV() throws Exception {
        File file=fixture(); final int[] calls={0};
        String text=CloudTranscription.decode(file,wav-> {
            calls[0]++; java.nio.ByteBuffer b=java.nio.ByteBuffer.wrap(wav).order(java.nio.ByteOrder.LITTLE_ENDIAN);
            assertEquals("RIFF",new String(wav,0,4,java.nio.charset.StandardCharsets.US_ASCII));
            assertEquals(16000,b.getInt(24)); assertEquals(1,b.getShort(22)); assertEquals(16,b.getShort(34));
            assertEquals(wav.length-44,b.getInt(40)); assertTrue(wav.length>30000); return "识别内容";
        });
        assertEquals(1,calls[0]); assertEquals("识别内容",text);
    }
    public void testAccountTokenIsEncryptedAndRestored() throws Exception {
        android.content.Context context=getInstrumentation().getTargetContext();
        AccountSession session=new AccountSession(context); session.clear();
        org.json.JSONObject object=new org.json.JSONObject().put("token_type","Bearer").put("access_token","instrumentation-secret")
            .put("expires_at",java.time.Instant.now().plusSeconds(3600).toString()).put("user",new org.json.JSONObject().put("display_name","测试账户"));
        try {
            session.save(object);
            assertEquals("instrumentation-secret",new AccountSession(context).token());
            String stored=context.getSharedPreferences("account-session",0).getString("session","");
            assertFalse(stored.contains("instrumentation-secret"));
        } finally { session.clear(); }
        assertEquals("",new AccountSession(context).token());
    }
    public void testUpgradeFromOriginalDatabasePreservesText() throws Exception {
        store.close();getInstrumentation().getTargetContext().deleteDatabase(name);
        android.database.sqlite.SQLiteDatabase old=getInstrumentation().getTargetContext().openOrCreateDatabase(name,0,null);
        old.execSQL("CREATE TABLE points (id TEXT PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,created INTEGER NOT NULL,audio_path TEXT,duration INTEGER NOT NULL DEFAULT 0,sha256 TEXT)");
        old.execSQL("INSERT INTO points(id,title,body,created) VALUES('legacy','旧标题','旧内容',12345)");old.setVersion(1);old.close();
        store=new PointStore(getInstrumentation().getTargetContext(),name);assertEquals("旧内容",store.get("legacy").effective());assertEquals(1,store.get("legacy").revision);
    }
    public void testCandidatesNeverOverwriteUserCorrection() throws Exception {
        store.commitAudio(fixture());String id=store.list("").get(0).id;
        store.addCandidate(id,"local","初始转写");assertEquals("初始转写",store.get(id).effective());
        store.update(id,"标题","人工修正");store.addCandidate(id,"cloud","另一个候选");assertEquals("人工修正",store.get(id).effective());assertEquals(2,store.rows("candidates",id).length());
        assertEquals(1,store.list("另一个候选").size());
    }
    public void testTrashRestoreAndPurgeDoNotResurrectAudio() throws Exception {
        store.commitAudio(fixture());PointStore.Point point=store.list("").get(0);byte[] original=java.nio.file.Files.readAllBytes(store.audioFile(point).toPath());
        store.trash(point.id,true);assertEquals(0,store.list("").size());assertEquals(1,store.list("",true).size());store.recover();assertEquals(0,store.list("").size());
        store.trash(point.id,false);assertEquals(1,store.list("").size());store.trash(point.id,true);store.purge(point.id);
        // Simulate a process crash after DB deletion and before file cleanup.
        java.nio.file.Files.write(store.audioFile(point).toPath(),original);store.recover();assertEquals(0,store.list("").size());
    }
    public void testSnapshotIsStableAndContainsOriginalAndCorrection() throws Exception {
        store.commitAudio(fixture());String id=store.list("").get(0).id;store.addCandidate(id,"local","机器原文");store.update(id,"标题","人工修正");
        CloudSync sync=new CloudSync(store);org.json.JSONObject a=sync.snapshot(store.get(id)),b=sync.snapshot(store.get(id));assertEquals(a.toString(),b.toString());
        assertEquals(1,a.getInt("format_version"));assertEquals("audio",a.getJSONArray("assets").getJSONObject(0).getString("kind"));
        org.json.JSONObject transcript=a.getJSONObject("payload").getJSONArray("transcripts").getJSONObject(0);assertEquals("机器原文",transcript.getString("engine_text"));assertEquals("人工修正",transcript.getString("user_text"));
    }
    public void testRealOfflineChineseSpeechRecognition() throws Exception {
        android.content.Context target=getInstrumentation().getTargetContext();File archive=new File(target.getFilesDir(),"test-speech-model.zip");
        assertTrue("将官方模型推送到测试设备的 files/test-speech-model.zip",archive.exists());
        LocalSpeech recognizer=new LocalSpeech(target);if(!recognizer.available())recognizer.install(archive,text->{});
        File speech=new File(store.staging,"speech.m4a");try(InputStream in=getInstrumentation().getContext().getAssets().open("speech-cn.m4a");OutputStream out=new FileOutputStream(speech)){byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1)out.write(b,0,n);}
        String text=recognizer.transcribe(speech,value->{});assertTrue("识别结果："+text,text.contains("想法")||text.contains("人工智能")||text.contains("知识"));
        android.util.Log.i("PointVerseOfflineTest","Chinese offline ASR result: "+text);
    }
    public void testTextSurvivesReopenAndLiteralSearch() {
        String id=store.createText("想法 100%_", "Android 9 离线保存");
        store.close(); store=new PointStore(getInstrumentation().getTargetContext(),name);
        assertEquals(1,store.list("Android").size()); assertEquals(1,store.list("100%_").size());
        assertEquals(0,store.list("' OR 1=1 --").size());
        store.update(id,"修正标题","新的补充文字");
        assertEquals(0,store.list("Android").size()); assertEquals(1,store.list("补充").size());
    }
    public void testAudioCommitIsIdempotentAndPreservesEdits() throws Exception {
        File source=fixture(); store.commitAudio(source);
        PointStore.Point point=store.list("").get(0);
        assertFalse(source.exists()); assertTrue(store.audioFile(point).isFile()); assertTrue(point.duration>0);
        store.update(point.id,"我的标题","人工补充"); store.commitAudio(store.audioFile(point));
        assertEquals(1,store.list("").size()); assertEquals("我的标题",store.list("").get(0).title);
    }
    public void testRecoversBothSidesOfFileDatabaseGap() throws Exception {
        File staging=fixture(); File other=fixture();
        File orphan=new File(store.audio,other.getName()); assertTrue(other.renameTo(orphan));
        assertEquals(0,store.recover()); assertEquals(2,store.list("").size()); assertFalse(staging.exists());
        assertEquals(0,store.recover()); assertEquals(2,store.list("").size());
    }
    public void testIncompleteRecordingIsPreservedWithoutFalseSuccess() throws Exception {
        File file=store.newRecording(); try(FileOutputStream out=new FileOutputStream(file)) { out.write(new byte[]{1,2,3}); }
        assertEquals(1,store.recover()); assertTrue(file.exists()); assertTrue(store.list("").isEmpty());
    }
}
