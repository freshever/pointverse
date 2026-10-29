package com.pointverse.app;

import android.app.*;
import android.content.*;
import android.test.InstrumentationTestCase;
import android.view.*;
import android.widget.*;
import java.util.concurrent.Callable;
import java.util.concurrent.FutureTask;

@SuppressWarnings("deprecation")
public final class MainActivityTest extends InstrumentationTestCase {
    private MainActivity activity;
    private <T> T ui(Callable<T> action) throws Exception {
        FutureTask<T> task=new FutureTask<>(action); getInstrumentation().runOnMainSync(task); return task.get();
    }
    private MainActivity launch() {
        Intent intent=new Intent(getInstrumentation().getTargetContext(),MainActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TASK);
        return (MainActivity)getInstrumentation().startActivitySync(intent);
    }
    private View find(View view,String text) {
        if(view instanceof TextView && text.contentEquals(((TextView)view).getText())) return view;
        if(view instanceof ViewGroup) for(int i=0;i<((ViewGroup)view).getChildCount();i++) {
            View found=find(((ViewGroup)view).getChildAt(i),text); if(found!=null) return found;
        }
        return null;
    }
    private void click(String title) throws Exception {
        ui(()-> { View view=find(activity.getWindow().getDecorView(),title); assertNotNull(title,view); assertTrue(view.isEnabled()); view.performClick(); return null; });
    }
    private void waitForText(String title) throws Exception {
        long deadline=System.currentTimeMillis()+10000;
        while(System.currentTimeMillis()<deadline) {
            if(ui(()->find(activity.getWindow().getDecorView(),title)!=null)) return;
            Thread.sleep(100);
        }
        fail("未显示："+title);
    }
    @Override protected void setUp() throws Exception {
        super.setUp();getInstrumentation().getTargetContext().getSharedPreferences("pointverse",0).edit().putBoolean("configured",true).putBoolean("cloud",false).putBoolean("autoTranscribe",false).putBoolean("captureCamera",false).putString("captureInputMode","voice").putInt("appLanguage",1).commit();
    }
    private View accessible(View view,String description) {
        if(view.getContentDescription()!=null&&description.contentEquals(view.getContentDescription()))return view;
        if(view instanceof ViewGroup)for(int i=0;i<((ViewGroup)view).getChildCount();i++){View result=accessible(((ViewGroup)view).getChildAt(i),description);if(result!=null)return result;}return null;
    }
    private void tapAccessible(String text) throws Exception {ui(()->{View found=accessible(activity.getWindow().getDecorView(),text);assertNotNull(text,found);found.performClick();return null;});}
    private void waitReady() throws Exception {long until=System.currentTimeMillis()+10000;while(System.currentTimeMillis()<until){if(ui(()->{View v=accessible(activity.getWindow().getDecorView(),"开始录音");return v!=null&&v.isEnabled();}))return;Thread.sleep(100);}fail("录音界面未就绪");}
    public void testRecordingSavesAndReopens() throws Exception {
        activity=launch();waitReady();tapAccessible("开始录音");Thread.sleep(1600);tapAccessible("完成录音");waitForText("原音");
        PointStore db=new PointStore(getInstrumentation().getTargetContext());PointStore.Point point=db.list("").get(0);assertNotNull(point.path);assertTrue(db.audioFile(point).isFile());assertTrue(point.duration>0);db.close();
        ui(()->{activity.finish();return null;});getInstrumentation().waitForIdleSync();activity=launch();waitReady();tapAccessible("想法");waitForText("全部想法");waitForText("语音想法");ui(()->{activity.finish();return null;});
    }
    public void testHoldToRecordEndsOnRelease() throws Exception {
        activity=launch();waitReady();final View[] held={null};long time=android.os.SystemClock.uptimeMillis();
        ui(()->{held[0]=accessible(activity.getWindow().getDecorView(),"开始录音");held[0].dispatchTouchEvent(android.view.MotionEvent.obtain(time,time,android.view.MotionEvent.ACTION_DOWN,20,20,0));return null;});
        Thread.sleep(1600);assertNotNull(ui(()->accessible(activity.getWindow().getDecorView(),"完成录音")));
        ui(()->{held[0].dispatchTouchEvent(android.view.MotionEvent.obtain(time,android.os.SystemClock.uptimeMillis(),android.view.MotionEvent.ACTION_UP,20,20,0));return null;});waitForText("原音");ui(()->{activity.finish();return null;});
    }
    public void testFiveTabsRenderWithoutPlaceholderPages() throws Exception {
        activity=launch();waitReady();
        tapAccessible("我的");waitForText("语音转写");waitForText("点界账户");
        tapAccessible("图片");waitForText("生成图片");
        tapAccessible("宇宙");waitForText("脑图");waitForText("分类");
        tapAccessible("想法");waitForText("全部想法");
        tapAccessible("记录");waitForText("语音");waitForText("文本");ui(()->{activity.finish();return null;});
    }
    private void screenshot(String name)throws Exception{
        getInstrumentation().waitForIdleSync();android.graphics.Bitmap image=getInstrumentation().getUiAutomation().takeScreenshot();
        if(image!=null)try(java.io.FileOutputStream out=new java.io.FileOutputStream(new java.io.File(getInstrumentation().getTargetContext().getFilesDir(),"qa-"+name+".png"))){image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);image.recycle();}
    }
    public void testBlackCaptureAndControlStates() throws Exception{
        activity=launch();waitReady();waitForText("留下此刻的想法");screenshot("capture-idle");
        tapAccessible("开始录音");waitForText("正在录音");Thread.sleep(400);screenshot("capture-recording");
        Thread.sleep(1000);tapAccessible("完成录音");waitForText("原音");ui(()->{activity.finish();return null;});
    }
    public void testPhotoDetailsShowUnderstandingWithoutReplacingManualNotes() throws Exception {
        PointStore store=new PointStore(getInstrumentation().getTargetContext());String id=store.createText("图片理解界面验收","原始想法");
        try {
            android.graphics.Bitmap bitmap=android.graphics.Bitmap.createBitmap(160,100,android.graphics.Bitmap.Config.ARGB_8888);bitmap.eraseColor(0xffcccccc);
            java.io.ByteArrayOutputStream bytes=new java.io.ByteArrayOutputStream();bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG,90,bytes);bitmap.recycle();
            store.addImage(id,bytes.toByteArray(),"用户照片");String image=store.rows("images",id).getJSONObject(0).getString("id");
            ContentValues values=new ContentValues();values.put("visual_text","桌上有一只杯子");values.put("ocr_text","HELLO");values.put("ocr_model","ocr-test");values.put("ocr_done",1);values.put("visual_model","vision-test");values.put("analysis_state","complete");store.imageAnalysis(image,values);
            store.imageCaption(image,"我确认的说明");
            activity=launch();waitReady();tapAccessible("想法");waitForText("图片理解界面验收");
            ui(()->{View v=find(activity.getWindow().getDecorView(),"图片理解界面验收");while(v!=null&&!v.isClickable())v=v.getParent() instanceof View?(View)v.getParent():null;assertNotNull(v);v.performClick();return null;});
            waitForText("我的图片说明：\n我确认的说明");waitForText("最新图片理解：\n桌上有一只杯子\n\n云端识别文字：\nHELLO");
            assertEquals("我确认的说明",store.image(image).getString("caption"));
        } finally {
            if(activity!=null)ui(()->{activity.finish();return null;});store.trash(id,true);store.purge(id);store.close();
        }
    }
    public void testNetworkContractValidation() throws Exception {
        assertEquals("https://example.com/v1/ai/chat/completions",NetworkModel.endpoint("https://example.com/v1/ai/").toString());
        for(String invalid:new String[]{"http://example.com/v1","https://user:secret@example.com/v1","https://example.com/v1?key=abc"}) {
            try { NetworkModel.endpoint(invalid); fail("接受了不合法地址"); } catch(java.io.IOException expected) { }
        }
        assertEquals("整理结果",NetworkModel.responseText(new org.json.JSONObject("{\"choices\":[{\"message\":{\"content\":\"整理结果\"}}]}")));
    }
    private void chooseDialogItem(String text)throws Exception {
        long until=System.currentTimeMillis()+10000;
        while(System.currentTimeMillis()<until){boolean selected=ui(()->{java.lang.reflect.Field field=MainActivity.class.getDeclaredField("dialogs");field.setAccessible(true);java.util.List<?> dialogs=(java.util.List<?>)field.get(activity);for(int n=dialogs.size()-1;n>=0;n--){Dialog d=(Dialog)dialogs.get(n);if(!d.isShowing()||!(d instanceof AlertDialog))continue;ListView list=((AlertDialog)d).getListView();if(list==null)continue;for(int i=0;i<list.getAdapter().getCount();i++)if(text.equals(list.getAdapter().getItem(i).toString())){list.performItemClick(list.getAdapter().getView(i,null,list),i,i);return true;}}return false;});if(selected)return;Thread.sleep(100);}fail("未显示菜单项："+text);
    }
    public void testSpeakerAndVoiceFiltersCombineAndClear()throws Exception {
        PointStore store=new PointStore(getInstrumentation().getTargetContext());String a=store.createText("组合筛选平静条目","正文"),b=store.createText("组合筛选激动条目","正文");
        try{store.field(a,"speaker","筛选测试说话人");store.field(b,"speaker","筛选测试说话人");store.field(a,"voice","平静");store.field(b,"voice","激动");activity=launch();waitReady();tapAccessible("想法");waitForText("组合筛选平静条目");click("筛选");chooseDialogItem("说话人");chooseDialogItem("筛选测试说话人");waitForText("清除筛选");waitForText("组合筛选激动条目");click("筛选");chooseDialogItem("声音状态");chooseDialogItem("平静");waitForText("当前筛选：筛选测试说话人 平静");waitForText("组合筛选平静条目");assertNull(ui(()->find(activity.getWindow().getDecorView(),"组合筛选激动条目")));click("清除筛选");waitForText("组合筛选激动条目");}
        finally{if(activity!=null)ui(()->{activity.finish();return null;});for(String id:new String[]{a,b}){store.trash(id,true);store.purge(id);}store.close();}
    }

}
