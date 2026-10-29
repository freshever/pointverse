package com.pointverse.app;

import android.media.*;
import java.io.*;
import java.nio.*;

/** Decode AAC locally, submit bounded PCM16 mono 16 kHz WAV chunks, as on iOS. */
final class CloudTranscription {
    interface Submitter { String submit(byte[] wav) throws Exception; }
    static String transcribe(File audio,String token) throws Exception {
        return decode(audio,wav->NetworkModel.transcribe(token,wav));
    }
    static String decode(File audio,Submitter submitter) throws Exception { return decodeBlocks(audio,120,submitter); }
    static String decodeBlocks(File audio,int seconds,Submitter submitter) throws Exception {
        MediaExtractor extractor=new MediaExtractor(); MediaCodec decoder=null;
        try {
            extractor.setDataSource(audio.getAbsolutePath()); MediaFormat format=null;
            for(int i=0;i<extractor.getTrackCount();i++) {
                MediaFormat candidate=extractor.getTrackFormat(i);
                if(candidate.getString(MediaFormat.KEY_MIME).startsWith("audio/")) { extractor.selectTrack(i); format=candidate; break; }
            }
            if(format==null) throw new IOException("无法读取录音");
            decoder=MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME));
            format.setInteger(MediaFormat.KEY_PCM_ENCODING,AudioFormat.ENCODING_PCM_16BIT);
            decoder.configure(format,null,null,0); decoder.start();
            int rate=format.getInteger(MediaFormat.KEY_SAMPLE_RATE),channels=format.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
            int phase=0; boolean inputDone=false,outputDone=false;
            ByteArrayOutputStream pcm=new ByteArrayOutputStream(); StringBuilder result=new StringBuilder();
            MediaCodec.BufferInfo info=new MediaCodec.BufferInfo();
            long deadline=System.currentTimeMillis()+120000;
            while(!outputDone) {
                if(Thread.currentThread().isInterrupted()) throw new IOException("转写已取消");
                if(System.currentTimeMillis()>deadline) throw new IOException("音频解码超时，请重试");
                if(!inputDone) {
                    int index=decoder.dequeueInputBuffer(10000);
                    if(index>=0) {
                        ByteBuffer buffer=decoder.getInputBuffer(index); int size=extractor.readSampleData(buffer,0);
                        if(size<0) { decoder.queueInputBuffer(index,0,0,0,MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone=true; }
                        else { decoder.queueInputBuffer(index,0,size,extractor.getSampleTime(),0); extractor.advance(); }
                    }
                }
                int index=decoder.dequeueOutputBuffer(info,10000);
                if(index==MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat out=decoder.getOutputFormat(); rate=out.getInteger(MediaFormat.KEY_SAMPLE_RATE); channels=out.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
                    if(out.containsKey(MediaFormat.KEY_PCM_ENCODING) && out.getInteger(MediaFormat.KEY_PCM_ENCODING)!=AudioFormat.ENCODING_PCM_16BIT)
                        throw new IOException("设备音频解码格式暂不支持");
                } else if(index>=0) {
                    ByteBuffer buffer=decoder.getOutputBuffer(index); buffer.position(info.offset); buffer.limit(info.offset+info.size); buffer.order(ByteOrder.LITTLE_ENDIAN);
                    while(buffer.remaining()>=channels*2) {
                        int sample=0; for(int c=0;c<channels;c++) sample+=buffer.getShort(); sample/=channels;
                        phase+=16000;
                        while(phase>=rate) { pcm.write(sample & 255); pcm.write((sample>>8)&255); phase-=rate; }
                        if(pcm.size()>=16000*2*seconds) {
                            append(result,submitter.submit(wav(pcm.toByteArray()))); pcm.reset(); deadline=System.currentTimeMillis()+120000;
                        }
                    }
                    outputDone=(info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM)!=0;
                    decoder.releaseOutputBuffer(index,false);
                }
            }
            if(pcm.size()>0) append(result,submitter.submit(wav(pcm.toByteArray())));

            return result.toString();
        } finally {
            if(decoder!=null) { try { decoder.stop(); } catch(RuntimeException ignored) { } decoder.release(); }
            extractor.release();
        }
    }
    private static void append(StringBuilder result,String text) { if(!text.isEmpty()) { if(result.length()>0) result.append('\n'); result.append(text); } }
    static byte[] wav(byte[] pcm) {
        ByteBuffer out=ByteBuffer.allocate(44+pcm.length).order(ByteOrder.LITTLE_ENDIAN);
        out.put(new byte[]{'R','I','F','F'}).putInt(36+pcm.length).put(new byte[]{'W','A','V','E','f','m','t',' '});
        out.putInt(16).putShort((short)1).putShort((short)1).putInt(16000).putInt(32000).putShort((short)2).putShort((short)16);
        out.put(new byte[]{'d','a','t','a'}).putInt(pcm.length).put(pcm); return out.array();
    }
}
