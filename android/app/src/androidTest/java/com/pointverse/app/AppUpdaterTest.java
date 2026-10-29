package com.pointverse.app;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.test.InstrumentationTestCase;
import android.view.accessibility.AccessibilityNodeInfo;
import org.json.JSONArray;
import org.json.JSONObject;
import javax.net.ssl.HttpsURLConnection;
import java.io.*;
import java.net.URL;
import java.nio.file.Files;
import java.security.cert.Certificate;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

@SuppressWarnings("deprecation")
public final class AppUpdaterTest extends InstrumentationTestCase {
    private Context context;
    private AppUpdater.Release release;
    private JSONObject metadata;
    private byte[] apk;
    private File cached;
    private long installedCode;
    private static final class Connection extends HttpsURLConnection {
        final byte[] bytes;final int status;final long length;
        Connection(URL url,byte[] bytes,int status,long length){super(url);this.bytes=bytes;this.status=status;this.length=length;}
        public int getResponseCode(){return status;}
        public long getContentLengthLong(){return length;}
        public InputStream getInputStream(){return new ByteArrayInputStream(bytes);}
        public void disconnect(){}public boolean usingProxy(){return false;}public void connect(){}
        public String getCipherSuite(){return "test";}public Certificate[] getLocalCertificates(){return null;}public Certificate[] getServerCertificates(){return new Certificate[0];}
    }
    @Override protected void setUp()throws Exception {
        super.setUp();context=getInstrumentation().getTargetContext();
        PackageInfo installed=context.getPackageManager().getPackageInfo(context.getPackageName(),PackageManager.GET_SIGNING_CERTIFICATES);installedCode=installed.getLongVersionCode();
        File fixture=new File(context.getFilesDir(),"test-update.apk");apk=Files.readAllBytes(fixture.toPath());
        metadata=metadata(fixture,installedCode+1,"update-test",AppUpdater.signer(installed));release=new AppUpdater.Release(metadata);cached=new AppUpdater(context).cached(release);cached.delete();
    }
    private JSONObject metadata(File file,long code,String version,String signer)throws Exception {
        return new JSONObject().put("package","com.pointverse.app").put("versionName",version).put("versionCode",code).put("file","pointverse-update-test.apk")
                .put("size",file.length()).put("sha256",AppUpdater.digest(file)).put("signerSha256",signer).put("minSdk",28).put("notes","更新测试，不安装测试包");
    }
    private JSONObject catalog()throws Exception{return new JSONObject().put("schemaVersion",1).put("latest",release.file).put("releases",new JSONArray().put(metadata));}
    private AppUpdater updater(byte[] bytes,int status,long length,AtomicInteger requests) {
        return new AppUpdater(context,url->{assertTrue(url.toString().startsWith(AppUpdater.BASE));requests.incrementAndGet();return new Connection(url,bytes,status,length);});
    }
    @Override protected void tearDown()throws Exception {cached.delete();super.tearDown();}
    private void noParts(){File[] files=AppUpdater.directory(context).listFiles();if(files!=null)for(File file:files)assertFalse("失败或取消后不应留下半包",(file.getName().endsWith(".part")||file.getName().endsWith(".part.apk")));}
    public void testLegacySignatureFieldWorksWhenSigningInfoIsAbsent()throws Exception {
        PackageInfo installed=context.getPackageManager().getPackageInfo(context.getPackageName(),PackageManager.GET_SIGNATURES);
        PackageInfo legacy=new PackageInfo();legacy.signatures=installed.signatures;legacy.signingInfo=null;
        assertNotNull(legacy.signatures);assertEquals(release.signer,AppUpdater.signer(legacy));
    }
    public void testMissingOrMultipleSignaturesAreNotTrusted()throws Exception {
        try{AppUpdater.signer(new PackageInfo());fail("签名缺失时不能跳过校验");}catch(IOException expected){}
        PackageInfo installed=context.getPackageManager().getPackageInfo(context.getPackageName(),PackageManager.GET_SIGNATURES);
        PackageInfo multiple=new PackageInfo();multiple.signatures=new android.content.pm.Signature[]{installed.signatures[0],installed.signatures[0]};
        try{AppUpdater.signer(multiple);fail("不能用单签名兼容分支接受多签名包");}catch(IOException expected){}
    }
    public void testNewerVersionCodeAndCatalogLatestSelection()throws Exception {
        assertEquals(installedCode+1,AppUpdater.latest(catalog(),installedCode).code);
        assertNull(AppUpdater.latest(catalog(),installedCode+1));assertNull(AppUpdater.latest(catalog(),installedCode+2));
        AtomicInteger calls=new AtomicInteger();byte[] data=catalog().toString().getBytes("UTF-8");
        assertEquals(release.sha256,updater(data,200,data.length,calls).check().sha256);assertEquals(1,calls.get());
    }
    public void testRejectsUntrustedPathsPackagesAndManifestFields()throws Exception {
        for(String path:new String[]{"../outside.apk","https://other.example/pointverse.apk","pointverse-../../escape.apk"}) {
            JSONObject bad=new JSONObject(metadata.toString()).put("file",path);try{new AppUpdater.Release(bad);fail(path);}catch(IOException expected){}
        }
        for(JSONObject bad:new JSONObject[]{new JSONObject(metadata.toString()).put("package","other.app"),new JSONObject(metadata.toString()).put("size",AppUpdater.MAX_APK_BYTES+1),new JSONObject(metadata.toString()).put("sha256","bad")}){
            try{new AppUpdater.Release(bad);fail("无效更新信息被接受");}catch(IOException expected){}
        }
        try{AppUpdater.latest(catalog().put("latest","missing.apk"),installedCode);fail();}catch(IOException expected){}
    }
    public void testDownloadsVerifiesAndReusesSignedApk()throws Exception {
        AtomicInteger requests=new AtomicInteger();AppUpdater updater=updater(apk,200,apk.length,requests);long[] progress={0};
        File file=updater.download(release,(received,total)->{assertEquals(apk.length,total);assertTrue(received>=progress[0]);progress[0]=received;});
        assertEquals(cached,file);assertEquals(apk.length,progress[0]);updater.verify(file,release);
        updater.download(release,(received,total)->{});assertEquals("完整校验通过的缓存无需再次下载",1,requests.get());noParts();
    }
    public void testRejectsTruncatedOversizedAndRedirectedResponses()throws Exception {
        for(Connection source:new Connection[]{new Connection(new URL(AppUpdater.BASE),java.util.Arrays.copyOf(apk,apk.length-1),200,-1),
                new Connection(new URL(AppUpdater.BASE),java.util.Arrays.copyOf(apk,apk.length+1),200,-1),new Connection(new URL(AppUpdater.BASE),apk,302,apk.length)}){
            try{new AppUpdater(context,url->source).download(release,(a,b)->{});fail("错误响应不应成为可安装包");}catch(IOException expected){}
            assertFalse(cached.exists());noParts();
        }
    }
    public void testCorruptedCacheIsRedownloaded()throws Exception {
        byte[] bad=apk.clone();bad[bad.length/2]^=1;Files.write(cached.toPath(),bad);AtomicInteger calls=new AtomicInteger();
        updater(apk,200,apk.length,calls).download(release,(a,b)->{});assertEquals(1,calls.get());assertEquals(release.sha256,AppUpdater.digest(cached));
    }
    public void testDifferentSignerAndPackageCannotInstall()throws Exception {
        for(String name:new String[]{"test-update-untrusted.apk","test-update-other-package.apk"}){
            File file=new File(context.getFilesDir(),name);AppUpdater.Release other=new AppUpdater.Release(metadata(file,installedCode+1,"update-test",release.signer));
            try{new AppUpdater(context).verify(file,other);fail("不应接受不同签名或包名");}catch(IOException expected){}
        }
        try{new AppUpdater(context).verify(new File(context.getFilesDir(),"test-update.apk"),new AppUpdater.Release(new JSONObject(metadata.toString()).put("sha256",new String(new char[64]).replace("\0","0"))));fail();}catch(IOException expected){}
    }
    public void testCancelCleansPartialDownload()throws Exception {
        try {
            updater(apk,200,apk.length,new AtomicInteger()).download(release,(received,total)->{if(received>0)Thread.currentThread().interrupt();});fail("取消后不能保留可安装包");
        }catch(InterruptedIOException expected){}finally{Thread.interrupted();}
        assertFalse(cached.exists());noParts();
    }
    public void testReadOnlyProviderAndInstallerIntent()throws Exception {
        new AppUpdater(context).verify(new File(context.getFilesDir(),"test-update.apk"),release);Files.write(cached.toPath(),apk);
        Intent intent=AppUpdater.installIntent(context,cached);Uri uri=intent.getData();assertEquals("content",uri.getScheme());assertEquals("application/vnd.android.package-archive",intent.getType());
        assertTrue((intent.getFlags()&Intent.FLAG_GRANT_READ_URI_PERMISSION)!=0);assertEquals(uri,intent.getClipData().getItemAt(0).getUri());
        try(InputStream input=context.getContentResolver().openInputStream(uri)){assertEquals(apk[0]&255,input.read());}
        try(ParcelFileDescriptor ignored=context.getContentResolver().openFileDescriptor(uri,"w")){fail("安装器不能修改安装包");}catch(FileNotFoundException expected){}
        try(InputStream ignored=context.getContentResolver().openInputStream(Uri.parse("content://com.pointverse.app.updates/apk/../test-update.apk"))){fail("不能读取更新目录以外的文件");}catch(FileNotFoundException expected){}
    }
    private android.view.View find(android.view.View view,String value) {
        if(value.contentEquals(view.getContentDescription()==null?"":view.getContentDescription())||view instanceof android.widget.TextView&&value.contentEquals(((android.widget.TextView)view).getText()))return view;
        if(view instanceof android.view.ViewGroup)for(int i=0;i<((android.view.ViewGroup)view).getChildCount();i++){android.view.View found=find(((android.view.ViewGroup)view).getChildAt(i),value);if(found!=null)return found;}return null;
    }
    public void testUpdateEntryWorksWithoutAccount()throws Exception {
        context.getSharedPreferences("pointverse",0).edit().putBoolean("configured",true).putBoolean("cloud",false).putBoolean("captureCamera",false).commit();
        MainActivity activity=(MainActivity)getInstrumentation().startActivitySync(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TASK));
        android.app.Instrumentation.ActivityMonitor monitor=getInstrumentation().addMonitor(UpdateActivity.class.getName(),null,false);
        UpdateActivity update=null;
        try {
            getInstrumentation().runOnMainSync(()->{android.view.View models=find(activity.getWindow().getDecorView(),"我的");assertNotNull(models);models.performClick();});
            getInstrumentation().runOnMainSync(()->{android.view.View check=find(activity.getWindow().getDecorView(),"检查更新");assertNotNull("“我的”页应提供更新入口",check);check.performClick();});
            update=(UpdateActivity)getInstrumentation().waitForMonitorWithTimeout(monitor,10000);assertNotNull(update);
            assertTrue(java.util.Arrays.asList(context.getPackageManager().getPackageInfo(context.getPackageName(),PackageManager.GET_PERMISSIONS).requestedPermissions).contains("android.permission.REQUEST_INSTALL_PACKAGES"));
        }finally{UpdateActivity shown=update;if(shown!=null)getInstrumentation().runOnMainSync(shown::finish);getInstrumentation().runOnMainSync(activity::finish);getInstrumentation().removeMonitor(monitor);}
    }
    private AccessibilityNodeInfo button(AccessibilityNodeInfo root,String[] labels) {
        for(String label:labels)for(AccessibilityNodeInfo node:root.findAccessibilityNodeInfosByText(label))
            if(label.contentEquals(node.getText()==null?"":node.getText())&&node.isClickable()&&node.isEnabled())return node;
        return null;
    }
    public void testSystemInstallerCanReadVerifiedUpgradeWithoutInstallingIt()throws Exception {
        Files.write(cached.toPath(),apk);new AppUpdater(context).verify(cached,release);
        context.getSharedPreferences("pointverse",0).edit().putBoolean("configured",true).putBoolean("cloud",false).putBoolean("captureCamera",false).commit();
        MainActivity activity=(MainActivity)getInstrumentation().startActivitySync(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TASK));
        try {
            assertTrue(context.getPackageManager().canRequestPackageInstalls());
            getInstrumentation().runOnMainSync(()->activity.startActivityForResult(AppUpdater.installIntent(activity,cached),99));
            long until=System.currentTimeMillis()+15000;AccessibilityNodeInfo cancel=null;
            while(System.currentTimeMillis()<until){AccessibilityNodeInfo root=getInstrumentation().getUiAutomation().getRootInActiveWindow();
                String name=root==null?"":String.valueOf(root.getPackageName());
                if(name.contains("packageinstaller")||name.contains("permissioncontroller")){
                    AccessibilityNodeInfo negative=button(root,new String[]{"Cancel","取消"});
                    AccessibilityNodeInfo positive=button(root,new String[]{"Install","Update","安装","更新"});
                    if(negative!=null&&positive!=null){cancel=negative;break;}
                }
                Thread.sleep(100);
            }
            assertNotNull("应显示 Android 安装确认及取消按钮",cancel);
            android.graphics.Bitmap screenshot=getInstrumentation().getUiAutomation().takeScreenshot();
            if(screenshot!=null)try(FileOutputStream out=new FileOutputStream(new File(context.getFilesDir(),"qa-updater-installer.png"))){screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);screenshot.recycle();}
            assertTrue("必须保留系统确认，不静默安装",cancel.performAction(AccessibilityNodeInfo.ACTION_CLICK));
        }finally{getInstrumentation().runOnMainSync(activity::finish);}
        assertEquals("测试只能展示安装确认，不能替换当前应用",installedCode,context.getPackageManager().getPackageInfo(context.getPackageName(),0).getLongVersionCode());
    }
}
