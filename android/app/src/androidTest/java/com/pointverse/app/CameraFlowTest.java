package com.pointverse.app;

import android.content.Context;
import android.content.Intent;
import android.graphics.BitmapFactory;
import android.os.ParcelFileDescriptor;
import android.test.InstrumentationTestCase;
import android.util.Size;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.Switch;
import android.widget.TextView;
import java.io.File;
import java.io.FileInputStream;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.FutureTask;

@SuppressWarnings("deprecation")
public final class CameraFlowTest extends InstrumentationTestCase {
    private MainActivity activity;
    private <T> T ui(Callable<T> action) throws Exception {
        FutureTask<T> task=new FutureTask<>(action);getInstrumentation().runOnMainSync(task);return task.get();
    }
    private View find(View view,String text) {
        if(text.equals(view.getContentDescription()) || view instanceof TextView && text.contentEquals(((TextView)view).getText())) return view;
        if(view instanceof ViewGroup) for(int i=0;i<((ViewGroup)view).getChildCount();i++){
            View found=find(((ViewGroup)view).getChildAt(i),text);if(found!=null)return found;
        }
        return null;
    }
    private void waitText(String text) throws Exception {
        long until=System.currentTimeMillis()+20000;
        while(System.currentTimeMillis()<until){if(ui(()->find(activity.getWindow().getDecorView(),text)!=null))return;Thread.sleep(100);}
        fail("相机流程未显示："+text);
    }
    private void tap(String text)throws Exception{ui(()->{View v=find(activity.getWindow().getDecorView(),text);assertNotNull(text,v);assertTrue(v.isEnabled());v.performClick();return null;});}
    private void grant(String permission)throws Exception{
        try(ParcelFileDescriptor result=getInstrumentation().getUiAutomation().executeShellCommand("pm grant com.pointverse.app "+permission);FileInputStream in=new FileInputStream(result.getFileDescriptor())){byte[] bytes=new byte[1024];while(in.read(bytes)!=-1){}}
    }
    public void testUsesDeviceReportedFourThreeSizes() {
        Size[] jpeg={new Size(4000,3000),new Size(1024,768),new Size(640,480)};
        Size photo=CaptureCamera.chooseJpeg(jpeg);assertEquals(new Size(1024,768),photo);
        Size preview=CaptureCamera.choosePreview(new Size[]{new Size(1920,1080),new Size(640,480)},photo);
        assertEquals(new Size(640,480),preview);
        assertEquals(new Size(640,480),CaptureCamera.chooseJpeg(new Size[]{new Size(640,480)}));
    }
    public void testSamplingMatchesIosIntervalAndEvenReviewSelection() {
        assertEquals(1200L,CaptureCamera.SAMPLE_INTERVAL_MS);assertEquals(12,CaptureCamera.MAX_CAPTURED_FRAMES);
        java.util.List<Integer> frames=new java.util.ArrayList<>();for(int i=0;i<12;i++)frames.add(i);
        assertEquals(java.util.Arrays.asList(0,2,5,8,11),CaptureCamera.evenlySelected(frames,5));
        assertEquals(java.util.Arrays.asList(0,1),CaptureCamera.evenlySelected(frames.subList(0,2),5));
        assertTrue(CaptureCamera.evenlySelected(frames,0).isEmpty());
    }
    public void testPreviewDoesNotRotateSensorTwice() {
        android.graphics.Matrix transform=CaptureCamera.previewTransform(1080,1600,new Size(1280,960),90,false,0);
        float[] line={540,800,640,800};transform.mapPoints(line);
        assertEquals("TextureView 已处理传感器方向，不应再次旋转横轴",line[1],line[3],0.01f);
        assertTrue(line[2]>line[0]);
    }
    public void testPhotoOrientationIsRespected()throws Exception{
        File file=new File(getInstrumentation().getTargetContext().getCacheDir(),"test-photo-orientation.jpg");
        android.graphics.Bitmap raw=android.graphics.Bitmap.createBitmap(120,80,android.graphics.Bitmap.Config.ARGB_8888);
        try{
            try(java.io.FileOutputStream output=new java.io.FileOutputStream(file)){raw.compress(android.graphics.Bitmap.CompressFormat.JPEG,95,output);}
            android.media.ExifInterface metadata=new android.media.ExifInterface(file.getAbsolutePath());metadata.setAttribute(android.media.ExifInterface.TAG_ORIENTATION,Integer.toString(android.media.ExifInterface.ORIENTATION_ROTATE_90));metadata.saveAttributes();
            android.graphics.Bitmap upright=PhotoDecoder.fromFile(file,512);assertEquals(80,upright.getWidth());assertEquals(120,upright.getHeight());upright.recycle();
        }finally{raw.recycle();file.delete();}
    }
    public void testCameraOpensWhileRecordingAndSavesRealJpeg()throws Exception{
        Context context=getInstrumentation().getTargetContext();
        grant("android.permission.CAMERA");grant("android.permission.RECORD_AUDIO");
        context.getSharedPreferences("pointverse",0).edit().putBoolean("configured",true).putBoolean("cloud",false).putBoolean("autoTranscribe",false).putBoolean("captureCamera",false).putString("captureInputMode","voice").putInt("appLanguage",1).commit();
        try{
            activity=(MainActivity)getInstrumentation().startActivitySync(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TASK));
            waitText("同时拍摄");Thread.sleep(300);
            ui(()->{((Switch)find(activity.getWindow().getDecorView(),"同时拍摄")).setChecked(true);return null;});
            assertTrue("相机预览必须在启用硬件加速的窗口中",ui(()->find(activity.getWindow().getDecorView(),"相机预览").isHardwareAccelerated()));
            // Start before the camera session is ready; the first preview must trigger a photo.
            tap("开始录音");waitText("相机已就绪");Thread.sleep(5200);
            android.graphics.Bitmap screenshot=getInstrumentation().getUiAutomation().takeScreenshot();
            if(screenshot!=null)try(java.io.FileOutputStream out=new java.io.FileOutputStream(new File(context.getFilesDir(),"qa-camera-recording.png"))){screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);screenshot.recycle();}
            tap("完成录音");
            long until=System.currentTimeMillis()+10000;AccessibilityNodeInfo save=null;
            while(System.currentTimeMillis()<until){AccessibilityNodeInfo root=getInstrumentation().getUiAutomation().getRootInActiveWindow();if(root!=null){List<AccessibilityNodeInfo> matches=root.findAccessibilityNodeInfosByText("保存所选");if(!matches.isEmpty()){save=matches.get(0);break;}}Thread.sleep(100);}
            assertNotNull("不足 8 秒的录音也应能保留真实拍摄画面",save);assertTrue(save.performAction(AccessibilityNodeInfo.ACTION_CLICK));
            PointStore db=new PointStore(context);try{
                org.json.JSONArray images=new org.json.JSONArray();PointStore.Point point=null;until=System.currentTimeMillis()+10000;
                while(System.currentTimeMillis()<until){point=db.list("").get(0);images=db.rows("images",point.id);if(images.length()>=3)break;Thread.sleep(100);}
                assertTrue("约五秒录音应采样多张画面，而不是只保存一张",images.length()>=3);assertTrue("最多保留五张供选择",images.length()<=5);assertNotNull(point.path);assertTrue(db.audioFile(point).isFile());assertTrue(point.duration>0);
                File file=new File(db.imageDirectory(),images.getJSONObject(0).getString("path"));BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;BitmapFactory.decodeFile(file.getAbsolutePath(),bounds);
                assertTrue("应保留实际 JPEG 文件",bounds.outWidth>0&&bounds.outHeight>0);
                until=System.currentTimeMillis()+10000;boolean waiting=false;
                while(System.currentTimeMillis()<until){images=db.rows("images",point.id);waiting=true;for(int i=0;i<images.length();i++)if(!"waiting_cloud".equals(images.optJSONObject(i).optString("analysis_state")))waiting=false;if(waiting)break;Thread.sleep(100);}
                assertTrue("隐私版应保存照片并等待云端登录",waiting);
                for(int i=0;i<images.length();i++){assertEquals("不能再调用本机识字",0,images.getJSONObject(i).getInt("ocr_done"));assertEquals("",images.getJSONObject(i).getString("ocr_text"));}
            }finally{db.close();}
            waitText("原音");
            try(ParcelFileDescriptor result=getInstrumentation().getUiAutomation().executeShellCommand("input keyevent KEYCODE_BACK");FileInputStream input=new FileInputStream(result.getFileDescriptor())){byte[] bytes=new byte[256];while(input.read(bytes)!=-1){}}
            waitText("相机已就绪");
            ui(()->{((Switch)find(activity.getWindow().getDecorView(),"同时拍摄")).setChecked(false);return null;});
            ui(()->{((Switch)find(activity.getWindow().getDecorView(),"同时拍摄")).setChecked(true);return null;});waitText("相机已就绪");
            try(ParcelFileDescriptor result=getInstrumentation().getUiAutomation().executeShellCommand("input keyevent KEYCODE_HOME");FileInputStream input=new FileInputStream(result.getFileDescriptor())){byte[] bytes=new byte[256];while(input.read(bytes)!=-1){}}
            long focusDeadline=System.currentTimeMillis()+5000;while(ui(()->activity.hasWindowFocus())&&System.currentTimeMillis()<focusDeadline)Thread.sleep(50);
            assertFalse("切后台应释放相机",ui(()->activity.hasWindowFocus()));
            context.startActivity(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
            focusDeadline=System.currentTimeMillis()+10000;while(!ui(()->activity.hasWindowFocus())&&System.currentTimeMillis()<focusDeadline)Thread.sleep(50);
            assertTrue(ui(()->activity.hasWindowFocus()));waitText("相机已就绪");
        }finally{
            if(activity!=null)ui(()->{activity.finish();return null;});context.getSharedPreferences("pointverse",0).edit().putBoolean("captureCamera",false).commit();
        }
    }
}
