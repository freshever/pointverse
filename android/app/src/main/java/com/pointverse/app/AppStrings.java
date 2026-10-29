package com.pointverse.app;
import android.content.Context;import org.json.JSONObject;import java.io.*;import java.util.Locale;
final class AppStrings{
    private final JSONObject strings;
    AppStrings(Context context){JSONObject value=new JSONObject();try{int selected=context.getSharedPreferences("pointverse",0).getInt("appLanguage",0);String[] codes={"system","zh-Hans","zh-Hant","en","ja"};String code=codes[Math.min(selected,codes.length-1)];if(code.equals("system")){Locale locale=Locale.getDefault();code=locale.getLanguage().equals("zh")?(locale.getCountry().equals("TW")||locale.getCountry().equals("HK")?"zh-Hant":"zh-Hans"):locale.getLanguage().equals("ja")?"ja":locale.getLanguage().equals("en")?"en":"zh-Hans";}try(InputStream input=context.getAssets().open("strings-"+code+".json")){ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] buffer=new byte[8192];int n;while((n=input.read(buffer))!=-1)out.write(buffer,0,n);value=new JSONObject(out.toString("UTF-8"));}}catch(Exception ignored){}strings=value;}
    String text(String key){return key.equals("点界")?"点界":strings.optString(key,key);}
}
