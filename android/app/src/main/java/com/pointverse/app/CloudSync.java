package com.pointverse.app;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;

/** Versioned manual upload with the same format_version=1 contract as iOS. */
final class CloudSync {
    private final PointStore store;
    CloudSync(PointStore store){this.store=store;}
    JSONObject snapshot(PointStore.Point point)throws Exception{
        android.database.sqlite.SQLiteDatabase db=store.getWritableDatabase();db.beginTransaction();
        try{JSONObject result=buildSnapshot(store.get(point.id));db.setTransactionSuccessful();return result;}finally{db.endTransaction();}
    }
    private JSONObject buildSnapshot(PointStore.Point p)throws Exception{
        String existing=store.snapshotCache(p.id,p.revision);if(existing!=null)return new JSONObject(existing);
        double timestamp=p.created/1000.0;String message=UUID.nameUUIDFromBytes((p.id+"message").getBytes(StandardCharsets.UTF_8)).toString();
        JSONArray assets=new JSONArray(),audio=new JSONArray(),images=new JSONArray(),transcripts=new JSONArray(),messages=new JSONArray();
        JSONObject point=new JSONObject().put("id",p.id).put("head_revision",p.revision).put("created_at",timestamp).put("accepted_title",p.title).put("modality",p.path==null?"text":"audio");
        messages.put(new JSONObject().put("id",message).put("point_id",p.id).put("sequence",0).put("role","user").put("user_text",p.path==null?p.body:"").put("created_at",timestamp));
        if(p.path!=null){File file=store.audioFile(p);String hash=LocalSpeech.hash(file);
            assets.put(asset(p.id,hash,file.length(),"audio"));audio.put(new JSONObject().put("id",p.id).put("message_id",message).put("sha256",hash).put("byte_count",file.length()).put("state","available").put("relative_path",p.path).put("duration_ms",p.duration));
            transcripts.put(new JSONObject().put("asset_id",p.id).put("engine_text",p.machine).put("user_text",p.edited==1?p.body:JSONObject.NULL));
        }
        JSONArray originals=store.rows("images",p.id);
        for(int i=0;i<originals.length();i++){JSONObject image=originals.getJSONObject(i);File file=new File(store.imageDirectory(),image.getString("path"));String hash=LocalSpeech.hash(file);assets.put(asset(image.getString("id"),hash,file.length(),"image"));images.put(new JSONObject().put("id",image.getString("id")).put("point_id",p.id).put("sha256",hash).put("recognized_text",image.optString("caption")).put("model_id",image.optString("model")));}
        JSONArray chat=store.rows("conversation",p.id);for(int i=0;i<chat.length();i++){JSONObject m=chat.getJSONObject(i);messages.put(new JSONObject().put("id",m.getString("id")).put("point_id",p.id).put("sequence",i+1).put("role",m.getString("role")).put("user_text",m.getString("text")).put("model_id",m.getString("model")));}
        JSONObject payload=new JSONObject().put("points",new JSONArray().put(point)).put("messages",messages).put("audio_assets",audio).put("point_images",images).put("transcripts",transcripts).put("transcription_candidates",store.rows("candidates",p.id)).put("manifestations",store.rows("manifestations",p.id));
        JSONObject manifest=new JSONObject().put("format_version",1).put("point_id",p.id).put("revision",p.revision).put("title",p.title).put("preview",p.effective().substring(0,Math.min(500,p.effective().length()))).put("created_at",timestamp).put("assets",assets).put("payload",payload);
        store.cacheSnapshot(p.id,p.revision,manifest.toString());return manifest;
    }
    private JSONObject asset(String id,String hash,long bytes,String kind)throws Exception{return new JSONObject().put("id",id).put("sha256",hash).put("byte_count",bytes).put("kind",kind);}
    void upload(PointStore.Point p,String token)throws Exception{
        JSONObject manifest=snapshot(p);JSONArray assets=manifest.getJSONArray("assets");JSONArray images=store.rows("images",p.id);
        for(int i=0;i<assets.length();i++){JSONObject item=assets.getJSONObject(i);File file=null;
            if(item.getString("kind").equals("audio"))file=store.audioFile(p);
            else for(int n=0;n<images.length();n++)if(images.getJSONObject(n).getString("id").equals(item.getString("id")))file=new File(store.imageDirectory(),images.getJSONObject(n).getString("path"));
            if(file==null||!file.isFile()||!LocalSpeech.hash(file).equals(item.getString("sha256")))throw new IOException("本地附件缺失或校验失败");
            if(file.length()>128L*1024*1024)throw new IOException("附件超过 128 MB");
            NetworkModel.uploadFile(token,item.getString("sha256"),file);
        }
        NetworkModel.api("/v1/sync/points","POST",token,manifest);
    }
}
