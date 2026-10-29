package com.pointverse.app;

import android.media.MediaRecorder;
import java.io.File;
import java.io.IOException;

final class AudioCapture {
    private MediaRecorder recorder;
    private File file;
    boolean isRecording() { return recorder != null; }
    @SuppressWarnings("deprecation")
    void start(File target, Runnable limitReached) throws IOException {
        MediaRecorder candidate=new MediaRecorder();
        try {
            candidate.setAudioSource(MediaRecorder.AudioSource.MIC);
            candidate.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            candidate.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            candidate.setAudioSamplingRate(24000); candidate.setAudioChannels(1); candidate.setAudioEncodingBitRate(64000);
            candidate.setMaxDuration(10*60*1000);
            candidate.setOutputFile(target.getAbsolutePath());
            candidate.setOnInfoListener((r,what,extra)-> { if(what==MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) limitReached.run(); });
            candidate.setOnErrorListener((r,what,extra)->limitReached.run());
            candidate.prepare(); candidate.start(); recorder=candidate; file=target;
        } catch(IOException | RuntimeException e) { candidate.release(); target.delete(); throw e; }
    }
    File finish() throws IOException {
        if(recorder==null) throw new IOException("没有正在进行的录音");
        MediaRecorder current=recorder; recorder=null;
        File result=file; file=null;
        try { current.stop(); return result; }
        catch(RuntimeException e) { result.delete(); throw new IOException("录音过短或被中断，请重试",e); }
        finally { current.release(); }
    }
    void cancel() {
        if(recorder==null) return;
        File discarded=file;
        try { finish(); } catch(IOException ignored) { }
        discarded.delete();
    }
}
