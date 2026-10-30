package com.pointverse.app;

import android.content.*;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Built-in synthetic corpus. Every mutation is restricted to the isolated test database. */
final class DemoData {
    static final String DATABASE="test-points.db";
    private final PointStore store;private final JSONArray corpus;
    DemoData(Context context,PointStore store)throws Exception {if(!DATABASE.equals(store.getDatabaseName())&&!store.getDatabaseName().matches("test-points-[a-f0-9-]{36}\\.db"))throw new IllegalArgumentException("测试数据只能用于独立测试库");this.store=store;try(InputStream in=context.getAssets().open("planet-demo-points.json");ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1)out.write(b,0,n);corpus=new JSONArray(out.toString("UTF-8"));}}
    static int count(PointStore store){try(Cursor c=store.getReadableDatabase().rawQuery("SELECT count(*) FROM points WHERE trashed=0",null)){return c.moveToFirst()?c.getInt(0):0;}}
    int append(int count,boolean memories)throws Exception {SQLiteDatabase db=store.getWritableDatabase();db.beginTransaction();try{int start;try(Cursor c=db.rawQuery("SELECT count(*) FROM points",null)){c.moveToFirst();start=c.getInt(0);}for(int i=0;i<count;i++){JSONObject sample=corpus.getJSONObject((start+i)%corpus.length());String id=UUID.randomUUID().toString(),text=sample.getString("text");if(memories)text="回忆片段 "+(i+1)+"："+text+" 那天留下了这个问题，今天想再回头看看。";insert(db,id,sample,text,System.currentTimeMillis()-(memories?(8+i)*86400000L:0));}db.setTransactionSuccessful();return count;}finally{db.endTransaction();}}
    int globe()throws Exception {SQLiteDatabase db=store.getWritableDatabase();db.beginTransaction();try{int count=0;for(int i=0;i<corpus.length();i++){JSONObject sample=corpus.getJSONObject(i);if(insert(db,sample.getString("id"),sample,sample.getString("text"),System.currentTimeMillis()))count++;}db.setTransactionSuccessful();return count;}finally{db.endTransaction();}}
    private boolean insert(SQLiteDatabase db,String id,JSONObject sample,String text,long created)throws Exception {String topic=sample.getString("topic");ContentValues v=new ContentValues();v.put("id",id);v.put("title",TitleGeneration.excerpt(text));v.put("body",text);v.put("created",created);v.put("topic",topic);v.put("domain",domain(topic));v.put("title_edited",1);double latitude=Math.toRadians(sample.getDouble("latitude")),longitude=Math.toRadians(sample.getDouble("longitude"));v.put("embedding",new JSONArray().put(Math.cos(latitude)*Math.sin(longitude)).put(Math.sin(latitude)).put(Math.cos(latitude)*Math.cos(longitude)).toString());return db.insertWithOnConflict("points",null,v,SQLiteDatabase.CONFLICT_IGNORE)!=-1;}
    private String domain(String topic){if(Arrays.asList("哲学","历史","文学").contains(topic))return "人文与思想";if(Arrays.asList("天文","编程").contains(topic))return "科学与技术";if(Arrays.asList("医疗","运动").contains(topic))return "健康与运动";if(Arrays.asList("烹饪","园艺").contains(topic))return "生活与自然";if(topic.equals("金融"))return "经济与社会";return "艺术与探索";}
    void clear(){SQLiteDatabase db=store.getWritableDatabase();db.beginTransaction();try{for(String table:new String[]{"points","candidates","conversation","images","relations","feedback","reviews","tombstones","snapshots","manifestations","sync_sources","sync_versions"})db.delete(table,null,null);db.setTransactionSuccessful();}finally{db.endTransaction();}for(File dir:new File[]{store.audio,store.staging,store.imageDirectory(),store.cloudDirectory()}){File[] files=dir.listFiles();if(files!=null)for(File file:files)PointStore.removeTree(file);}}
}
