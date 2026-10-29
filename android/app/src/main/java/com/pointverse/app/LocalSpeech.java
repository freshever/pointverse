package com.pointverse.app;

import android.content.Context;
import org.vosk.Model;
import org.vosk.Recognizer;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.*;

/** Real offline ASR; no Android SpeechRecognizer or network fallback is used. */
final class LocalSpeech {
    static final String ID="vosk-model-small-cn-0.22";
    static final String SHA="3af8b0e7e0f835ae9d414ce5df580237a3cfb08d586c9fbbb0f7ff29ad5b14ba";
    static final String URL="https://dianjie.org/downloads/android/models/"+ID+".zip";
    private final File root, installed;
    interface Progress { void update(String text); }
    LocalSpeech(Context context){root=new File(context.getNoBackupFilesDir(),"speech-models");root.mkdirs();installed=new File(root,ID);}
    boolean available(){return new File(installed,".verified").isFile();}
    synchronized void download(Progress progress) throws Exception {
        if(available())return;
        File archive=new File(root,ID+".zip.part");if(archive.isFile()&&SHA.equals(hash(archive))){install(archive,progress);archive.delete();return;}long offset=archive.exists()?archive.length():0;
        HttpURLConnection c=(HttpURLConnection)new java.net.URL(URL).openConnection();c.setConnectTimeout(15000);c.setReadTimeout(20000);c.setInstanceFollowRedirects(false);
        if(offset>0)c.setRequestProperty("Range","bytes="+offset+"-");
        try{
            int code=c.getResponseCode();if(code!=200&&code!=206)throw new IOException("模型下载暂不可用，请稍后重试");
            if(code==200)offset=0;
            long total=c.getContentLengthLong()+offset,received=offset,last=0;
            try(InputStream in=c.getInputStream();FileOutputStream out=new FileOutputStream(archive,offset>0)){
                byte[] buffer=new byte[32768];int n;
                while((n=in.read(buffer))!=-1){if(Thread.currentThread().isInterrupted())throw new InterruptedIOException("已暂停下载");received+=n;if(received>64L*1024*1024)throw new IOException("模型文件超过限制");out.write(buffer,0,n);if(received-last>262144){progress.update("正在下载中文转写模型 · "+(total>0?received*100/total:0)+"%");last=received;}}
                out.getFD().sync();
            }
        }finally{c.disconnect();}
        install(archive,progress);archive.delete();
    }
    synchronized void install(File archive,Progress progress) throws Exception {
        progress.update("正在校验离线语音模型…");
        if(!SHA.equals(hash(archive))) {archive.delete();throw new IOException("模型校验失败，请重新下载");}
        File staging=new File(root,"installing");remove(staging);staging.mkdirs();
        long total=0;int entries=0;
        try(ZipInputStream zip=new ZipInputStream(new FileInputStream(archive))){ZipEntry entry;
            while((entry=zip.getNextEntry())!=null){
                if(++entries>2000)throw new IOException("模型条目过多");
                File target=new File(staging,entry.getName());
                if(!target.getCanonicalPath().startsWith(staging.getCanonicalPath()+File.separator))throw new IOException("无效的模型路径");
                if(entry.isDirectory()){target.mkdirs();continue;}target.getParentFile().mkdirs();
                try(FileOutputStream out=new FileOutputStream(target)){byte[] buffer=new byte[32768];int n;while((n=zip.read(buffer))!=-1){if(Thread.currentThread().isInterrupted())throw new InterruptedIOException("已取消安装");total+=n;if(total>256L*1024*1024)throw new IOException("模型解压超过限制");out.write(buffer,0,n);}out.getFD().sync();}
            }
        }
        File model=new File(staging,ID);progress.update("正在验证本机语音引擎…");
        synchronized(NativeInference.LOCK){try(Model check=new Model(model.getAbsolutePath())){ }}
        if(installed.exists())remove(installed);
        if(!model.renameTo(installed))throw new IOException("无法安装语音模型");
        try(FileOutputStream out=new FileOutputStream(new File(installed,".verified"))){out.write(SHA.getBytes(java.nio.charset.StandardCharsets.UTF_8));out.getFD().sync();}
        remove(staging);progress.update("中文离线转写已就绪");
    }
    synchronized String transcribe(File audio,Progress progress) throws Exception {
        if(!available())throw new IOException("请先在“我的”页下载中文离线语音模型");
        progress.update("正在本机转写，原音不会上传…");
        synchronized(NativeInference.LOCK){
        try(Model model=new Model(installed.getAbsolutePath());Recognizer recognizer=new Recognizer(model,16000)){
            StringBuilder result=new StringBuilder();
            // Decode in short blocks to bound memory and feed the recognizer incrementally.
            CloudTranscription.decodeBlocks(audio,2,wav->{
                byte[] pcm=Arrays.copyOfRange(wav,44,wav.length);
                if(recognizer.acceptWaveForm(pcm,pcm.length))append(result,new JSONObject(recognizer.getResult()).optString("text"));
                return "";
            });
            append(result,new JSONObject(recognizer.getFinalResult()).optString("text"));
            if(result.length()==0)throw new IOException("未识别到清晰语音，原音仍在，可重新转写");
            return result.toString();
        }
        }
    }
    private static void append(StringBuilder out,String text){text=text.trim().replace(" ","");if(!text.isEmpty()){if(out.length()>0)out.append('，');out.append(text);}}
    synchronized void uninstall(){remove(installed);}
    static String hash(File file)throws Exception{MessageDigest digest=MessageDigest.getInstance("SHA-256");try(InputStream in=new FileInputStream(file)){byte[] b=new byte[32768];int n;while((n=in.read(b))!=-1)digest.update(b,0,n);}StringBuilder hex=new StringBuilder();for(byte value:digest.digest())hex.append(String.format(Locale.ROOT,"%02x",value&255));return hex.toString();}
    static void remove(File file){File[] children=file.listFiles();if(children!=null)for(File child:children)remove(child);file.delete();}
}
