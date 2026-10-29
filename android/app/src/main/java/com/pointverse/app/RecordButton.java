package com.pointverse.app;
import android.content.Context;import android.graphics.*;import android.widget.Button;
/** Same control states as iOS CaptureView: viewfinder, stop, and a circular fill. */
final class RecordButton extends Button{
    private final Paint paint=new Paint(3);private final Path corners=new Path();
    RecordButton(Context context){super(context);setMinHeight(0);setMinWidth(0);}
    protected void onDraw(Canvas canvas){
        float cx=getWidth()/2f,cy=getHeight()/2f,r=getWidth()*.18f;
        paint.setColor(Color.WHITE);paint.setStrokeWidth(getWidth()*.04f);paint.setStyle(Paint.Style.STROKE);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);
        if(getText().toString().equals("■")){paint.setStyle(Paint.Style.FILL);float edge=r*.75f;canvas.drawRoundRect(cx-edge,cy-edge,cx+edge,cy+edge,getWidth()*.014f,getWidth()*.014f,paint);return;}
        float length=r*.55f,radius=r*.3f;corners.reset();
        for(int x:new int[]{-1,1})for(int y:new int[]{-1,1}){
            corners.moveTo(cx+x*(r-length),cy+y*r);corners.lineTo(cx+x*(r-radius),cy+y*r);
            corners.quadTo(cx+x*r,cy+y*r,cx+x*r,cy+y*(r-radius));corners.lineTo(cx+x*r,cy+y*(r-length));
        }
        canvas.drawPath(corners,paint);
    }
}
