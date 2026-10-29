package com.pointverse.app;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;

/** Only a verified immutable APK can be shared, read-only, with the system installer. */
public final class UpdatePackageProvider extends ContentProvider {
    public boolean onCreate(){return true;}
    static Uri uri(Context context,File file){return Uri.parse("content://"+context.getPackageName()+".updates/apk/"+file.getName());}
    private File file(Uri uri)throws FileNotFoundException {
        String name=uri.getLastPathSegment();
        if(!"content".equals(uri.getScheme())||!(getContext().getPackageName()+".updates").equals(uri.getAuthority())
                ||uri.getPathSegments().size()!=2||!"apk".equals(uri.getPathSegments().get(0))||name==null||!name.matches("[a-f0-9]{64}\\.apk"))throw new FileNotFoundException();
        File file=new File(AppUpdater.directory(getContext()),name);if(!file.isFile())throw new FileNotFoundException();return file;
    }
    public ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException {
        if(!"r".equals(mode))throw new FileNotFoundException("安装包只读");return ParcelFileDescriptor.open(file(uri),ParcelFileDescriptor.MODE_READ_ONLY);
    }
    public String getType(Uri uri){return "application/vnd.android.package-archive";}
    public Cursor query(Uri uri,String[] projection,String selection,String[] args,String order) {
        try {
            File file=file(uri);String[] columns=projection==null?new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE}:projection;
            MatrixCursor cursor=new MatrixCursor(columns,1);Object[] row=new Object[columns.length];
            for(int i=0;i<columns.length;i++)row[i]=OpenableColumns.DISPLAY_NAME.equals(columns[i])?"点界更新.apk":OpenableColumns.SIZE.equals(columns[i])?file.length():null;
            cursor.addRow(row);return cursor;
        }catch(FileNotFoundException e){return null;}
    }
    public Uri insert(Uri u,ContentValues v){throw new UnsupportedOperationException();}
    public int update(Uri u,ContentValues v,String s,String[] a){throw new UnsupportedOperationException();}
    public int delete(Uri u,String s,String[] a){throw new UnsupportedOperationException();}
}
