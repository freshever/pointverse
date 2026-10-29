package com.pointverse.app;

import org.json.*;
import java.io.*;
import java.nio.*;
import java.util.*;

/** Same bounded, model-free acoustic measurements as iOS; semantic labels come from CLAP. */
final class AudioUnderstanding {
    interface Classifier { JSONObject classify(byte[] wav)throws Exception; }
    static JSONObject analyze(File audio,String transcript,Classifier classifier)throws Exception {
        Features features=new Features();JSONObject[] cloud={null};String[] error={""};boolean[] sent={false};
        CloudTranscription.decodeBlocks(audio,30,wav->{
            if(Thread.currentThread().isInterrupted())throw new InterruptedIOException("声音理解已取消");
            features.accept(wav);
            if(!sent[0]){sent[0]=true;try{cloud[0]=classifier.classify(wav);if(cloud[0]==null||cloud[0].getJSONArray("labels").length()==0)throw new IOException("声音分类结果为空");}catch(Exception e){if(Thread.currentThread().isInterrupted())throw new InterruptedIOException("声音理解已取消");cloud[0]=null;error[0]="云端声音分类暂不可用，基础声学分析已保留，可重新理解";}}
            return "";
        });
        JSONObject value=features.finish();JSONArray tags=value.getJSONArray("tags");
        if(cloud[0]!=null){JSONArray labels=cloud[0].optJSONArray("labels");if(labels==null||labels.length()==0)throw new IOException("云端声音分类结果为空");value.put("labels",labels).put("cloud_model",cloud[0].optString("model","CLAP")).put("scores_relative",true);tags.put("候选："+label(labels.getJSONObject(0).getString("label")));}
        value.put("cloud_error",error[0]).put("has_voice",!transcript.trim().isEmpty()).put("lyrics",transcript).put("version",1).put("sample_seconds",Math.min(30,features.samples/16000.0));
        if(!transcript.trim().isEmpty())tags.put("已有转写");
        String semantic="声音特征："+join(tags," · ")+"；响度 "+String.format(Locale.ROOT,"%.1f dBFS",value.getDouble("loudness_db"));
        if(value.has("bpm"))semantic+="；估计节奏 "+Math.round(value.getDouble("bpm"))+" BPM";
        if(value.has("key"))semantic+="；估计调性 "+value.getString("key");
        value.put("semantic_text",semantic).put("measured_at",System.currentTimeMillis());return value;
    }
    static String label(String label){String[] en={"human speech","music","applause","rain","a dog barking","a cat meowing","road traffic","birds singing","wind","a door closing","keyboard typing","silence"};String[] zh={"人声讲话","音乐","掌声","雨声","狗叫","猫叫","道路交通","鸟鸣","风声","关门声","键盘声","安静／静音"};for(int i=0;i<en.length;i++)if(en[i].equals(label))return zh[i];return label;}
    static String join(JSONArray values,String separator){List<String> text=new ArrayList<>();for(int i=0;i<values.length();i++)text.add(values.optString(i));return String.join(separator,text);}
    static String context(String raw){if(raw==null||raw.isEmpty())return "";try{return new JSONObject(raw).optString("semantic_text");}catch(JSONException e){return "";}}
    static final class Features {
        long samples;double energy,envelopeEnergy;int envelopeCount,parity;final ArrayList<Double> envelope=new ArrayList<>();final ArrayList<Float> pitch=new ArrayList<>();
        void accept(byte[] wav)throws IOException {if(wav.length<44)throw new IOException("音频数据无效");ByteBuffer b=ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN);b.position(44);while(b.remaining()>=2){double x=b.getShort()/32768.0;samples++;energy+=x*x;envelopeEnergy+=x*x;envelopeCount++;if(envelopeCount==160){if(envelope.size()<30000)envelope.add(Math.sqrt(envelopeEnergy/160));envelopeCount=0;envelopeEnergy=0;}if(parity++%2==0&&pitch.size()<160000)pitch.add((float)x);}}
        JSONObject finish()throws Exception {
            if(samples==0)throw new IOException("录音为空");double db=20*Math.log10(Math.max(0.000001,Math.sqrt(energy/samples)));double[] tempo=tempo();JSONObject out=new JSONObject().put("duration_seconds",samples/16000.0).put("loudness_db",db).put("rhythm_strength",tempo[1]);JSONArray tags=new JSONArray().put(db> -18?"响亮":db< -42?"安静":"中等响度");tags.put(tempo[1]>.18?"节奏明显":"节奏不明显");if(tempo[0]>0)out.put("bpm",tempo[0]);out.put("tags",tags);notes(out);return out;
        }
        double[] tempo(){if(envelope.size()<=300)return new double[]{0,0};double mean=0,total=0;for(double x:envelope)mean+=x;mean/=envelope.size();double[] x=new double[envelope.size()];for(int i=0;i<x.length;i++){x[i]=envelope.get(i)-mean;total+=x[i]*x[i];}if(total<1e-6)return new double[]{0,0};double best=0;int lagBest=0;for(int lag=30;lag<=150;lag++){double score=0;for(int i=lag;i<x.length;i++)score+=x[i]*x[i-lag];score/=total;if(score>best){best=score;lagBest=lag;}}return new double[]{best>.08?6000.0/lagBest:0,Math.min(1,best)};}
        void notes(JSONObject out)throws Exception {
            int[] counts=new int[128];double[] frequencies=new double[128];ArrayList<Integer> frames=new ArrayList<>();
            for(int start=0;start+1024<=pitch.size();start+=512){if(Thread.currentThread().isInterrupted())throw new InterruptedIOException("声音理解已取消");double rms=0;for(int i=0;i<1024;i++)rms+=pitch.get(start+i)*pitch.get(start+i);int midi=-1;
                if(Math.sqrt(rms/1024)>.012){double best=0;int bestLag=0;double[] correlations=new double[146];for(int lag=8;lag<=145;lag++){double cross=0,left=0,right=0;for(int i=0;i<1024-lag;i++){double a=pitch.get(start+i),b=pitch.get(start+i+lag);cross+=a*b;left+=a*a;right+=b*b;}double score=cross/Math.sqrt(Math.max(1e-7,left*right));correlations[lag]=score;if(score>best){best=score;bestLag=lag;}}for(int lag=9;lag<145;lag++)if(correlations[lag]>=Math.max(.72,best*.95)&&correlations[lag]>correlations[lag-1]&&correlations[lag]>=correlations[lag+1]){bestLag=lag;break;}if(best>.72){double offset=0;if(bestLag>8&&bestLag<145){double denominator=correlations[bestLag-1]-2*correlations[bestLag]+correlations[bestLag+1];if(Math.abs(denominator)>1e-9)offset=Math.max(-.5,Math.min(.5,.5*(correlations[bestLag-1]-correlations[bestLag+1])/denominator));}double hz=8000.0/(bestLag+offset);midi=(int)Math.round(69+12*Math.log(hz/440)/Math.log(2));if(midi>=24&&midi<=108){counts[midi]++;frequencies[midi]+=hz;}else midi=-1;}}
                frames.add(midi);
            }
            int dominant=0;for(int i=1;i<128;i++)if(counts[i]>counts[dominant])dominant=i;JSONArray notes=new JSONArray(),sequence=new JSONArray();
            if(counts[dominant]>0){out.put("dominant_pitch_hz",frequencies[dominant]/counts[dominant]);Set<Integer> seen=new HashSet<>();for(int midi:frames)if(midi>=0&&counts[midi]>=Math.max(2,counts[dominant]/5)&&seen.add(midi)&&notes.length()<12)notes.put(note(midi));
                ArrayList<Integer> smooth=new ArrayList<>(frames);for(int i=1;i<frames.size()-1;i++){ArrayList<Integer> v=new ArrayList<>();for(int j=i-1;j<=i+1;j++)if(frames.get(j)>=0)v.add(frames.get(j));Collections.sort(v);if(v.size()>=2)smooth.set(i,v.get(v.size()/2));}
                int current=-1,start=0;for(int i=0;i<=smooth.size();i++){int next=i==smooth.size()?-1:smooth.get(i);if(current!=next){double duration=(i-start)*.064;if(current>=0&&duration>=.12&&sequence.length()<64)sequence.put(new JSONObject().put("note",note(current)).put("midi",current).put("start_seconds",start*.064).put("duration_seconds",duration));current=next;start=i;}}
                if(notes.length()>0){out.getJSONArray("tags").put("有调性");Set<Integer> classes=new HashSet<>();for(int n=0;n<128;n++)if(counts[n]>=2)classes.add(n%12);if(classes.size()>=3)out.put("key",key(counts));}
            }
            out.put("notes",notes).put("note_sequence",sequence);
        }
        static String note(int midi){return new String[]{"C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"}[midi%12]+(midi/12-1);}
        static String key(int[] counts){double[][] profiles={{6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88},{6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17}};double best=-1;int root=0,mode=0;for(int r=0;r<12;r++)for(int m=0;m<2;m++){double score=0;for(int n=0;n<128;n++)score+=counts[n]*profiles[m][(n%12-r+12)%12];if(score>best){best=score;root=r;mode=m;}}return note(root+60).replace("4","")+(mode==0?" 大调":" 小调");}
    }
}
