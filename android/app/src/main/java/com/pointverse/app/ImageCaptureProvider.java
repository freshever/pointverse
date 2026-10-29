package com.pointverse.app;
import android.content.*;import android.database.Cursor;import android.net.Uri;import android.os.ParcelFileDescriptor;import java.io.*;
public final class ImageCaptureProvider extends ContentProvider{
    public boolean onCreate(){return true;}
    public ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException{String name=uri.getLastPathSegment();if(name==null||!name.matches("[a-fA-F0-9-]{36}\\.jpg"))throw new FileNotFoundException();File dir=new File(getContext().getCacheDir(),"camera");dir.mkdirs();return ParcelFileDescriptor.open(new File(dir,name),mode.contains("w")?ParcelFileDescriptor.MODE_WRITE_ONLY|ParcelFileDescriptor.MODE_CREATE|ParcelFileDescriptor.MODE_TRUNCATE:ParcelFileDescriptor.MODE_READ_ONLY);}
    public String getType(Uri u){return "image/jpeg";}public Cursor query(Uri u,String[] p,String s,String[] a,String o){return null;}public Uri insert(Uri u,ContentValues v){throw new UnsupportedOperationException();}public int update(Uri u,ContentValues v,String s,String[] a){throw new UnsupportedOperationException();}public int delete(Uri u,String s,String[] a){return 0;}
}
