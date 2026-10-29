package com.pointverse.app;

import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.test.InstrumentationTestCase;
import java.io.*;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

@SuppressWarnings("deprecation")
public final class TitleGenerationTest extends InstrumentationTestCase {
    private PointStore store;private String database,id;private TitleGeneration service;private Policy policy;
    private final AtomicInteger calls=new AtomicInteger();
    private static final class Policy implements TitleGeneration.Policy {
        boolean allowed=true;String token="test-token";
        public boolean allowed(){return allowed;}public String token(){return token;}public String model(){return "pointverse-cloud";}
    }
    @Override protected void setUp()throws Exception {
        super.setUp();database="title-"+UUID.randomUUID()+".db";store=new PointStore(getInstrumentation().getTargetContext(),database);policy=new Policy();
        File file=store.newRecording();try(InputStream input=getInstrumentation().getContext().getAssets().open("tone.m4a");OutputStream out=new FileOutputStream(file)){byte[] block=new byte[8192];int n;while((n=input.read(block))!=-1)out.write(block,0,n);}
        store.commitAudio(file);id=store.list("").get(0).id;
    }
    private TitleGeneration create(TitleGeneration.Generator generator){service=new TitleGeneration(store,policy,generator);return service;}
    private TitleGeneration create(){return create((point,token,model)->{calls.incrementAndGet();assertEquals("test-token",token);return new TitleGeneration.Generated("外接硬盘中的语音模型","actual-title-model");});}
    @Override protected void tearDown()throws Exception {if(service!=null)service.shutdownForTest();store.close();getInstrumentation().getTargetContext().deleteDatabase(database);remove(store.audio.getParentFile());super.tearDown();}
    private void remove(File file){File[] children=file.listFiles();if(children!=null)for(File child:children)remove(child);file.delete();}
    public void testTranscriptImmediatelyReplacesPlaceholderThenCloudSummarizes()throws Exception {
        store.addCandidate(id,"cloud-speech","计划把语音模型放到外接硬盘上。明天开始执行。");
        assertTrue(store.get(id).title.startsWith("计划把语音模型"));assertFalse(store.get(id).title.equals("语音想法"));
        String body=store.get(id).effective();create().process(id,false);PointStore.Point point=store.get(id);
        assertEquals("外接硬盘中的语音模型",point.title);assertEquals("actual-title-model",point.titleModel);assertEquals(body,point.effective());assertTrue(store.audioFile(point).isFile());
        service.process(id,false);assertEquals("相同内容不能反复请求标题",1,calls.get());assertEquals(1,store.list("外接硬盘中的语音模型").size());
    }
    public void testPrivacyOrNoLoginStillUsesTranscriptExcerptWithoutUploading()throws Exception {
        store.addCandidate(id,"offline","今天讨论语音识别的准确率。");policy.allowed=false;create().process(id,false);assertEquals(0,calls.get());assertEquals("今天讨论语音识别的准确率",store.get(id).title);
        policy.allowed=true;policy.token="";service.process(id,false);assertEquals(0,calls.get());policy.token="test-token";service.process(id,false);assertEquals(1,calls.get());
    }
    public void testManualTitleSurvivesRetranscription()throws Exception {
        store.addCandidate(id,"cloud","第一次转写");PointStore.Point point=store.get(id);store.update(id,"我自己的标题",point.effective());store.addCandidate(id,"cloud","第二次转写");
        create().process(id,false);assertEquals("我自己的标题",store.get(id).title);assertEquals(1,store.get(id).titleEdited);assertEquals(0,calls.get());
    }
    public void testEditingTranscriptWithoutChangingTitleKeepsAutomaticTitleEnabled()throws Exception {
        store.addCandidate(id,"cloud","初始识别文字");PointStore.Point point=store.get(id);store.update(id,point.title,"用户纠正后的真实原文");assertEquals(0,store.get(id).titleEdited);
        create((p,t,m)->{assertEquals("用户纠正后的真实原文",p.effective());return new TitleGeneration.Generated("纠正后的主题",m);}).process(id,false);
        assertEquals("纠正后的主题",store.get(id).title);store.addCandidate(id,"cloud","后来另一个机器候选");assertEquals("纠正后的主题",store.get(id).title);assertEquals("用户纠正后的真实原文",store.get(id).effective());
    }
    public void testLateModelReplyCannotOverwriteNewTranscriptTitle()throws Exception {
        store.addCandidate(id,"cloud","旧的语音主题");create((p,t,m)->{store.addCandidate(id,"cloud","新的转写主题");return new TitleGeneration.Generated("旧主题总结",m);}).process(id,false);
        assertEquals("新的转写主题",store.get(id).title);assertEquals("新的转写主题",store.get(id).effective());
    }
    public void testManualChangeDuringForcedGenerationIsProtected()throws Exception {
        store.addCandidate(id,"cloud","转写文字");create((p,t,m)->{store.update(id,"生成期间手工修改",p.effective());return new TitleGeneration.Generated("迟到的标题",m);}).process(id,true);
        assertEquals("生成期间手工修改",store.get(id).title);assertEquals(1,store.get(id).titleEdited);
    }
    public void testTitleFailureDoesNotLoseTranscriptionOrOriginalAudio()throws Exception {
        store.addCandidate(id,"cloud","这是已经识别成功的内容。");create((p,t,m)->{throw new IOException("标题服务不可用");});
        try{service.process(id,false);fail();}catch(IOException expected){}
        assertEquals("这是已经识别成功的内容。",store.get(id).effective());assertEquals("这是已经识别成功的内容",store.get(id).title);assertTrue(store.audioFile(store.get(id)).isFile());
    }
    public void testCandidateSelectionRefreshesTitleAndInvalidatesOldEmbedding()throws Exception {
        store.addCandidate(id,"cloud","旧候选");store.field(id,"embedding","[1,0]");store.selectCandidate(id,"新候选里的完整主题。");assertEquals("新候选里的完整主题",store.get(id).title);assertEquals("",store.get(id).embedding);
    }
    public void testExplicitRegenerationCanReplaceAnExistingManualTitle()throws Exception {
        store.addCandidate(id,"cloud","录音内容");store.update(id,"原人工标题",store.get(id).effective());create().generateNow(id);assertEquals("外接硬盘中的语音模型",store.get(id).title);assertEquals(0,store.get(id).titleEdited);
    }
    public void testReorganizationRefreshesUnchangedAutomaticTitle()throws Exception {
        store.addCandidate(id,"cloud","录音内容");create((p,t,m)->new TitleGeneration.Generated(calls.incrementAndGet()==1?"旧自动标题":"重新整理的新标题",m)).generateNow(id);assertEquals("旧自动标题",store.get(id).title);
        service.regenerateAutomaticNow(id);assertEquals("重新整理必须刷新已生成标题",2,calls.get());assertEquals("重新整理的新标题",store.get(id).title);
    }
    public void testReorganizationPreservesManualTitle()throws Exception {
        store.addCandidate(id,"cloud","录音内容");store.update(id,"手动标题",store.get(id).effective());create().regenerateAutomaticNow(id);
        assertEquals(0,calls.get());assertEquals("手动标题",store.get(id).title);assertEquals(1,store.get(id).titleEdited);
    }
    public void testReorganizationSkipsEmptyRecordingWithoutFailingBatch()throws Exception {
        create().regenerateAutomaticNow(id);assertEquals(0,calls.get());assertEquals("语音想法",store.get(id).title);
    }
    public void testManualEditDuringReorganizationIsProtected()throws Exception {
        store.addCandidate(id,"cloud","录音内容");create((p,t,m)->{store.update(id,"整理期间手动改名",p.effective());return new TitleGeneration.Generated("模型标题",m);}).regenerateAutomaticNow(id);
        assertEquals("整理期间手动改名",store.get(id).title);assertEquals(1,store.get(id).titleEdited);
    }
    public void testTitleCleaningPreservesUnicodeAndIosLengthRules() {
        assertEquals("语音模型迁移",TitleGeneration.clean("标题：\"语音模型迁移。\"","zh-CN"));
        String text="这是一个很长很长很长很长很长很长的中文主题标题",cleaned=TitleGeneration.clean(text,"zh-CN");assertEquals(20,cleaned.codePointCount(0,cleaned.length()));
        assertEquals("one two three four five six seven eight",TitleGeneration.clean("one two three four five six seven eight nine","en"));
        String emoji=TitleGeneration.excerpt("😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀");assertEquals(20,emoji.codePointCount(0,emoji.length()));
    }
    public void testLegacyMigrationProtectsCustomTitlesAndAllowsPlaceholderRepair()throws Exception {
        String name="title-v5-"+UUID.randomUUID()+".db",sql;
        try(Cursor c=store.getReadableDatabase().rawQuery("SELECT sql FROM sqlite_master WHERE name='points'",null)){assertTrue(c.moveToFirst());sql=c.getString(0);}
        sql=sql.replaceAll(",\\s*title_edited INTEGER NOT NULL DEFAULT 0","").replaceAll(",\\s*title_version INTEGER NOT NULL DEFAULT 0","").replaceAll(",\\s*title_source TEXT NOT NULL DEFAULT ''","").replaceAll(",\\s*title_model TEXT NOT NULL DEFAULT ''","");
        try(SQLiteDatabase old=SQLiteDatabase.openOrCreateDatabase(getInstrumentation().getTargetContext().getDatabasePath(name),null)){
            old.execSQL(sql);old.execSQL("CREATE TABLE images(id TEXT PRIMARY KEY,point_id TEXT,caption TEXT)");old.execSQL("INSERT INTO points(id,title,body,created) VALUES('custom','手工旧标题','原文',1),('placeholder','语音想法','',2)");old.setVersion(5);
        }
        PointStore upgraded=new PointStore(getInstrumentation().getTargetContext(),name);
        try{assertEquals(1,upgraded.get("custom").titleEdited);assertEquals(0,upgraded.get("placeholder").titleEdited);assertEquals("手工旧标题",upgraded.get("custom").title);}
        finally{upgraded.close();getInstrumentation().getTargetContext().deleteDatabase(name);remove(upgraded.audio.getParentFile());}
    }
}
