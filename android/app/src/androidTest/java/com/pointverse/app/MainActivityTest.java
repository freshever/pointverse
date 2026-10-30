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
        super.setUp();getInstrumentation().getTargetContext().getSharedPreferences("pointverse",0).edit().putBoolean("testMode",false).putBoolean("configured",true).putBoolean("cloud",false).putBoolean("autoTranscribe",false).putBoolean("captureCamera",false).putString("captureInputMode","voice").putInt("appLanguage",1).commit();
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

    private UniverseCanvas universeCanvas()throws Exception {return ui(()->{java.lang.reflect.Field field=MainActivity.class.getDeclaredField("activeUniverseCanvas");field.setAccessible(true);return (UniverseCanvas)field.get(activity);});}
    private void waitUniverseLayout()throws Exception {waitForText("全景");long end=System.currentTimeMillis()+5000;while(System.currentTimeMillis()<end){UniverseCanvas c=universeCanvas();if(c!=null&&ui(()->c.getWidth()>0))return;Thread.sleep(50);}fail("宇宙没有完成布局");}
    private void waitCamera()throws Exception {Thread.sleep(1800);getInstrumentation().waitForIdleSync();}
    public void testUniverseSearchDetailReturnPreservesCamera()throws Exception {
        PointStore store=new PointStore(getInstrumentation().getTargetContext());String id=store.createText("宇宙往返交互验收","宇宙回指的原文");store.field(id,"domain","交互验收领域");store.field(id,"topic","回指测试");
        try{activity=launch();waitReady();tapAccessible("宇宙");waitUniverseLayout();UniverseCanvas canvas=universeCanvas();ui(()->{canvas.focus(id);return null;});waitCamera();double[] before=ui(()->new double[]{canvas.state.cameraX,canvas.state.cameraY,canvas.state.distance});UniverseScene.State state=canvas.state;
            ui(()->{java.lang.reflect.Method open=MainActivity.class.getDeclaredMethod("open",String.class);open.setAccessible(true);open.invoke(activity,id);return null;});waitForText("宇宙回指的原文");click("‹ 返回");waitUniverseLayout();UniverseCanvas restored=universeCanvas();assertSame(state,restored.state);assertEquals(before[0],restored.state.cameraX,.001);assertEquals(before[1],restored.state.cameraY,.001);assertEquals(before[2],restored.state.distance,.001);assertEquals(id,restored.state.focused);screenshot("universe-focused-return");
        }finally{if(activity!=null)ui(()->{activity.finish();return null;});store.trash(id,true);store.purge(id);store.close();}
    }
    public void testUniverseDirectoryOpensMatchingIdeaWithoutChangingClassification()throws Exception {
        PointStore store=new PointStore(getInstrumentation().getTargetContext());String id=store.createText("目录直达交互验收","目录中的原文");store.field(id,"domain","目录领域");store.field(id,"topic","目录主题");
        try{activity=launch();waitReady();tapAccessible("宇宙");waitUniverseLayout();UniverseCanvas canvas=universeCanvas();ui(()->{canvas.showNavigator();return null;});
            ui(()->{java.lang.reflect.Field field=UniverseCanvas.class.getDeclaredField("dialogs");field.setAccessible(true);java.util.List<?> dialogs=(java.util.List<?>)field.get(canvas);Dialog d=(Dialog)dialogs.get(dialogs.size()-1);java.util.ArrayDeque<View> queue=new java.util.ArrayDeque<>();queue.add(d.getWindow().getDecorView());while(!queue.isEmpty()){View v=queue.remove();if(v instanceof EditText){((EditText)v).setText("目录直达交互验收");break;}if(v instanceof ViewGroup)for(int n=0;n<((ViewGroup)v).getChildCount();n++)queue.add(((ViewGroup)v).getChildAt(n));}View button=find(d.getWindow().getDecorView(),"想法 · 目录直达交互验收");assertNotNull(button);button.performClick();return null;});waitForText("目录中的原文");assertEquals("目录领域",store.get(id).domain);assertEquals("目录主题",store.get(id).topic);click("‹ 返回");waitUniverseLayout();click("脑图");waitUniverseLayout();UniverseCanvas mind=universeCanvas();assertTrue(mind.mind);ui(()->{mind.focus(id);return null;});getInstrumentation().waitForIdleSync();assertTrue(mind.state.expanded.contains("planet:目录领域"));Thread.sleep(200);getInstrumentation().waitForIdleSync();screenshot("universe-mindmap");
        }finally{if(activity!=null)ui(()->{activity.finish();return null;});store.trash(id,true);store.purge(id);store.close();}
    }

    private MainActivity recreated(Runnable action)throws Exception {android.app.Instrumentation.ActivityMonitor monitor=getInstrumentation().addMonitor(MainActivity.class.getName(),null,false);try{ui(()->{action.run();return null;});Activity next=getInstrumentation().waitForMonitorWithTimeout(monitor,8000);assertNotNull("模式切换后应重新创建界面",next);return (MainActivity)next;}finally{getInstrumentation().removeMonitor(monitor);}}
    public void testIndependentTestModeCanAddClearAndExitWithoutChangingFormalData()throws Exception {
        PointStore formal=new PointStore(getInstrumentation().getTargetContext());String id=formal.createText("正式库隔离验收","正式内容完整保留");PointStore test=null;String savedPrompt=getInstrumentation().getTargetContext().getSharedPreferences("pointverse",0).getString("imagePrompt","");getInstrumentation().getTargetContext().getSharedPreferences("pointverse",0).edit().putString("imagePrompt","正式库专用草稿").commit();
        try{activity=launch();waitReady();int before=DemoData.count(formal);tapAccessible("宇宙");waitUniverseLayout();activity=recreated(()->{View v=find(activity.getWindow().getDecorView(),"测试");assertNotNull(v);v.performClick();});waitForText("球面样本");test=new PointStore(getInstrumentation().getTargetContext(),DemoData.DATABASE);new DemoData(getInstrumentation().getTargetContext(),test).clear();click("+100");long until=System.currentTimeMillis()+10000;while(System.currentTimeMillis()<until&&DemoData.count(test)<100)Thread.sleep(100);assertEquals(100,DemoData.count(test));assertEquals(before,DemoData.count(formal));assertEquals("正式内容完整保留",formal.get(id).body);tapAccessible("图片");waitForText("生成图片");assertNull(ui(()->find(activity.getWindow().getDecorView(),"正式库专用草稿")));tapAccessible("宇宙");waitUniverseLayout();Thread.sleep(2300);screenshot("universe-test-mode");activity=recreated(()->{View v=find(activity.getWindow().getDecorView(),"退出");assertNotNull(v);v.performClick();});waitUniverseLayout();assertFalse(getInstrumentation().getTargetContext().getSharedPreferences("pointverse",0).getBoolean("testMode",true));assertEquals("正式内容完整保留",formal.get(id).body);assertEquals(100,DemoData.count(test));
        }finally{getInstrumentation().getTargetContext().getSharedPreferences("pointverse",0).edit().putBoolean("testMode",false).putString("imagePrompt",savedPrompt).remove("switchTestPage").commit();if(test!=null){new DemoData(getInstrumentation().getTargetContext(),test).clear();test.close();}if(activity!=null)ui(()->{activity.finish();return null;});formal.trash(id,true);formal.purge(id);formal.close();}
    }

}
