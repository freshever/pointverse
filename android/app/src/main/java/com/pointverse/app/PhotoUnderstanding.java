package com.pointverse.app;

import android.content.ContentValues;
import android.content.Context;
import android.graphics.Bitmap;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

/** Originals are committed first; each durable analysis step can survive leaving the screen. */
final class PhotoUnderstanding {
    interface Policy {
        boolean allowed();
        String token();
        String model();
    }
    interface Ocr { Description read(File image,String locale,String token,String model) throws Exception; }
    interface Vision { Description describe(File image, String locale, String token, String model) throws Exception; }
    static final class Description {
        final String text, model;
        Description(String text, String model) { this.text=text; this.model=model; }
    }
    private final PointStore store;
    private final Policy policy;
    private final Ocr ocr;
    private final Vision vision;
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Set<String> queued=ConcurrentHashMap.newKeySet();
    private final CopyOnWriteArrayList<Consumer<String>> listeners=new CopyOnWriteArrayList<>();

    PhotoUnderstanding(Context context, PointStore store, Policy policy) {
        this(store,policy,(file,locale,token,model)->requestCloud(file,locale,token,model,true,policy),
                (file,locale,token,model)->requestCloud(file,locale,token,model,false,policy));
        worker.execute(()->{store.recoverPhotoAnalysis();removeLegacyOcr(new File(context.getNoBackupFilesDir(),"ocr"));});
    }
    private static void removeLegacyOcr(File file) {
        File[] children=file.listFiles();if(children!=null)for(File child:children)removeLegacyOcr(child);file.delete();
    }
    PhotoUnderstanding(PointStore store, Policy policy, Ocr ocr, Vision vision) {
        this.store=store;this.policy=policy;this.ocr=ocr;this.vision=vision;
    }
    void addListener(Consumer<String> listener) { listeners.addIfAbsent(listener); }
    void removeListener(Consumer<String> listener) { listeners.remove(listener); }
    void resumePending() {
        worker.execute(()->{
            for(String point:store.pendingPhotoPoints(policy.allowed()&&!policy.token().isEmpty())) enqueuePoint(point,false);
        });
    }
    void enqueuePoint(String point, boolean retry) { enqueue(point,null,retry,false); }
    void enqueueImage(String point,String image,boolean ocrOnly) { enqueue(point,image,true,ocrOnly); }
    private void enqueue(String point,String image,boolean retry,boolean ocrOnly) {
        String key=image==null?point:image;
        if(!queued.add(key))return;
        worker.execute(()->{
            try {
                JSONArray rows=store.rows("images",point);
                for(int i=0;i<rows.length();i++) {
                    JSONObject row=rows.getJSONObject(i);
                    if(image==null||image.equals(row.optString("id"))) process(row.optString("id"),retry,ocrOnly);
                }
            }catch(Exception e){android.util.Log.w("PointVersePhotos","图片处理未完成",e);}
            finally {queued.remove(key);}
        });
    }
    // Synchronous core lets tests exercise persistence, retries and policy changes without a real account.
    void process(String image,boolean retry,boolean ocrOnly) throws Exception {
        JSONObject row=store.image(image);if(row==null)return;
        String state=row.optString("analysis_state"),point=row.optString("point_id");
        if(!retry&&!state.equals("pending")&&!state.equals("waiting_cloud"))return;
        if(!retry&&state.equals("waiting_cloud")&&(!policy.allowed()||policy.token().isEmpty()))return;
        PointStore.Point source=store.get(point);if(source.trashed!=0)return;
        File file=new File(store.imageDirectory(),row.optString("path"));
        if(!policy.allowed()||policy.token().isEmpty()){update(image,point,"waiting_cloud","");return;}
        String ocrError="";
        try {
            if(row.optInt("ocr_done")==0||ocrOnly) {
                update(image,point,"ocr_running","");
                try {
                    ensureCloud(policy,policy.token());
                    Description result=ocr.read(file,source.locale,policy.token(),policy.model());
                    ContentValues values=new ContentValues();values.put("ocr_text",result.text.trim());values.put("ocr_model",result.model);values.put("ocr_done",1);
                    store.imageAnalysis(image,values);changed(point);
                }catch(Exception e){ocrError="云端文字识别未完成："+error(e);}
            }
            if(!policy.allowed()||policy.token().isEmpty()){update(image,point,"waiting_cloud",ocrError);return;}
            row=store.image(image);if(row==null||store.get(point).trashed!=0)return;
            if(ocrOnly||(!retry&&!row.optString("visual_text").isEmpty())) {
                update(image,point,ocrError.isEmpty()?(row.optString("visual_text").isEmpty()?"text_complete":"complete"):"failed",ocrError);return;
            }
            update(image,point,"vision_running",ocrError);
            Description result=vision.describe(file,source.locale,policy.token(),policy.model());
            if(result.text.trim().isEmpty())throw new IOException("模型返回了空内容，请重试");
            ContentValues values=new ContentValues();values.put("visual_text",result.text.trim());values.put("visual_model",result.model);
            values.put("analysis_state",ocrError.isEmpty()?"complete":"partial");values.put("analysis_error",ocrError);
            store.imageAnalysis(image,values);changed(point);
        }catch(Exception e) {
            update(image,point,!policy.allowed()||policy.token().isEmpty()?"waiting_cloud":"failed",error(e));
        }
    }
    private void update(String image,String point,String state,String error) {
        ContentValues values=new ContentValues();values.put("analysis_state",state);values.put("analysis_error",error);
        store.imageAnalysis(image,values);changed(point);
    }
    private void changed(String point) { for(Consumer<String> listener:listeners)listener.accept(point); }
    private static String error(Exception e) { String text=e.getMessage();if(text==null||text.trim().isEmpty())return "请稍后重试";return text.substring(0,Math.min(180,text.length())); }
    static JSONObject visionPayload(File file,String locale,String model) throws Exception {
        return filePayload(file,locale,model,false);
    }
    static JSONObject ocrPayload(File file,String locale,String model) throws Exception {
        return filePayload(file,locale,model,true);
    }
    private static JSONObject filePayload(File file,String locale,String model,boolean ocr)throws Exception {
        Bitmap image=PhotoDecoder.fromFile(file,1024);
        try{return payload(image,locale,model,ocr);}finally{image.recycle();}
    }
    private static JSONObject payload(Bitmap source,String locale,String model,boolean ocr)throws Exception {
        float scale=Math.min(1f,1024f/Math.max(source.getWidth(),source.getHeight()));
        Bitmap image=scale<1?Bitmap.createScaledBitmap(source,Math.max(1,Math.round(source.getWidth()*scale)),Math.max(1,Math.round(source.getHeight()*scale)),true):source;
        try {
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();image.compress(Bitmap.CompressFormat.JPEG,65,bytes);
            if(bytes.size()>500000){bytes.reset();image.compress(Bitmap.CompressFormat.JPEG,35,bytes);}
            if(bytes.size()>500000)throw new IOException("图片过大，请裁剪后重试");
            String language=locale.startsWith("zh-Hant")||locale.startsWith("zh-TW")?"Traditional Chinese":locale.startsWith("zh")?"Simplified Chinese":locale.startsWith("ja")?"Japanese":"English";
            String instruction=ocr?"Extract all clearly visible text from the image, preserving the original language, wording, reading order and line breaks. Do not translate, correct, guess missing characters or describe the scene. Output only the recognized text, without explanations or markdown. If there is no readable text, output exactly [NO_TEXT].":"Describe the visible image in "+language+". Be concise; distinguish observations from uncertainty.";
            JSONArray content=new JSONArray().put(new JSONObject().put("type","text").put("text",instruction))
                    .put(new JSONObject().put("type","image_url").put("image_url",new JSONObject().put("url","data:image/jpeg;base64,"+android.util.Base64.encodeToString(bytes.toByteArray(),android.util.Base64.NO_WRAP))));
            return new JSONObject().put("model",model).put("max_tokens",ocr?512:256).put("messages",new JSONArray().put(new JSONObject().put("role","user").put("content",content)));
        }finally{if(image!=source)image.recycle();}
    }
    private static void ensureCloud(Policy policy,String token)throws IOException {
        if(!policy.allowed()||token.isEmpty()||!token.equals(policy.token()))throw new IOException("请切换登录版并登录点界账户后重试");
    }
    static Description response(JSONObject response,String model,boolean ocr)throws Exception {
        if(ocr&&"length".equals(response.getJSONArray("choices").getJSONObject(0).optString("finish_reason")))throw new IOException("图片文字较多，请裁剪分段识别，避免遗漏");
        String text=NetworkModel.responseText(response);return new Description(ocr&&text.equals("[NO_TEXT]")?"":text,response.optString("model",model));
    }
    private static Description requestCloud(File file,String locale,String token,String model,boolean ocr,Policy policy) throws Exception {
        ensureCloud(policy,token);JSONObject body=filePayload(file,locale,model,ocr);ensureCloud(policy,token);
        return response(NetworkModel.api("/v1/ai/chat/completions","POST",token,body),model,ocr);
    }
    String extractText(Bitmap image,String locale)throws Exception {
        String token=policy.token(),model=policy.model();ensureCloud(policy,token);JSONObject body=payload(image,locale,model,true);ensureCloud(policy,token);
        String text=response(NetworkModel.api("/v1/ai/chat/completions","POST",token,body),model,true).text;
        if(text.isEmpty())throw new IOException("未识别到清晰文字，请选择更清晰的图片");return text;
    }
    void shutdownForTest() { worker.shutdownNow(); }
}
