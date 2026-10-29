package com.pointverse.app;

import android.media.*;
import org.json.*;
import java.util.concurrent.*;

/** Bounded synthesized preview of estimated notes; never replays the microphone. */
final class NotePlayer {
    private final ExecutorService worker=Executors.newSingleThreadExecutor();private Future<?> future;private AudioTrack track;private volatile boolean playing;private long generation;
    synchronized boolean isPlaying(){return playing;}
    synchronized void stop(){generation++;playing=false;if(future!=null)future.cancel(true);if(track!=null)try{track.pause();track.flush();}catch(IllegalStateException ignored){}}
    synchronized void play(JSONArray events,Runnable done){stop();long ticket=generation;playing=true;future=worker.submit(()->{AudioTrack audio=null;try{
        short[] samples=render(events);if(samples.length==0)return;
        audio=new AudioTrack.Builder().setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()).setAudioFormat(new AudioFormat.Builder().setSampleRate(16000).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()).setBufferSizeInBytes(Math.max(4096,AudioTrack.getMinBufferSize(16000,AudioFormat.CHANNEL_OUT_MONO,AudioFormat.ENCODING_PCM_16BIT))).setTransferMode(AudioTrack.MODE_STREAM).build();
        synchronized(this){if(Thread.currentThread().isInterrupted())return;track=audio;}audio.play();for(int offset=0;offset<samples.length&&!Thread.currentThread().isInterrupted();){int count=audio.write(samples,offset,Math.min(2048,samples.length-offset));if(count<=0)break;offset+=count;}while(!Thread.currentThread().isInterrupted()&&audio.getPlaybackHeadPosition()<samples.length)Thread.sleep(20);
    }catch(Exception ignored){}finally{synchronized(this){if(generation==ticket){track=null;playing=false;}}if(audio!=null)audio.release();done.run();}});}
    static short[] render(JSONArray events){double end=0;for(int i=0;i<Math.min(64,events.length());i++){JSONObject e=events.optJSONObject(i);if(e!=null)end=Math.max(end,Math.min(20,Math.max(0,e.optDouble("start_seconds"))+Math.min(4,Math.max(0,e.optDouble("duration_seconds")))));}short[] out=new short[(int)(end*16000)];for(int i=0;i<Math.min(64,events.length());i++){JSONObject e=events.optJSONObject(i);if(e==null)continue;int midi=e.optInt("midi",-1);if(midi<24||midi>108)continue;int start=(int)(Math.max(0,e.optDouble("start_seconds"))*16000),length=(int)(Math.min(4,Math.max(0,e.optDouble("duration_seconds")))*16000);double hz=440*Math.pow(2,(midi-69)/12.0);for(int n=0;n<length&&start+n<out.length;n++){double fade=Math.min(1,Math.min(n/160.0,(length-n)/160.0));out[start+n]=(short)(Math.sin(2*Math.PI*hz*n/16000)*6000*fade);}}return out;}
    void close(){stop();worker.shutdownNow();}
}
