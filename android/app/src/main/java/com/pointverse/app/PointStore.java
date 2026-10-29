package com.pointverse.app;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.media.MediaMetadataRetriever;
import android.system.Os;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;

/** Local source of truth. A finalized audio file precedes its idempotent SQLite row. */
final class PointStore extends SQLiteOpenHelper {
    final File staging, audio;
    static final class Point {
        String id, title, body, path, summary, machine, speaker, voice, domain, topic, project, expression, manual, embedding, locale, analysis;
        int revision, edited, titleEdited, titleVersion;
        String titleSource="",titleModel="";
        long trashed, viewed;
        String imageContext = "";
        String context() { String sound=AudioUnderstanding.context(analysis);return effective() + (imageContext.isEmpty() ? "" : "\n\n[图片内容]\n" + imageContext)+(sound.isEmpty()?"":"\n\n[音乐与现场声音]\n"+sound); }
        String effective() { return edited!=0 || path==null || !body.isEmpty()?body:machine; }
        long created, duration;
    }
    PointStore(Context context) { this(context, "points.db"); }
    PointStore(Context context, String databaseName) {
        super(context, databaseName, null, 8);
        File base = new File(context.getNoBackupFilesDir(), databaseName + "-media");
        staging = new File(base, "staging"); audio = new File(base, "audio");
        if ((!staging.isDirectory() && !staging.mkdirs()) || (!audio.isDirectory() && !audio.mkdirs()))
            throw new IllegalStateException("无法创建录音目录");
        setWriteAheadLoggingEnabled(true);
    }
    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE points (id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, created INTEGER NOT NULL, audio_path TEXT, duration INTEGER NOT NULL DEFAULT 0, sha256 TEXT)");
        db.execSQL("CREATE INDEX points_created ON points(created DESC)");
        upgradeV2(db);
        upgradeV3(db);
        upgradeV4(db);
        upgradeV5(db);
        upgradeV6(db);
        upgradeV7(db);
    }
    @Override public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        if(oldVersion<2) upgradeV2(db);
        if(oldVersion<3) upgradeV3(db);
        if(oldVersion<4) upgradeV4(db);
        if(oldVersion<5) upgradeV5(db);
        if(oldVersion<6) upgradeV6(db);
        if(oldVersion<7) upgradeV7(db);
        if(oldVersion<8) upgradeV8(db);
    }
    private void upgradeV8(SQLiteDatabase db){boolean lens=false;try(Cursor c=db.rawQuery("PRAGMA table_info(manifestations)",null)){while(c.moveToNext())if(c.getString(c.getColumnIndexOrThrow("name")).equals("lens"))lens=true;}if(!lens)db.execSQL("ALTER TABLE manifestations ADD COLUMN lens TEXT NOT NULL DEFAULT 'original'");}
    private void upgradeV7(SQLiteDatabase db){db.execSQL("CREATE TABLE manifestations(id TEXT PRIMARY KEY,point_id TEXT NOT NULL,kind TEXT NOT NULL,content TEXT NOT NULL,model TEXT NOT NULL,lens TEXT NOT NULL DEFAULT 'original',source_revision INTEGER NOT NULL,created INTEGER NOT NULL)");db.execSQL("CREATE INDEX manifestations_point ON manifestations(point_id,created)");}
    String saveManifestation(Point source,String text,String model)throws IOException {return saveManifestation(source,"text",text,model,"original");}
    String saveManifestation(Point source,String kind,String text,String model,String lens)throws IOException {
        if(text.trim().isEmpty())throw new IOException("文字显影为空，请重试");SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{if(get(source.id).trashed!=0)throw new IOException("想法已移入回收站");String id=UUID.randomUUID().toString();ContentValues v=new ContentValues();v.put("id",id);v.put("point_id",source.id);v.put("kind",kind);v.put("content",text);v.put("model",model);v.put("lens",lens);v.put("source_revision",source.revision);v.put("created",System.currentTimeMillis());db.insertOrThrow("manifestations",null,v);bump(source.id);db.setTransactionSuccessful();return id;}finally{db.endTransaction();}
    }
    private void upgradeV6(SQLiteDatabase db) {
        for(String column:new String[]{"title_edited INTEGER NOT NULL DEFAULT 0","title_source TEXT NOT NULL DEFAULT ''","title_model TEXT NOT NULL DEFAULT ''","title_version INTEGER NOT NULL DEFAULT 0"})db.execSQL("ALTER TABLE points ADD COLUMN "+column);
        db.execSQL("UPDATE points SET title_edited=1 WHERE title NOT IN ('','语音想法','未命名想法')");
    }
    private void upgradeV5(SQLiteDatabase db) {
        db.execSQL("ALTER TABLE images ADD COLUMN ocr_model TEXT NOT NULL DEFAULT ''");
        // Preserve prior output until a cloud result succeeds; manual captions remain protected.
        db.execSQL("UPDATE images SET ocr_done=0,analysis_state=CASE WHEN analysis_state='manual' THEN 'manual' ELSE 'pending' END,analysis_error='' WHERE ocr_done=1 OR ocr_text<>''");
    }
    private void upgradeV4(SQLiteDatabase db) {
        for (String column : new String[]{"ocr_text TEXT NOT NULL DEFAULT ''", "visual_text TEXT NOT NULL DEFAULT ''",
                "visual_model TEXT NOT NULL DEFAULT ''", "analysis_state TEXT NOT NULL DEFAULT 'pending'",
                "analysis_error TEXT NOT NULL DEFAULT ''", "caption_edited INTEGER NOT NULL DEFAULT 0",
                "ocr_done INTEGER NOT NULL DEFAULT 0"}) db.execSQL("ALTER TABLE images ADD COLUMN " + column);
        // Existing text may have been written by the user; never silently replace it.
        db.execSQL("UPDATE images SET caption_edited=1, analysis_state='manual' WHERE caption<>''");
        db.execSQL("CREATE INDEX images_point_created ON images(point_id,created)");
    }
    private void upgradeV3(SQLiteDatabase db) {
        db.execSQL("ALTER TABLE points ADD COLUMN locale TEXT NOT NULL DEFAULT 'zh-CN'");
        db.execSQL("ALTER TABLE points ADD COLUMN analysis TEXT NOT NULL DEFAULT ''");
    }
    private void upgradeV2(SQLiteDatabase db) {
        String[] columns={"summary TEXT NOT NULL DEFAULT ''","machine TEXT NOT NULL DEFAULT ''","speaker TEXT NOT NULL DEFAULT ''","voice TEXT NOT NULL DEFAULT '未标注'","domain TEXT NOT NULL DEFAULT ''","topic TEXT NOT NULL DEFAULT ''","project TEXT NOT NULL DEFAULT ''","expression TEXT NOT NULL DEFAULT ''","manual TEXT NOT NULL DEFAULT ''","embedding TEXT NOT NULL DEFAULT ''","revision INTEGER NOT NULL DEFAULT 1","edited INTEGER NOT NULL DEFAULT 0","trashed INTEGER NOT NULL DEFAULT 0","viewed INTEGER NOT NULL DEFAULT 0"};
        for(String column:columns) db.execSQL("ALTER TABLE points ADD COLUMN "+column);
        db.execSQL("CREATE TABLE candidates(id TEXT PRIMARY KEY,point_id TEXT NOT NULL,engine TEXT NOT NULL,text TEXT NOT NULL,created INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE conversation(id TEXT PRIMARY KEY,point_id TEXT NOT NULL,role TEXT NOT NULL,text TEXT NOT NULL,model TEXT NOT NULL,created INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE images(id TEXT PRIMARY KEY,point_id TEXT NOT NULL,path TEXT NOT NULL,caption TEXT NOT NULL DEFAULT '',model TEXT NOT NULL DEFAULT '',created INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE relations(source TEXT NOT NULL,target TEXT NOT NULL,type TEXT NOT NULL,PRIMARY KEY(source,target))");
        db.execSQL("CREATE TABLE feedback(point_id TEXT PRIMARY KEY,value TEXT NOT NULL,created INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE reviews(scope TEXT PRIMARY KEY,score INTEGER NOT NULL,notes TEXT NOT NULL,created INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE tombstones(id TEXT PRIMARY KEY)");
        db.execSQL("CREATE TABLE snapshots(point_id TEXT NOT NULL,revision INTEGER NOT NULL,manifest TEXT NOT NULL,PRIMARY KEY(point_id,revision))");
    }
    String createText(String title, String body) {
        String id = UUID.randomUUID().toString();
        ContentValues values = content(id, title, body, System.currentTimeMillis());
        getWritableDatabase().insertOrThrow("points", null, values);
        return id;
    }
    private ContentValues content(String id, String title, String body, long created) {
        ContentValues values = new ContentValues();
        values.put("id", id); values.put("title", title); values.put("body", body); values.put("created", created);
        return values;
    }
    void update(String id, String title, String body) {
        SQLiteDatabase db=getWritableDatabase();db.beginTransaction();
        try{Point before=get(id);ContentValues values=new ContentValues();values.put("title",title);values.put("body",body);values.put("edited",1);values.put("embedding","");
            if(!title.equals(before.title)){values.put("title_edited",1);values.put("title_version",before.titleVersion+1);values.put("title_source","");values.put("title_model","");}
            if(db.update("points",values,"id=?",new String[]{id})!=1)throw new IllegalStateException("记录已不存在");
            refreshSpeechTitle(id);bump(id);db.setTransactionSuccessful();
        }finally{db.endTransaction();}
    }
    private void refreshSpeechTitle(String id) {
        Point point=get(id);if(point.path==null||point.titleEdited!=0||point.effective().trim().isEmpty())return;
        String source=TitleGeneration.signature(point);if(source.equals(point.titleSource))return;
        ContentValues values=new ContentValues();values.put("title",TitleGeneration.excerpt(point.effective()));values.put("title_source",source);values.put("title_model","transcript-excerpt");values.put("title_version",point.titleVersion+1);
        getWritableDatabase().update("points",values,"id=?",new String[]{id});
    }
    boolean autoTitle(Point expected,String title,String model,boolean force) {
        SQLiteDatabase db=getWritableDatabase();db.beginTransaction();
        try{Point current;try{current=get(expected.id);}catch(IllegalStateException gone){return false;}
            if(current.trashed!=0||current.titleVersion!=expected.titleVersion||(!force&&current.titleEdited!=0)||!TitleGeneration.signature(current).equals(TitleGeneration.signature(expected)))return false;
            ContentValues values=new ContentValues();values.put("title",title);values.put("title_source",TitleGeneration.signature(current));values.put("title_model",model);values.put("title_edited",0);values.put("title_version",current.titleVersion+1);
            db.update("points",values,"id=?",new String[]{current.id});bump(current.id);db.setTransactionSuccessful();return true;
        }finally{db.endTransaction();}
    }
    List<Point> list(String query) { return list(query,false); }
    List<Point> list(String query,boolean trash) {
        List<Point> result = new ArrayList<>();
        // instr treats %, _ and quotes literally; query values never become SQL.
        try (Cursor c = getReadableDatabase().query("points", new String[]{"*", "coalesce((SELECT group_concat(caption,char(10)||char(10)) FROM images WHERE point_id=points.id AND caption<>''),'') AS image_context"},
                "trashed"+(trash?">0":"=0")+" AND (instr(lower(title),lower(?))>0 OR instr(lower(body || machine || summary),lower(?))>0 OR EXISTS (SELECT 1 FROM images WHERE point_id=points.id AND instr(lower(caption),lower(?))>0))",
                new String[]{query, query, query}, null, null, "created DESC, id DESC")) {
            while (c.moveToNext()) {
                Point p = new Point(); p.id=c.getString(c.getColumnIndexOrThrow("id"));
                p.titleEdited=c.getInt(c.getColumnIndexOrThrow("title_edited"));p.titleVersion=c.getInt(c.getColumnIndexOrThrow("title_version"));p.titleSource=str(c,"title_source");p.titleModel=str(c,"title_model");p.title=c.getString(c.getColumnIndexOrThrow("title")); p.body=c.getString(c.getColumnIndexOrThrow("body"));
                p.path=c.getString(c.getColumnIndexOrThrow("audio_path")); p.created=c.getLong(c.getColumnIndexOrThrow("created"));
                p.duration=c.getLong(c.getColumnIndexOrThrow("duration"));
                p.imageContext=str(c,"image_context");p.locale=str(c,"locale");p.analysis=str(c,"analysis");p.summary=str(c,"summary"); p.machine=str(c,"machine"); p.speaker=str(c,"speaker");p.voice=str(c,"voice");
                p.domain=str(c,"domain");p.topic=str(c,"topic");p.project=str(c,"project");p.expression=str(c,"expression");p.manual=str(c,"manual");p.embedding=str(c,"embedding");
                p.revision=c.getInt(c.getColumnIndexOrThrow("revision")); p.edited=c.getInt(c.getColumnIndexOrThrow("edited"));
                p.trashed=c.getLong(c.getColumnIndexOrThrow("trashed"));p.viewed=c.getLong(c.getColumnIndexOrThrow("viewed"));result.add(p);
            }
        }
        return result;
    }
    File newRecording() { return new File(staging, UUID.randomUUID() + ".m4a"); }
    void commitAudio(File source) throws Exception {
        long duration;
        MediaMetadataRetriever metadata = new MediaMetadataRetriever();
        try {
            metadata.setDataSource(source.getAbsolutePath());
            String value = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
            duration = value == null ? 0 : Long.parseLong(value);
            if (duration <= 0) throw new IOException("录音过短或文件不完整");
        } finally { metadata.release(); }
        String id = source.getName().replaceFirst("\\.m4a$", "");
        UUID.fromString(id);
        long created = source.lastModified();
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(source)) {
            byte[] buffer=new byte[8192]; int count;
            while ((count=in.read(buffer))!=-1) digest.update(buffer,0,count);
        }
        StringBuilder hash=new StringBuilder(); for (byte b:digest.digest()) hash.append(String.format(Locale.ROOT,"%02x",b & 255));
        try (RandomAccessFile file = new RandomAccessFile(source,"rw")) { file.getFD().sync(); }
        File destination = new File(audio, source.getName());
        if (!source.equals(destination)) Os.rename(source.getAbsolutePath(), destination.getAbsolutePath());
        ContentValues values=content(id,"语音想法","",created);
        values.put("audio_path",destination.getName()); values.put("duration",duration); values.put("sha256",hash.toString());
        SQLiteDatabase db=getWritableDatabase(); db.beginTransaction();
        try {
            long row=db.insertWithOnConflict("points",null,values,SQLiteDatabase.CONFLICT_IGNORE);
            if(row==-1) {
                try(Cursor existing=db.rawQuery("SELECT 1 FROM points WHERE id=?",new String[]{id})) {
                    if(!existing.moveToFirst()) throw new IOException("数据库未完成保存");
                }
            }
            db.setTransactionSuccessful();
        }
        finally { db.endTransaction(); }
    }
    /** Recover finalized recordings after process death, including file/DB commit gaps. */
    void recoverPhotoAnalysis() {
        getWritableDatabase().execSQL("UPDATE images SET analysis_state='pending' WHERE analysis_state IN ('ocr_running','vision_running')");
    }
    int recover() {
        int incomplete=0;
        Set<String> existing=new HashSet<>(); for(Point p:list("")) if(p.path!=null) existing.add(p.path);
        for(Point p:list("",true)) if(p.path!=null)existing.add(p.path);
        try(Cursor c=getReadableDatabase().rawQuery("SELECT id FROM tombstones",null)){while(c.moveToNext())existing.add(c.getString(0)+".m4a");}
        for(File directory:new File[]{audio,staging}) {
            File[] files=directory.listFiles((dir,name)->name.endsWith(".m4a"));
            if(files==null) continue;
            for(File file:files) {
                if(directory.equals(audio) && existing.contains(file.getName())) continue;
                try { commitAudio(file); } catch(Exception e) { incomplete++; }
            }
        }
        return incomplete;
    }
    private static String str(Cursor c,String key) { return c.getString(c.getColumnIndexOrThrow(key)); }
    void bump(String id) { getWritableDatabase().execSQL("UPDATE points SET revision=revision+1 WHERE id=?",new Object[]{id}); }
    Point get(String id) { for(Point p:list("")) if(p.id.equals(id)) return p; for(Point p:list("",true)) if(p.id.equals(id)) return p; throw new IllegalStateException("记录不存在"); }
    void field(String id,String column,String value) {
        if(!Arrays.asList("summary","speaker","voice","domain","topic","project","expression","manual","embedding","locale","analysis").contains(column)) throw new IllegalArgumentException();
        ContentValues values=new ContentValues();values.put(column,value);if(column.equals("analysis"))values.put("embedding","");getWritableDatabase().update("points",values,"id=?",new String[]{id});bump(id);
    }
    void trash(String id,boolean deleted) { ContentValues values=new ContentValues();values.put("trashed",deleted?System.currentTimeMillis():0);getWritableDatabase().update("points",values,"id=?",new String[]{id});bump(id); }
    void viewed(String id) { ContentValues v=new ContentValues();v.put("viewed",System.currentTimeMillis());getWritableDatabase().update("points",v,"id=?",new String[]{id}); }
    String addCandidate(String point,String engine,String text) {
        SQLiteDatabase db=getWritableDatabase();db.beginTransaction();
        try { String id=UUID.randomUUID().toString();ContentValues v=new ContentValues();v.put("id",id);v.put("point_id",point);v.put("engine",engine);v.put("text",text);v.put("created",System.currentTimeMillis());db.insertOrThrow("candidates",null,v);
            ContentValues selected=new ContentValues();selected.put("machine",text);selected.put("embedding","");db.update("points",selected,"id=?",new String[]{point});refreshSpeechTitle(point);bump(point);db.setTransactionSuccessful();return id;
        } finally { db.endTransaction(); }
    }
    void selectCandidate(String point,String text) {
        SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{ContentValues values=new ContentValues();values.put("machine",text);values.put("embedding","");db.update("points",values,"id=?",new String[]{point});refreshSpeechTitle(point);bump(point);db.setTransactionSuccessful();}finally{db.endTransaction();}
    }
    org.json.JSONArray rows(String table,String point) {
        if(!Arrays.asList("candidates","conversation","images","manifestations").contains(table)) throw new IllegalArgumentException();
        org.json.JSONArray result=new org.json.JSONArray();
        try(Cursor c=getReadableDatabase().query(table,null,"point_id=?",new String[]{point},null,null,"created ASC,rowid ASC")) {
            while(c.moveToNext()) {org.json.JSONObject row=new org.json.JSONObject();for(int i=0;i<c.getColumnCount();i++) try {row.put(c.getColumnName(i),c.getType(i)==Cursor.FIELD_TYPE_INTEGER?c.getLong(i):c.getString(i));} catch(org.json.JSONException e){throw new IllegalStateException(e);} result.put(row);}
        }return result;
    }
    String message(String point,String role,String text,String model) {
        String id=UUID.randomUUID().toString();ContentValues v=new ContentValues();v.put("id",id);v.put("point_id",point);v.put("role",role);v.put("text",text);v.put("model",model);v.put("created",System.currentTimeMillis());getWritableDatabase().insertOrThrow("conversation",null,v);bump(point);return id;
    }
    final File imageDirectory() { File dir=new File(audio.getParentFile(),"images");if(!dir.exists()&&!dir.mkdirs())throw new IllegalStateException("无法创建图片目录");return dir; }
    File addImage(String point,byte[] bytes,String model) throws Exception {
        if(bytes.length>16*1024*1024)throw new IOException("图片超过 16 MB");
        String id=UUID.randomUUID().toString();File temp=new File(imageDirectory(),id+".tmp"),file=new File(imageDirectory(),id+".jpg");
        try(FileOutputStream out=new FileOutputStream(temp)){out.write(bytes);out.getFD().sync();}Os.rename(temp.getAbsolutePath(),file.getAbsolutePath());
        ContentValues v=new ContentValues();v.put("id",id);v.put("point_id",point);v.put("path",file.getName());v.put("model",model);v.put("created",System.currentTimeMillis());getWritableDatabase().insertOrThrow("images",null,v);bump(point);return file;
    }
    org.json.JSONObject image(String id) {
        try (Cursor c=getReadableDatabase().query("images",null,"id=?",new String[]{id},null,null,null)) {
            if(!c.moveToFirst()) return null;
            org.json.JSONObject row=new org.json.JSONObject();
            for(int i=0;i<c.getColumnCount();i++) try {row.put(c.getColumnName(i),c.getType(i)==Cursor.FIELD_TYPE_INTEGER?c.getLong(i):c.getString(i));}catch(org.json.JSONException e){throw new IllegalStateException(e);}
            return row;
        }
    }
    void imageCaption(String id,String text) {
        SQLiteDatabase db=getWritableDatabase();db.beginTransaction();
        try {org.json.JSONObject row=image(id);if(row==null)return;
            ContentValues values=new ContentValues();values.put("caption",text);values.put("caption_edited",1);
            db.update("images",values,"id=?",new String[]{id});invalidatePhotoContext(row.optString("point_id"));db.setTransactionSuccessful();
        }finally{db.endTransaction();}
    }
    void imageAnalysis(String id,ContentValues values) {
        SQLiteDatabase db=getWritableDatabase();db.beginTransaction();
        try {org.json.JSONObject row=image(id);if(row==null)return;
            String ocr=values.containsKey("ocr_text")?values.getAsString("ocr_text"):row.optString("ocr_text");
            String visual=values.containsKey("visual_text")?values.getAsString("visual_text"):row.optString("visual_text");
            String merged=visual.isEmpty()?ocr:visual+(ocr.isEmpty()?"":"\n\n图片文字：\n"+ocr);
            boolean changed=row.optInt("caption_edited")==0&&!merged.equals(row.optString("caption"));
            if(changed)values.put("caption",merged);
            db.update("images",values,"id=?",new String[]{id});
            if(changed)invalidatePhotoContext(row.optString("point_id"));
            db.setTransactionSuccessful();
        }finally{db.endTransaction();}
    }
    private void invalidatePhotoContext(String point) {
        getWritableDatabase().execSQL("UPDATE points SET embedding='',revision=revision+1 WHERE id=?",new Object[]{point});
    }
    List<String> pendingPhotoPoints(boolean cloud) {
        List<String> ids=new ArrayList<>();
        try(Cursor c=getReadableDatabase().rawQuery("SELECT DISTINCT images.point_id FROM images JOIN points ON points.id=images.point_id WHERE points.trashed=0 AND (analysis_state='pending'"+(cloud?" OR analysis_state='waiting_cloud'":"")+")",null)){while(c.moveToNext())ids.add(c.getString(0));}
        return ids;
    }
    void saveEmbedding(String point,int revision,String embedding) {
        getWritableDatabase().execSQL("UPDATE points SET embedding=?,revision=revision+1 WHERE id=? AND revision=?",new Object[]{embedding,point,revision});
    }
    void feedback(String point,String value) {ContentValues v=new ContentValues();v.put("point_id",point);v.put("value",value);v.put("created",System.currentTimeMillis());getWritableDatabase().insertWithOnConflict("feedback",null,v,SQLiteDatabase.CONFLICT_REPLACE);}
    List<Point> memories() {
        List<Point> result=new ArrayList<>();long week=System.currentTimeMillis()-7L*86400000;
        for(Point p:list("")) if(p.created<week && p.viewed<week) {
            try(Cursor c=getReadableDatabase().rawQuery("SELECT value,created FROM feedback WHERE point_id=?",new String[]{p.id})) {
                if(c.moveToFirst() && (c.getString(0).equals("不相关") || c.getLong(1)>System.currentTimeMillis()-86400000))continue;
            }result.add(p);if(result.size()==4)break;
        }return result;
    }
    void relation(String source,String target,String type) {if(source.equals(target))return;ContentValues v=new ContentValues();v.put("source",source);v.put("target",target);v.put("type",type);getWritableDatabase().insertWithOnConflict("relations",null,v,SQLiteDatabase.CONFLICT_REPLACE);bump(source);}
    void review(String scope,int score,String notes) {ContentValues v=new ContentValues();v.put("scope",scope);v.put("score",score);v.put("notes",notes);v.put("created",System.currentTimeMillis());getWritableDatabase().insertWithOnConflict("reviews",null,v,SQLiteDatabase.CONFLICT_REPLACE);}
    String snapshotCache(String id,int revision) {try(Cursor c=getReadableDatabase().rawQuery("SELECT manifest FROM snapshots WHERE point_id=? AND revision=?",new String[]{id,Integer.toString(revision)})){return c.moveToFirst()?c.getString(0):null;}}
    void cacheSnapshot(String id,int revision,String manifest) {ContentValues v=new ContentValues();v.put("point_id",id);v.put("revision",revision);v.put("manifest",manifest);getWritableDatabase().insertWithOnConflict("snapshots",null,v,SQLiteDatabase.CONFLICT_IGNORE);}
    void purge(String id) {
        Point p=get(id);if(p.trashed==0)throw new IllegalStateException("请先移入回收站");
        // Delete the DB references first; unreferenced files are kept if cleanup is interrupted.
        org.json.JSONArray images=rows("images",id);SQLiteDatabase db=getWritableDatabase();db.beginTransaction();
        try {ContentValues tombstone=new ContentValues();tombstone.put("id",id);db.insertWithOnConflict("tombstones",null,tombstone,SQLiteDatabase.CONFLICT_IGNORE);for(String table:new String[]{"candidates","conversation","images","snapshots","feedback","manifestations"})db.delete(table,"point_id=?",new String[]{id});db.delete("relations","source=? OR target=?",new String[]{id,id});db.delete("points","id=?",new String[]{id});db.setTransactionSuccessful();}finally{db.endTransaction();}
        if(p.path!=null)audioFile(p).delete();for(int i=0;i<images.length();i++)new File(imageDirectory(),images.optJSONObject(i).optString("path")).delete();
    }
    File audioFile(Point p) { return new File(audio,p.path); }
}
