package com.pointverse.app;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.os.Build;
import android.system.Os;
import org.json.JSONArray;
import org.json.JSONObject;
import javax.net.ssl.HttpsURLConnection;
import java.io.*;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.UUID;

/** Public release downloads are independent of the account/content upload policy. */
final class AppUpdater {
    static final String BASE="https://dianjie.org/downloads/android/";
    static final long MAX_APK_BYTES=200L*1024*1024;
    interface Connections { HttpsURLConnection open(URL url)throws Exception; }
    interface Progress { void update(long received,long total); }
    static final class Release {
        final String file,version,sha256,signer,notes;
        final long code,size;
        final int minSdk;
        Release(JSONObject data)throws Exception {
            file=data.getString("file");version=data.getString("versionName");code=data.getLong("versionCode");size=data.getLong("size");
            sha256=data.getString("sha256");signer=data.getString("signerSha256");notes=data.optString("notes");minSdk=data.getInt("minSdk");
            if(!"com.pointverse.app".equals(data.getString("package"))||!file.matches("pointverse-[A-Za-z0-9._-]+\\.apk")
                    ||!sha256.matches("[a-f0-9]{64}")||!signer.matches("[a-f0-9]{64}")||code<=0||size<=0||size>MAX_APK_BYTES
                    ||version.isEmpty()||version.length()>80||minSdk<28)throw new IOException("更新信息异常，请稍后重试");
        }
        JSONObject json()throws Exception {
            return new JSONObject().put("package","com.pointverse.app").put("file",file).put("versionName",version).put("versionCode",code)
                    .put("size",size).put("sha256",sha256).put("signerSha256",signer).put("notes",notes).put("minSdk",minSdk);
        }
    }
    private final Context context;
    private final Connections connections;
    private volatile HttpsURLConnection active;
    AppUpdater(Context context){this(context,url->(HttpsURLConnection)url.openConnection());}
    AppUpdater(Context context,Connections connections){this.context=context.getApplicationContext();this.connections=connections;}
    Release check()throws Exception {
        HttpsURLConnection connection=connect(new URL(BASE+"releases.json"));
        try {
            if(connection.getResponseCode()!=200)throw new IOException("暂时无法检查更新，请稍后重试");
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();
            try(InputStream input=connection.getInputStream()) {
                byte[] block=new byte[8192];int count;
                while((count=input.read(block))!=-1){interrupted();if(bytes.size()+count>1024*1024)throw new IOException("更新信息过大");bytes.write(block,0,count);}
            }
            Release release=latest(new JSONObject(bytes.toString(StandardCharsets.UTF_8.name())),installed().getLongVersionCode());
            if(release!=null)validateRelease(release);
            return release;
        }finally{connection.disconnect();active=null;}
    }
    static Release latest(JSONObject catalog,long installedCode)throws Exception {
        if(catalog.getInt("schemaVersion")!=1)throw new IOException("暂不支持此更新格式");
        String latest=catalog.getString("latest");JSONArray releases=catalog.getJSONArray("releases");
        for(int i=0;i<releases.length();i++)if(latest.equals(releases.getJSONObject(i).optString("file"))){
            Release release=new Release(releases.getJSONObject(i));return release.code>installedCode?release:null;
        }
        throw new IOException("没有找到可用的更新包，请稍后重试");
    }
    File cached(Release release){return new File(directory(context),release.sha256+".apk");}
    File download(Release release,Progress progress)throws Exception {
        validateRelease(release);
        File result=cached(release);
        if(result.isFile()) {
            try{verify(result,release);progress.update(release.size,release.size);return result;}
            catch(InterruptedIOException e){throw e;}catch(Exception e){result.delete();}
        }
        File temporary=new File(directory(context),UUID.randomUUID()+".part.apk");
        HttpsURLConnection connection=connect(new URL(BASE+"files/"+release.file));
        try {
            if(connection.getResponseCode()!=200)throw new IOException("下载未完成，请检查网络后重试");
            long length=connection.getContentLengthLong();
            if(length>=0&&length!=release.size)throw new IOException("安装包大小不符，请稍后重试");
            try(InputStream input=connection.getInputStream();FileOutputStream output=new FileOutputStream(temporary)) {
                byte[] block=new byte[32768];long received=0;int count;progress.update(0,release.size);
                while((count=input.read(block))!=-1){
                    interrupted();received+=count;if(received>release.size)throw new IOException("安装包大小不符，已停止下载");
                    output.write(block,0,count);progress.update(received,release.size);
                }
                output.getFD().sync();
            }
            verify(temporary,release);interrupted();Os.rename(temporary.getAbsolutePath(),result.getAbsolutePath());return result;
        }finally{connection.disconnect();active=null;temporary.delete();}
    }
    void verify(File file,Release release)throws Exception {
        validateRelease(release);interrupted();
        if(!file.isFile()||file.length()!=release.size||!digest(file).equals(release.sha256))throw new IOException("安装包校验失败，请重新下载");
        PackageInfo archive=archive(file.getAbsolutePath());
        if(archive==null||!context.getPackageName().equals(archive.packageName)||archive.getLongVersionCode()!=release.code
                ||!release.version.equals(archive.versionName)||archive.applicationInfo==null||archive.applicationInfo.minSdkVersion!=release.minSdk)
            throw new IOException("安装包与更新信息不符，请重新下载");
        if(!signer(archive).equals(release.signer))throw new IOException("安装包签名不符，无法安全覆盖更新");
    }
    private void validateRelease(Release release)throws Exception {
        if(release.minSdk>Build.VERSION.SDK_INT)throw new IOException("此更新不支持当前 Android 版本");
        PackageInfo installed=installed();
        if(release.code<=installed.getLongVersionCode())throw new IOException("当前已是最新版本，无需安装旧版本");
        if(!signer(installed).equals(release.signer))throw new IOException("更新包签名与当前点界不同，请使用原下载渠道");
    }
    @SuppressWarnings("deprecation")
    private PackageInfo installed()throws Exception {
        PackageManager manager=context.getPackageManager();
        PackageInfo info=manager.getPackageInfo(context.getPackageName(),PackageManager.GET_SIGNING_CERTIFICATES|PackageManager.GET_SIGNATURES);
        if(hasSignatures(info))return info;
        info=manager.getPackageInfo(context.getPackageName(),PackageManager.GET_SIGNATURES);
        if(hasSignatures(info))return info;
        // Read our own installed APK if the installed-package query omits certificate metadata.
        PackageInfo source=archive(context.getApplicationInfo().sourceDir);
        return hasSignatures(source)?source:info;
    }
    @SuppressWarnings("deprecation")
    private PackageInfo archive(String path) {
        PackageManager manager=context.getPackageManager();
        PackageInfo info=manager.getPackageArchiveInfo(path,PackageManager.GET_SIGNING_CERTIFICATES|PackageManager.GET_SIGNATURES);
        return hasSignatures(info)?info:manager.getPackageArchiveInfo(path,PackageManager.GET_SIGNATURES);
    }
    @SuppressWarnings("deprecation")
    private static Signature[] signatures(PackageInfo info) {
        if(info==null)return null;
        Signature[] current=info.signingInfo==null?null:info.signingInfo.getApkContentsSigners();
        return current==null||current.length==0?info.signatures:current;
    }
    private static boolean hasSignatures(PackageInfo info) {Signature[] values=signatures(info);return values!=null&&values.length>0;}
    static String signer(PackageInfo info)throws Exception {
        Signature[] values=signatures(info);
        if(values==null||values.length==0)throw new IOException("无法读取应用签名，请从下载网站覆盖安装新版");
        if(values.length!=1)throw new IOException("应用签名格式不支持");
        return hex(MessageDigest.getInstance("SHA-256").digest(values[0].toByteArray()));
    }
    static String digest(File file)throws Exception {
        MessageDigest digest=MessageDigest.getInstance("SHA-256");
        try(InputStream input=new FileInputStream(file)){byte[] block=new byte[32768];int count;while((count=input.read(block))!=-1){interrupted();digest.update(block,0,count);}}
        return hex(digest.digest());
    }
    private static String hex(byte[] bytes){StringBuilder value=new StringBuilder();for(byte b:bytes)value.append(String.format(Locale.ROOT,"%02x",b&255));return value.toString();}
    static android.content.Intent installIntent(Context context,File file) {
        android.net.Uri uri=UpdatePackageProvider.uri(context,file);
        android.content.Intent intent=new android.content.Intent(android.content.Intent.ACTION_VIEW).setDataAndType(uri,"application/vnd.android.package-archive")
                .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION).putExtra(android.content.Intent.EXTRA_RETURN_RESULT,true);
        intent.setClipData(android.content.ClipData.newRawUri("点界更新",uri));return intent;
    }
    static File directory(Context context){File dir=new File(context.getCacheDir(),"updates");if(!dir.isDirectory()&&!dir.mkdirs())throw new IllegalStateException("无法创建更新目录");return dir;}
    private HttpsURLConnection connect(URL url)throws Exception {
        interrupted();HttpsURLConnection connection=connections.open(url);active=connection;
        connection.setInstanceFollowRedirects(false);connection.setUseCaches(false);connection.setConnectTimeout(15000);connection.setReadTimeout(20000);
        connection.setRequestProperty("Accept-Encoding","identity");connection.setRequestProperty("User-Agent","Pointverse-Android/"+BuildVersion.name(context));return connection;
    }
    private static void interrupted()throws InterruptedIOException{if(Thread.currentThread().isInterrupted())throw new InterruptedIOException("已取消下载");}
    void cancel(){HttpsURLConnection connection=active;if(connection!=null)connection.disconnect();}
}
