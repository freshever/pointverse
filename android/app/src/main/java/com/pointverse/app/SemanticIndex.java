package com.pointverse.app;
import android.content.Context;
import org.json.*;
import java.util.*;
import java.io.*;
final class SemanticIndex {
    final JSONArray terms;
    SemanticIndex(Context context)throws Exception{try(InputStream input=context.getAssets().open("facets.json")){ByteArrayOutputStream bytes=new ByteArrayOutputStream();byte[] buffer=new byte[8192];int n;while((n=input.read(buffer))!=-1)bytes.write(buffer,0,n);terms=new JSONArray(bytes.toString("UTF-8"));}}
    String value(PointStore.Point p,String dimension){String saved="";switch(dimension){case "domain":saved=p.domain;break;case "topic":saved=p.topic;break;case "project":saved=p.project;break;case "expression":saved=p.expression;break;}
        if(!saved.isEmpty()||Arrays.asList(p.manual.split(",")).contains(dimension))return saved;
        String text=(p.title+" "+p.context()).toLowerCase(Locale.ROOT),best="";int score=0;
        for(int i=0;i<terms.length();i++){JSONObject term=terms.optJSONObject(i);if(!dimension.equals(term.optString("dimension")))continue;JSONArray words=term.optJSONArray("keywords");int count=0;for(int j=0;j<words.length();j++)if(text.contains(words.optString(j).toLowerCase(Locale.ROOT)))count++;if(count>score){score=count;best=term.optString("title");}}
        return best;
    }
    List<PointStore.Point> related(PointStore.Point source,List<PointStore.Point> all){List<PointStore.Point> result=new ArrayList<>();for(PointStore.Point p:all)if(!p.id.equals(source.id))result.add(p);result.sort((a,b)->Double.compare(score(source,b),score(source,a)));return result.subList(0,Math.min(8,result.size()));}
    double score(PointStore.Point a,PointStore.Point b){if(!a.embedding.isEmpty()&&!b.embedding.isEmpty())try{JSONArray x=new JSONArray(a.embedding),y=new JSONArray(b.embedding);if(x.length()!=y.length())return 0;double product=0,left=0,right=0;for(int i=0;i<x.length();i++){double l=x.getDouble(i),r=y.getDouble(i);product+=l*r;left+=l*l;right+=r*r;}return left>0&&right>0?product/Math.sqrt(left*right):0;}catch(Exception ignored){}
        Set<String> x=grams(a.context()),y=grams(b.context());int total=x.size()+y.size();x.retainAll(y);return total>0?2.0*x.size()/total:0;
    }
    private Set<String> grams(String text){Set<String> values=new HashSet<>();text=text.toLowerCase(Locale.ROOT).replaceAll("\\s+","");for(int i=0;i+1<text.length();i++)values.add(text.substring(i,i+2));return values;}
}
