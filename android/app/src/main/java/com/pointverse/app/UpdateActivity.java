package com.pointverse.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.view.View;
import android.widget.*;
import org.json.JSONObject;
import java.io.File;
import java.util.Locale;
import java.util.concurrent.*;
import java.util.function.Consumer;

/** User-initiated download followed by Android's own installation confirmation. */
public final class UpdateActivity extends Activity {
    private static final int ALLOW_INSTALL=40,INSTALL=41;
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private AppUpdater updater;
    private AppUpdater.Release release;
    private TextView status,notes;
    private ProgressBar progress;
    private Button action,cancel;
    private Future<?> running;
    private AlertDialog permissionDialog;
    private boolean busy,waitingForPermission;
    private int generation;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);updater=new AppUpdater(this);
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setBackgroundColor(Color.BLACK);
        root.setOnApplyWindowInsetsListener((view,insets)->{view.setPadding(dp(20),insets.getSystemWindowInsetTop()+dp(12),dp(20),insets.getSystemWindowInsetBottom()+dp(16));return insets.consumeSystemWindowInsets();});setContentView(root);
        Button back=button("‹ 返回");back.setOnClickListener(v->finish());root.addView(back);
        TextView title=text("应用更新",26);root.addView(title);root.addView(text("当前版本："+BuildVersion.name(this)+"\n无需登录即可更新，原有记录与设置会保留。",14));
        status=text("正在检查更新…",18);root.addView(status);
        progress=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);progress.setMax(100);progress.setVisibility(View.GONE);root.addView(progress,new LinearLayout.LayoutParams(-1,dp(20)));
        action=button("检查更新");action.setOnClickListener(v->{if(release==null)check();else downloadAndInstall();});root.addView(action);
        cancel=button("取消下载");cancel.setVisibility(View.GONE);cancel.setOnClickListener(v->cancelTask());root.addView(cancel);
        Button website=button("打开下载网站");website.setOnClickListener(v->{try{startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse(AppUpdater.BASE)));}catch(Exception e){status.setText("未找到浏览器，请访问 dianjie.org/downloads/android/");}});root.addView(website);
        ScrollView scroll=new ScrollView(this);notes=text("",15);scroll.addView(notes);root.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        if(state!=null) {
            waitingForPermission=state.getBoolean("waitingForPermission");
            try{String saved=state.getString("release");if(saved!=null)release=new AppUpdater.Release(new JSONObject(saved));}catch(Exception ignored){release=null;waitingForPermission=false;}
        }
        if(release==null)check();else{showRelease();status.setText(updater.cached(release).isFile()?"安装包已下载，可继续安装":"发现新版本 "+release.version);ready();}
    }
    private void check() {
        release=null;progress.setVisibility(View.GONE);notes.setText("");
        run("正在检查更新…",()->updater.check(),found->{
            release=found;if(found==null)status.setText("当前已是最新版本");else{showRelease();status.setText("发现新版本 "+found.version);}ready();
        });
    }
    private void showRelease(){notes.setText("新版本："+release.version+"\n安装包："+String.format(Locale.getDefault(),"%.1f MB",release.size/1048576.0)+"\n\n更新说明\n"+release.notes);}
    private void downloadAndInstall() {
        if(busy||release==null)return;
        AppUpdater.Release selected=release;progress.setProgress(0);progress.setVisibility(View.VISIBLE);int[] last={-1};final int token=generation+1;
        run("正在准备下载…",()->updater.download(selected,(received,total)->{
            int percent=(int)(received*100/total);if(percent==last[0])return;last[0]=percent;
            runOnUiThread(()->{if(!isDestroyed()&&token==generation&&busy){progress.setProgress(percent);status.setText(percent==100?"下载完成，正在校验安装包…":"正在下载 "+percent+"% · "+String.format(Locale.getDefault(),"%.1f / %.1f MB",received/1048576.0,total/1048576.0));}});
        }),this::prepareInstallation);
    }
    private void prepareInstallation(File file) {
        status.setText("安装包已校验，可继续安装");ready();
        if(!getPackageManager().canRequestPackageInstalls()) {
            permissionDialog=new AlertDialog.Builder(this).setTitle("允许点界安装更新").setMessage("请在接下来的 Android 设置中开启「允许来自此来源的应用」。返回点界后会继续打开系统安装确认页。")
                    .setNegativeButton("稍后",null).setPositiveButton("前往设置",(dialog,which)->{
                        try{waitingForPermission=true;startActivityForResult(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,Uri.parse("package:"+getPackageName())),ALLOW_INSTALL);}
                        catch(Exception e){waitingForPermission=false;status.setText("无法打开安装权限设置，请在系统设置中允许点界安装应用后重试");}
                    }).create();permissionDialog.show();return;
        }
        try {
            Intent install=AppUpdater.installIntent(this,file);
            startActivityForResult(install,INSTALL);
        }catch(Exception e){status.setText("无法打开系统安装界面，可使用下载网站安装");}
    }
    @Override protected void onActivityResult(int request,int result,Intent data) {
        super.onActivityResult(request,result,data);
        if(request==ALLOW_INSTALL){waitingForPermission=false;if(getPackageManager().canRequestPackageInstalls())downloadAndInstall();else{status.setText("未开启安装权限，安装包已保留，可稍后继续安装");ready();}}
        if(request==INSTALL){status.setText(result==RESULT_OK?"更新安装完成":"安装未完成，安装包已保留，可再次安装");ready();}
    }
    @Override protected void onResume(){super.onResume();if(waitingForPermission&&getPackageManager().canRequestPackageInstalls()){waitingForPermission=false;downloadAndInstall();}}
    @Override protected void onSaveInstanceState(Bundle state){super.onSaveInstanceState(state);state.putBoolean("waitingForPermission",waitingForPermission);if(release!=null)try{state.putString("release",release.json().toString());}catch(Exception ignored){}}
    private <T> void run(String message,Callable<T> operation,Consumer<T> done) {
        busy=true;action.setEnabled(false);cancel.setVisibility(View.VISIBLE);status.setText(message);int token=++generation;
        running=worker.submit(()->{try{T value=operation.call();runOnUiThread(()->{if(!isDestroyed()&&!isFinishing()&&token==generation){busy=false;cancel.setVisibility(View.GONE);done.accept(value);}});}
            catch(Exception e){runOnUiThread(()->{if(!isDestroyed()&&!isFinishing()&&token==generation){busy=false;progress.setVisibility(View.GONE);status.setText(e instanceof java.io.IOException&&e.getMessage()!=null?e.getMessage():"更新未完成，请检查网络后重试");ready();}});}});
    }
    private void ready(){busy=false;cancel.setVisibility(View.GONE);action.setEnabled(true);action.setText(release==null?"检查更新":updater.cached(release).isFile()?"安装更新":"下载并安装");}
    private void cancelTask(){generation++;if(running!=null)running.cancel(true);updater.cancel();progress.setVisibility(View.GONE);status.setText("已取消，原有应用与记录未改变");ready();}
    @Override protected void onDestroy(){if(permissionDialog!=null)permissionDialog.dismiss();generation++;if(running!=null)running.cancel(true);if(updater!=null)updater.cancel();worker.shutdownNow();super.onDestroy();}
    private int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
    private TextView text(String value,int size){TextView view=new TextView(this);view.setText(value);view.setTextSize(size);view.setTextColor(0xfff2f2f7);view.setPadding(0,dp(10),0,dp(10));return view;}
    private Button button(String value){Button view=new Button(this);view.setText(value);view.setAllCaps(false);view.setTextColor(0xfff2f2f7);return view;}
}
