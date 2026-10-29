package com.pointverse.app;
import android.content.Context;import android.graphics.*;import android.view.*;
final class DoodleCanvas extends View{
    private final Paint paint=new Paint(3);private final Path path=new Path();
    DoodleCanvas(Context c){super(c);setMinimumHeight(850);paint.setColor(0xff222222);paint.setStrokeWidth(6);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);paint.setStyle(Paint.Style.STROKE);setBackgroundColor(Color.WHITE);}
    protected void onDraw(Canvas c){super.onDraw(c);c.drawPath(path,paint);}
    public boolean onTouchEvent(MotionEvent e){if(e.getAction()==MotionEvent.ACTION_DOWN)path.moveTo(e.getX(),e.getY());else if(e.getAction()==MotionEvent.ACTION_MOVE)path.lineTo(e.getX(),e.getY());invalidate();return true;}
    void clear(){path.reset();invalidate();}
    Bitmap result(){Bitmap b=Bitmap.createBitmap(Math.max(1,getWidth()),Math.max(1,getHeight()),Bitmap.Config.ARGB_8888);Canvas c=new Canvas(b);draw(c);return b;}
}
