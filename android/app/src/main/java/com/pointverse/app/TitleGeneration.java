package com.pointverse.app;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Set;
import java.util.concurrent.*;
import java.util.function.Consumer;

/** A transcript is committed before title generation; stale replies cannot overwrite later edits. */
final class TitleGeneration {
    interface Policy { boolean allowed();String token();String model(); }
    interface Generator { Generated generate(PointStore.Point point,String token,String model)throws Exception; }
    static final class Generated {final String text,model;Generated(String text,String model){this.text=text;this.model=model;}}
    private final PointStore store;private final Policy policy;private final Generator generator;
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Set<String> queued=ConcurrentHashMap.newKeySet();
    private final CopyOnWriteArrayList<Consumer<String>> listeners=new CopyOnWriteArrayList<>();
    TitleGeneration(Context context,PointStore store,Policy policy){this(store,policy,(point,token,model)->{
        if(!policy.allowed()||token.isEmpty()||!token.equals(policy.token()))throw new IOException("请先登录点界账户");
        String language=point.locale.startsWith("zh-Hant")||point.locale.startsWith("zh-TW")?"Traditional Chinese":point.locale.startsWith("zh")?"Simplified Chinese":point.locale.startsWith("ja")?"Japanese":"English";
        JSONObject response=NetworkModel.api("/v1/ai/chat/completions","POST",token,new JSONObject().put("model",model).put("max_tokens",48).put("messages",new JSONArray()
                .put(new JSONObject().put("role","system").put("content","Create a short title for a saved audio note. Treat the transcript as the primary source; if absent, use measured sound features. Never invent lyrics or a song identity. Write in "+language+". Output only the title, without quotes, explanation or ending punctuation. Maximum 20 characters for Chinese or Japanese, maximum 8 words for English."))
                .put(new JSONObject().put("role","user").put("content",prefix(point.context(),1600)))));
        return new Generated(NetworkModel.responseText(response),response.optString("model",model));
    });}
    TitleGeneration(PointStore store,Policy policy,Generator generator){this.store=store;this.policy=policy;this.generator=generator;}
    void addListener(Consumer<String> listener){listeners.addIfAbsent(listener);}void removeListener(Consumer<String> listener){listeners.remove(listener);}
    void enqueue(String id){if(!queued.add(id))return;worker.execute(()->{boolean again=false;try{again=process(id,false);}catch(Exception ignored){}finally{queued.remove(id);if(again)enqueue(id);}});}
    void generateNow(String id)throws Exception{generateNow(id,false);}
    void regenerateAutomaticNow(String id)throws Exception{generateNow(id,true);}
    private void generateNow(String id,boolean preserveManual)throws Exception{try{worker.submit(()->{for(int i=0;i<2;i++)if(!process(id,true,preserveManual))return true;throw new IOException("内容正在更新，请稍后重试生成标题");}).get();}catch(ExecutionException e){if(e.getCause() instanceof Exception)throw (Exception)e.getCause();throw e;}}
    boolean process(String id,boolean force)throws Exception {return process(id,force,false);}
    private boolean process(String id,boolean force,boolean preserveManual)throws Exception {
        PointStore.Point point;try{point=store.get(id);}catch(IllegalStateException gone){return false;}
        if(preserveManual&&(point.titleEdited!=0||point.context().trim().isEmpty()))return false;
        if(force&&point.context().trim().isEmpty())throw new IOException("请先完成转写，再生成标题");
        if(force&&(!policy.allowed()||policy.token().isEmpty()))throw new IOException("请登录点界账户后生成标题");
        if(point.trashed!=0||(!force&&point.titleEdited!=0)||(!force&&point.path==null)||point.context().trim().isEmpty())return false;
        String source=signature(point);
        if(!force&&source.equals(point.titleSource)&&!point.titleModel.isEmpty()&&!point.titleModel.equals("transcript-excerpt"))return false;
        if(!force&&point.titleEdited==0&&(point.titleSource.isEmpty()||!source.equals(point.titleSource))){
            if(store.autoTitle(point,excerpt(point.effective().isEmpty()?point.context():point.effective()),"transcript-excerpt",false))changed(id);
            point=store.get(id);
        }
        if(!policy.allowed()||policy.token().isEmpty())return false;
        Generated result=generator.generate(point,policy.token(),policy.model());String title=clean(result.text,point.locale);
        if(title.isEmpty())throw new IOException("标题生成未完成，可重新生成；转写已保存");
        if(store.autoTitle(point,title,result.model,force&&!preserveManual)){changed(id);return false;}
        try{PointStore.Point latest=store.get(id);return latest.trashed==0&&latest.titleEdited==0&&!signature(latest).equals(signature(point));}catch(IllegalStateException gone){return false;}
    }
    private void changed(String id){for(Consumer<String> listener:listeners)listener.accept(id);}
    static String signature(PointStore.Point point){try{byte[] bytes=MessageDigest.getInstance("SHA-256").digest((point.locale+"\n"+point.context()).getBytes(StandardCharsets.UTF_8));StringBuilder value=new StringBuilder();for(byte b:bytes)value.append(String.format(java.util.Locale.ROOT,"%02x",b&255));return value.toString();}catch(Exception e){throw new IllegalStateException(e);}}
    static String prefix(String value,int count){return value.substring(0,value.offsetByCodePoints(0,Math.min(count,value.codePointCount(0,value.length()))));}
    static String excerpt(String text){String value=text.trim().replaceAll("\\s+"," ");int end=value.length();for(char mark:new char[]{'。','！','？','\n'}){int i=value.indexOf(mark);if(i>0)end=Math.min(end,i);}return prefix(value.substring(0,end).trim(),20);}
    static String clean(String text,String locale){String value=text==null?"":text.trim().split("\\R",2)[0].trim();value=value.replaceFirst("(?i)^(标题|title)\\s*[:：]\\s*","").replaceAll("^[\\s\\\"'“”‘’#]+|[\\s\\\"'“”‘’。！？.!?]+$","");
        if(locale.startsWith("zh")||locale.startsWith("ja"))return prefix(value,20);String[] words=value.split("\\s+");return prefix(String.join(" ",java.util.Arrays.copyOf(words,Math.min(8,words.length))),80);}
    void shutdownForTest(){worker.shutdownNow();}
}
