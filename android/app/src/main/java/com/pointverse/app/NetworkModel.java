package com.pointverse.app;

import org.json.*;
import javax.net.ssl.HttpsURLConnection;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;

/** Uses the same production account and AI endpoints as the iOS app. */
final class NetworkModel {
    static final class ServiceException extends IOException {
        final int status;final String reason;
        ServiceException(int status,String reason,String message){super(message);this.status=status;this.reason=reason;}
    }
    static ServiceException serviceError(int code,String reason,String path){
        String message="云端服务暂不可用（"+code+"），请稍后重试";
        if(code==400)message=path.contains("/images/")?"生图描述不符合要求，请精简描述后重试":"提交内容不符合服务要求，请检查后重试";
        if(code==404)message=path.contains("/jobs/")?"上次生图任务已过期或不存在，请重新生成":"云端功能暂不可用，请更新应用后重试";
        if(code==503)message="云端服务繁忙或暂不可用，请稍后重试";
        if(reason.equals("model_not_installed"))message="云端所需模型尚未就绪，请稍后重试";
        if(reason.equals("image_queue_full")||reason.equals("node_busy")||reason.equals("queue_timeout"))message="云端任务较多，请稍后重试";
        return new ServiceException(code,reason,message);
    }
    static volatile java.util.function.BooleanSupplier cloudAllowed=()->true;
    static final String SERVICE="https://dianjie.org";
    static URL endpoint(String base) throws Exception {
        URI uri=new URI(base.trim());
        if(!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost()==null || uri.getUserInfo()!=null || uri.getQuery()!=null || uri.getFragment()!=null)
            throw new IOException("请输入有效的 HTTPS 服务地址");
        return new URL(base.trim().replaceAll("/+$", "")+"/chat/completions");
    }
    static String organize(String token,String text) throws Exception {
        if(text.length()>24000) throw new IOException("单次整理最多支持 24000 字，请分段处理");
        JSONObject payload=new JSONObject().put("model","pointverse-cloud").put("stream",false).put("messages",new JSONArray()
            .put(new JSONObject().put("role","system").put("content","你是点界的想法整理助手。使用用户的语言，忠实保留原意，不编造事实。输出简短标题、摘要和下一步思考问题；仅输出纯文本。"))
            .put(new JSONObject().put("role","user").put("content",text)));
        return responseText(post(endpoint(SERVICE+"/v1/ai"),token,payload));
    }
    static JSONObject login(String email,String password) throws Exception {
        return post(new URL(SERVICE+"/v1/auth/email/login"),"",new JSONObject().put("email",email.trim()).put("password",password));
    }
    static void logout(String token) throws Exception { post(new URL(SERVICE+"/v1/auth/logout"),token,new JSONObject()); }
    static String transcribe(String token,byte[] wav) throws Exception {
        String text=post(new URL(SERVICE+"/v1/ai/audio/transcriptions"),token,new JSONObject().put("audio",android.util.Base64.encodeToString(wav,android.util.Base64.NO_WRAP))).getString("text").trim();
        return text;
    }
    static String responseText(JSONObject response) throws Exception {
        String value=response.getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content").trim();
        if(value.isEmpty()) throw new IOException("模型返回了空内容，请重试");
        return value;
    }
    static JSONObject post(URL url,String token,JSONObject payload) throws Exception { return request(url,"POST",token,payload==null?null:payload.toString().getBytes(StandardCharsets.UTF_8),"application/json; charset=utf-8"); }
    static JSONObject api(String path,String method,String token,JSONObject payload) throws Exception {
        if(!path.startsWith("/v1/")||path.contains(".."))throw new IOException("无效服务路径");
        return request(new URL(SERVICE+path),method,token,payload==null?null:payload.toString().getBytes(StandardCharsets.UTF_8),"application/json");
    }
    static JSONObject chat(String token,String model,String system,JSONArray messages) throws Exception {
        JSONArray input=new JSONArray().put(new JSONObject().put("role","system").put("content",system));
        for(int i=0;i<messages.length();i++)input.put(messages.getJSONObject(i));
        return api("/v1/ai/chat/completions","POST",token,new JSONObject().put("model",model).put("stream",false).put("messages",input));
    }
    static void upload(String token,String hash,byte[] bytes) throws Exception {
        if(!hash.matches("[a-f0-9]{64}"))throw new IOException("附件校验失败");
        request(new URL(SERVICE+"/v1/sync/assets/"+hash),"PUT",token,bytes,"application/octet-stream");
    }
    static void uploadFile(String token,String hash,File file)throws Exception{
        if(!hash.matches("[a-f0-9]{64}")||!cloudAllowed.getAsBoolean())throw new IOException("附件校验失败或云端已关闭");
        HttpsURLConnection connection=(HttpsURLConnection)new URL(SERVICE+"/v1/sync/assets/"+hash).openConnection();
        try{connection.setInstanceFollowRedirects(false);connection.setConnectTimeout(15000);connection.setReadTimeout(180000);connection.setRequestMethod("PUT");connection.setDoOutput(true);connection.setRequestProperty("Authorization","Bearer "+token);connection.setRequestProperty("Content-Type","application/octet-stream");connection.setFixedLengthStreamingMode(file.length());
            try(InputStream in=new FileInputStream(file);OutputStream out=connection.getOutputStream()){byte[] bytes=new byte[32768];int n;while((n=in.read(bytes))!=-1){if(Thread.currentThread().isInterrupted()||!cloudAllowed.getAsBoolean())throw new InterruptedIOException("上传已停止");out.write(bytes,0,n);}}
            int code=connection.getResponseCode();if(code<200||code>=300)throw new IOException(code==401?"登录已过期，请重新登录":"附件上传失败（"+code+"）");
        }finally{connection.disconnect();}
    }
    static JSONObject request(URL url,String method,String token,byte[] data,String type) throws Exception {
        if(!"https".equals(url.getProtocol()) || !"dianjie.org".equals(url.getHost()))throw new IOException("无效服务地址");
        boolean contentRequest=url.getPath().startsWith("/v1/ai/")||url.getPath().startsWith("/v1/sync/");
        if(contentRequest&&!cloudAllowed.getAsBoolean())throw new IOException("当前为隐私模式，云端处理已停止");
        HttpsURLConnection connection=(HttpsURLConnection)url.openConnection();
        try {
            connection.setInstanceFollowRedirects(false);connection.setUseCaches(false);connection.setConnectTimeout(15000);connection.setReadTimeout(url.getPath().startsWith("/v1/auth/")?15000:120000);
            connection.setRequestMethod(method);connection.setRequestProperty("Accept","application/json");
            if(!token.isEmpty())connection.setRequestProperty("Authorization","Bearer "+token);
            if(data!=null){connection.setDoOutput(true);connection.setRequestProperty("Content-Type",type);connection.setFixedLengthStreamingMode(data.length);try(OutputStream out=connection.getOutputStream()){out.write(data);}}
            int code=connection.getResponseCode();
            if(code==401||code==403)throw new IOException(token.isEmpty()?"邮箱或密码不正确，请重试":"登录已过期，请重新登录点界账户");
            if(code==429)throw new IOException("服务请求过多，请稍后重试");
            if(code==413)throw new IOException("内容或附件超出云端限制");
            if(code<200||code>=300){String reason="";try(InputStream error=connection.getErrorStream()){if(error!=null){byte[] bytes=new byte[4096];int count=error.read(bytes);if(count>0){JSONObject response=new JSONObject(new String(bytes,0,count,StandardCharsets.UTF_8));Object detail=response.opt("error");reason=detail instanceof JSONObject?((JSONObject)detail).optString("code"):detail instanceof String?(String)detail:"";}}}catch(Exception ignored){}throw serviceError(code,reason,url.getPath());}
            if(code==204)return new JSONObject();
            try(InputStream in=connection.getInputStream();ByteArrayOutputStream buffer=new ByteArrayOutputStream()){
                byte[] bytes=new byte[16384];int n;while((n=in.read(bytes))!=-1){if(contentRequest&&!cloudAllowed.getAsBoolean())throw new InterruptedIOException("已切换隐私模式");if(Thread.currentThread().isInterrupted())throw new InterruptedIOException("已取消");if(buffer.size()+n>32*1024*1024)throw new IOException("返回内容过大");buffer.write(bytes,0,n);}
                String value=buffer.toString("UTF-8");return value.isEmpty()?new JSONObject():new JSONObject(value);
            }
        }finally{connection.disconnect();}
    }
}
