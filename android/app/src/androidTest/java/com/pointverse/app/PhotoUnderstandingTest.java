package com.pointverse.app;

import android.content.ContentValues;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.test.InstrumentationTestCase;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

@SuppressWarnings("deprecation")
public final class PhotoUnderstandingTest extends InstrumentationTestCase {
    private PointStore store;private String database,point,image;private File file;private byte[] original;private PhotoUnderstanding service;
    private final AtomicInteger ocrCalls=new AtomicInteger(),visionCalls=new AtomicInteger();
    private static final class Policy implements PhotoUnderstanding.Policy {
        boolean allowed=true;String token="test-token";
        public boolean allowed(){return allowed;}public String token(){return token;}public String model(){return "pointverse-cloud-enhanced";}
    }
    private Policy policy;
    @Override protected void setUp()throws Exception {
        super.setUp();database="photos-test-"+UUID.randomUUID()+".db";store=new PointStore(getInstrumentation().getTargetContext(),database);
        point=store.createText("关于这个画面","原始想法保持不变");Bitmap bitmap=Bitmap.createBitmap(160,100,Bitmap.Config.ARGB_8888);bitmap.eraseColor(0xffeeeeee);
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();bitmap.compress(Bitmap.CompressFormat.JPEG,95,bytes);bitmap.recycle();original=bytes.toByteArray();
        file=store.addImage(point,original,"录音相机");image=store.rows("images",point).getJSONObject(0).getString("id");policy=new Policy();
    }
    private PhotoUnderstanding create(PhotoUnderstanding.Ocr ocr,PhotoUnderstanding.Vision vision){service=new PhotoUnderstanding(store,policy,ocr,vision);return service;}
    private PhotoUnderstanding create(){return create((f,l,t,m)->{ocrCalls.incrementAndGet();assertEquals("test-token",t);return new PhotoUnderstanding.Description("发票总额 42 元","cloud-ocr");},(f,l,t,m)->{
        visionCalls.incrementAndGet();assertEquals("test-token",t);assertEquals("pointverse-cloud-enhanced",m);return new PhotoUnderstanding.Description("桌上放着一张发票","actual-vision-model");});}
    private JSONObject row(){return store.image(image);}
    @Override protected void tearDown()throws Exception {if(service!=null)service.shutdownForTest();store.close();getInstrumentation().getTargetContext().deleteDatabase(database);remove(store.audio.getParentFile());super.tearDown();}
    private void remove(File f){File[] children=f.listFiles();if(children!=null)for(File child:children)remove(child);f.delete();}
    public void testPhotoWithoutRecognizedTextKeepsOriginalContext(){assertEquals("原始想法保持不变",store.get(point).context());}
    public void testCloudTextAndVisionAreSavedInContext()throws Exception {
        store.field(point,"embedding","[1,0]");int revision=store.get(point).revision;create().process(image,false,false);
        assertEquals("complete",row().getString("analysis_state"));assertEquals("cloud-ocr",row().getString("ocr_model"));assertEquals("actual-vision-model",row().getString("visual_model"));
        assertTrue(row().getString("caption").contains("桌上"));assertTrue(row().getString("caption").contains("42 元"));
        PointStore.Point p=store.get(point);assertEquals("原始想法保持不变",p.effective());assertTrue(p.context().contains("桌上"));assertEquals(1,store.list("42 元").size());assertEquals("",p.embedding);assertTrue(p.revision>revision);
        assertTrue(Arrays.equals(original,Files.readAllBytes(file.toPath())));service.process(image,false,false);assertEquals(1,visionCalls.get());assertEquals(1,ocrCalls.get());
    }
    public void testPrivacyAndLoginBlockBothOcrAndVision()throws Exception {
        policy.allowed=false;create().process(image,false,false);assertEquals("waiting_cloud",row().getString("analysis_state"));assertEquals(0,ocrCalls.get());assertEquals(0,visionCalls.get());assertEquals("",row().getString("caption"));
        policy.allowed=true;policy.token="";service.process(image,false,false);assertEquals(0,ocrCalls.get());assertEquals(0,visionCalls.get());
        policy.token="test-token";service.process(image,false,false);assertEquals(1,ocrCalls.get());assertEquals(1,visionCalls.get());assertEquals("complete",row().getString("analysis_state"));
    }
    public void testVisionFailureKeepsCloudTextAndRetryReusesIt()throws Exception {
        create((f,l,t,m)->{ocrCalls.incrementAndGet();return new PhotoUnderstanding.Description("云端识别的文字",m);},(f,l,t,m)->{
            if(visionCalls.incrementAndGet()==1)throw new IOException("连接中断");return new PhotoUnderstanding.Description("一只杯子",m);
        }).process(image,false,false);
        assertEquals("failed",row().getString("analysis_state"));assertEquals("云端识别的文字",row().getString("caption"));assertTrue(file.isFile());
        service.process(image,false,false);assertEquals(1,visionCalls.get());service.process(image,true,false);assertEquals(2,visionCalls.get());assertEquals(1,ocrCalls.get());
    }
    public void testOcrFailureStillAllowsVisionAndCanRetryTextOnly()throws Exception {
        create((f,l,t,m)->{if(ocrCalls.incrementAndGet()==1)throw new IOException("识字服务暂不可用");return new PhotoUnderstanding.Description("补全的文字",m);},(f,l,t,m)->{visionCalls.incrementAndGet();return new PhotoUnderstanding.Description("一张纸",m);}).process(image,false,false);
        assertEquals("partial",row().getString("analysis_state"));assertTrue(row().getString("caption").contains("一张纸"));assertTrue(row().getString("analysis_error").contains("云端"));
        service.process(image,true,true);assertEquals("complete",row().getString("analysis_state"));assertEquals(1,visionCalls.get());assertEquals(2,ocrCalls.get());assertTrue(row().getString("caption").contains("补全的文字"));
    }
    public void testManualEditsDuringRequestAreNeverOverwritten()throws Exception {
        create((f,l,t,m)->new PhotoUnderstanding.Description("图片文字",m),(f,l,t,m)->{store.imageCaption(image,"我确认的图片说明");return new PhotoUnderstanding.Description("模型候选说明",m);}).process(image,false,false);
        assertEquals("我确认的图片说明",row().getString("caption"));assertEquals("模型候选说明",row().getString("visual_text"));assertFalse(store.get(point).context().contains("模型候选说明"));
    }
    public void testLogoutDuringOcrPreventsNextVisionRequest()throws Exception {
        create((f,l,t,m)->{policy.token="";return new PhotoUnderstanding.Description("已完成的云端文字",m);},(f,l,t,m)->{visionCalls.incrementAndGet();return new PhotoUnderstanding.Description("不可发送",m);}).process(image,false,false);
        assertEquals(0,visionCalls.get());assertEquals("waiting_cloud",row().getString("analysis_state"));assertEquals("已完成的云端文字",row().getString("caption"));
    }
    public void testCrashRecoveryReusesSavedCloudOcr()throws Exception {
        ContentValues values=new ContentValues();values.put("ocr_text","已识别的云端文字");values.put("ocr_model","cloud-ocr");values.put("ocr_done",1);values.put("analysis_state","vision_running");store.imageAnalysis(image,values);
        store.recoverPhotoAnalysis();create().process(image,false,false);assertEquals(0,ocrCalls.get());assertEquals(1,visionCalls.get());assertTrue(row().getString("caption").contains("已识别的云端文字"));
    }
    public void testQueuedPhotosAnalyzeEveryRetainedFrame()throws Exception {
        for(int i=0;i<4;i++)store.addImage(point,original,"录音相机");java.util.concurrent.CountDownLatch complete=new java.util.concurrent.CountDownLatch(1);
        create().addListener(id->{JSONArray images=store.rows("images",id);int finished=0;for(int i=0;i<images.length();i++)if("complete".equals(images.optJSONObject(i).optString("analysis_state")))finished++;if(finished==5)complete.countDown();});
        service.enqueuePoint(point,false);assertTrue(complete.await(10,java.util.concurrent.TimeUnit.SECONDS));assertEquals(5,ocrCalls.get());assertEquals(5,visionCalls.get());
    }
    public void testTextOnlyDoesNotCallVision()throws Exception {
        create().process(image,true,true);assertEquals("text_complete",row().getString("analysis_state"));assertEquals(1,ocrCalls.get());assertEquals(0,visionCalls.get());
    }
    public void testDeletionDuringRequestDoesNotResurrectPhoto()throws Exception {
        create((f,l,t,m)->new PhotoUnderstanding.Description("文字",m),(f,l,t,m)->{store.trash(point,true);store.purge(point);return new PhotoUnderstanding.Description("迟到的回复",m);}).process(image,false,false);
        assertNull(row());assertFalse(file.exists());assertTrue(store.list("").isEmpty());
    }
    public void testOcrRequestUsesCloudImageRouteAndVerbatimPrompt()throws Exception {
        JSONObject ocr=PhotoUnderstanding.ocrPayload(file,"zh-CN","pointverse-cloud-enhanced"),vision=PhotoUnderstanding.visionPayload(file,"zh-CN","pointverse-cloud-enhanced");
        assertEquals("pointverse-cloud-enhanced",ocr.getString("model"));assertEquals(512,ocr.getInt("max_tokens"));assertEquals(256,vision.getInt("max_tokens"));
        JSONArray parts=ocr.getJSONArray("messages").getJSONObject(0).getJSONArray("content");String instruction=parts.getJSONObject(0).getString("text");assertTrue(instruction.contains("Do not translate"));assertTrue(instruction.contains("[NO_TEXT]"));
        String url=parts.getJSONObject(1).getJSONObject("image_url").getString("url");assertTrue(url.startsWith("data:image/jpeg;base64,"));byte[] jpeg=android.util.Base64.decode(url.substring(url.indexOf(',')+1),android.util.Base64.NO_WRAP);
        Bitmap bitmap=BitmapFactory.decodeByteArray(jpeg,0,jpeg.length);assertNotNull(bitmap);assertTrue(Math.max(bitmap.getWidth(),bitmap.getHeight())<=1024);bitmap.recycle();assertTrue(jpeg.length<=500000);assertTrue(Arrays.equals(original,Files.readAllBytes(file.toPath())));
    }
    public void testNoTextAndTruncatedCloudOcrAreHandledExplicitly()throws Exception {
        JSONObject empty=new JSONObject().put("choices",new JSONArray().put(new JSONObject().put("finish_reason","stop").put("message",new JSONObject().put("content","[NO_TEXT]"))));
        assertEquals("",PhotoUnderstanding.response(empty,"cloud-ocr",true).text);
        JSONObject truncated=new JSONObject().put("choices",new JSONArray().put(new JSONObject().put("finish_reason","length").put("message",new JSONObject().put("content","不完整文字"))));
        try{PhotoUnderstanding.response(truncated,"cloud-ocr",true);fail("不能悄悄保存截断的识字结果");}catch(IOException expected){assertTrue(expected.getMessage().contains("裁剪"));}
    }
    public void testOldLocalOcrIsPreservedUntilCloudReplacementSucceeds()throws Exception {
        String name="photos-v4-"+UUID.randomUUID()+".db",pointsSql,imagesSql;
        try(Cursor c=store.getReadableDatabase().rawQuery("SELECT sql FROM sqlite_master WHERE name='points'",null)){assertTrue(c.moveToFirst());pointsSql=c.getString(0).replaceAll(",\\s*title_edited INTEGER NOT NULL DEFAULT 0","").replaceAll(",\\s*title_version INTEGER NOT NULL DEFAULT 0","").replaceAll(",\\s*title_source TEXT NOT NULL DEFAULT ''","").replaceAll(",\\s*title_model TEXT NOT NULL DEFAULT ''","");}
        try(Cursor c=store.getReadableDatabase().rawQuery("SELECT sql FROM sqlite_master WHERE name='images'",null)){assertTrue(c.moveToFirst());imagesSql=c.getString(0).replaceAll(",\\s*ocr_model TEXT NOT NULL DEFAULT ''","");}
        assertFalse(imagesSql.contains("ocr_model"));
        try(SQLiteDatabase old=SQLiteDatabase.openOrCreateDatabase(getInstrumentation().getTargetContext().getDatabasePath(name),null)){
            old.execSQL(pointsSql);old.execSQL(imagesSql);old.execSQL("INSERT INTO points(id,title,body,created) VALUES('point','旧想法','原文',1)");
            old.execSQL("INSERT INTO images(id,point_id,path,caption,created,ocr_text,ocr_done,visual_text,analysis_state) VALUES('old','point','old.jpg','旧的本机识字',1,'旧的本机识字',1,'原有云端视觉','complete')");old.setVersion(4);
        }
        PointStore upgraded=new PointStore(getInstrumentation().getTargetContext(),name);PhotoUnderstanding processor=null;
        try {
            assertEquals("旧的本机识字",upgraded.image("old").getString("caption"));assertEquals(0,upgraded.image("old").getInt("ocr_done"));assertEquals("pending",upgraded.image("old").getString("analysis_state"));
            processor=new PhotoUnderstanding(upgraded,policy,(f,l,t,m)->new PhotoUnderstanding.Description("新的云端文字",m),(f,l,t,m)->{fail("无需重做已有云端视觉");return null;});processor.process("old",false,false);
            assertTrue(upgraded.image("old").getString("caption").contains("新的云端文字"));assertFalse(upgraded.image("old").getString("caption").contains("旧的本机识字"));assertEquals("原有云端视觉",upgraded.image("old").getString("visual_text"));
        }finally{if(processor!=null)processor.shutdownForTest();upgraded.close();getInstrumentation().getTargetContext().deleteDatabase(name);remove(upgraded.audio.getParentFile());}
    }
    public void testLateEmbeddingCannotOverwriteChangedImageContext()throws Exception {
        int revision=store.get(point).revision;create().process(image,false,false);store.saveEmbedding(point,revision,"[1,0]");assertEquals("",store.get(point).embedding);
    }
    public void testInstalledApkContainsNoLocalOcrRuntimeOrModels()throws Exception {
        try(java.util.zip.ZipFile zip=new java.util.zip.ZipFile(getInstrumentation().getTargetContext().getApplicationInfo().sourceDir)){
            java.util.Enumeration<? extends java.util.zip.ZipEntry> entries=zip.entries();while(entries.hasMoreElements()){String name=entries.nextElement().getName();assertFalse(name,name.contains("tessdata/")||name.endsWith("libtesseract.so")||name.endsWith("libleptonica.so"));}
        }
    }
}
