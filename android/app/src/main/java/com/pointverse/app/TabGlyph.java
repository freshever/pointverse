package com.pointverse.app;
import android.content.Context;import android.graphics.*;import android.view.View;
final class TabGlyph extends View{
    private final int type,color;private final Paint p=new Paint(3);
    TabGlyph(Context c,int type,int color){super(c);this.type=type;this.color=color;}
    protected void onDraw(Canvas c){super.onDraw(c);c.save();c.scale(getWidth()/28f,getHeight()/28f);p.setColor(color);p.setStrokeWidth(1.6f);p.setStyle(Paint.Style.STROKE);p.setStrokeCap(Paint.Cap.ROUND);
        switch(type){case 0:c.drawCircle(14,14,11,p);for(int i=0;i<5;i++){float height=new int[]{3,6,8,5,2}[i];c.drawLine(7+i*3,14-height,7+i*3,14+height,p);}break;
        case 1:p.setStyle(Paint.Style.FILL);for(int x=0;x<2;x++)for(int y=0;y<2;y++)c.drawRoundRect(4+x*12,4+y*12,12+x*12,12+y*12,2,2,p);break;
        case 2:c.drawOval(2,8,26,20,p);c.save();c.rotate(60,14,14);c.drawOval(2,8,26,20,p);c.restore();c.save();c.rotate(-60,14,14);c.drawOval(2,8,26,20,p);c.restore();p.setStyle(Paint.Style.FILL);c.drawCircle(14,14,2,p);break;
        case 3:c.drawRoundRect(3,5,25,23,3,3,p);c.drawCircle(19,10,2,p);Path path=new Path();path.moveTo(4,22);path.lineTo(11,13);path.lineTo(16,19);path.lineTo(20,15);path.lineTo(25,21);c.drawPath(path,p);break;
        case 4:c.drawCircle(14,14,11,p);c.drawCircle(14,10,3.5f,p);Path person=new Path();person.moveTo(6.5f,22);person.cubicTo(7,14,21,14,21.5f,22);c.drawPath(person,p);break;
        }c.restore();}
}
