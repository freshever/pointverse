package com.pointverse.app;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.media.ExifInterface;
import java.io.*;

/** Apply JPEG orientation without rewriting or discarding the captured original. */
final class PhotoDecoder {
    private interface Source { InputStream open() throws IOException; }
    static Bitmap fromBytes(byte[] bytes, int maxEdge) throws IOException {
        return decode(() -> new ByteArrayInputStream(bytes), maxEdge);
    }
    static Bitmap fromFile(File file, int maxEdge) throws IOException {
        return decode(() -> new FileInputStream(file), maxEdge);
    }
    private static Bitmap decode(Source source, int maxEdge) throws IOException {
        BitmapFactory.Options bounds = new BitmapFactory.Options(); bounds.inJustDecodeBounds = true;
        try (InputStream input = source.open()) { BitmapFactory.decodeStream(input, null, bounds); }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw new IOException("无法读取图片");
        BitmapFactory.Options options = new BitmapFactory.Options(); options.inSampleSize = 1;
        while (Math.max(bounds.outWidth, bounds.outHeight) / options.inSampleSize > maxEdge)
            options.inSampleSize *= 2;
        Bitmap image;
        try (InputStream input = source.open()) { image = BitmapFactory.decodeStream(input, null, options); }
        if (image == null) throw new IOException("无法读取图片");
        int orientation = ExifInterface.ORIENTATION_NORMAL;
        try (InputStream input = source.open()) {
            orientation = new ExifInterface(input).getAttributeInt(ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL);
        } catch (IOException ignored) { }
        Matrix matrix = new Matrix();
        switch (orientation) {
            case ExifInterface.ORIENTATION_FLIP_HORIZONTAL: matrix.setScale(-1, 1); break;
            case ExifInterface.ORIENTATION_ROTATE_180: matrix.setRotate(180); break;
            case ExifInterface.ORIENTATION_FLIP_VERTICAL: matrix.setScale(1, -1); break;
            case ExifInterface.ORIENTATION_TRANSPOSE: matrix.setRotate(90); matrix.postScale(-1, 1); break;
            case ExifInterface.ORIENTATION_ROTATE_90: matrix.setRotate(90); break;
            case ExifInterface.ORIENTATION_TRANSVERSE: matrix.setRotate(270); matrix.postScale(-1, 1); break;
            case ExifInterface.ORIENTATION_ROTATE_270: matrix.setRotate(270); break;
        }
        if (!matrix.isIdentity()) {
            Bitmap upright = Bitmap.createBitmap(image, 0, 0, image.getWidth(), image.getHeight(), matrix, true);
            if (upright != image) image.recycle();
            return upright;
        }
        return image;
    }
}
