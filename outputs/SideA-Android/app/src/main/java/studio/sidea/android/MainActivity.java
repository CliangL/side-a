package studio.sidea.android;

import android.app.Activity;
import android.content.SharedPreferences;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.pm.PackageInfo;
import android.content.res.Configuration;
import android.graphics.Color;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.webkit.*;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Button;
import android.widget.ProgressBar;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;
import static studio.sidea.android.Json.*;

/** Music playback belongs to the native media service; the offline-bundled view handles presentation. */
public final class MainActivity extends Activity {
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService actions=Executors.newSingleThreadExecutor();
    private final ExecutorService network=Executors.newFixedThreadPool(4);
    private final ExecutorService artwork=Executors.newFixedThreadPool(3);
    private volatile WebView web;
    private volatile int pageGeneration;
    private LinearLayout startup;
    private String startupFailure="";
    private FrameLayout frame;
    private Catalog catalog;
    private boolean active, ready;
    private long lastRevision=-1;
    private String lastPlayer="";
    private volatile boolean destroyed;
    private final Runnable startupTimeout=()->{if(!ready&&!destroyed)failStartup(pageGeneration,"timeout");};
    private final Runnable tick=new Runnable(){ public void run(){
        if(!active||destroyed)return;
        if(ready)try{
            JSONObject state=PlaybackService.state(MainActivity.this);
            String raw=state.toString();
            if(!raw.equals(lastPlayer)){lastPlayer=raw;send("sideAPlayer",raw);}
            long revision=Library.revision();
            if(revision!=lastRevision){lastRevision=revision;send("sideALibrary",Library.snapshot(MainActivity.this).toString());send("sideAPreferences",settings(new JSONObject()).toString());}
        }catch(RuntimeException|LinkageError unavailable){failStartup(pageGeneration,"native");}
        main.postDelayed(this,700);
    }};
    @Override public void onCreate(Bundle state){
        super.onCreate(state);
        catalog=new Catalog(this);
        frame=new FrameLayout(this);
        setContentView(frame);
        boolean night="car".equals(appUiMode())||(getResources().getConfiguration().uiMode&Configuration.UI_MODE_NIGHT_MASK)==Configuration.UI_MODE_NIGHT_YES;
        bars(night);
        if(Build.VERSION.SDK_INT>=30){
            getWindow().setDecorFitsSystemWindows(false);
            frame.setOnApplyWindowInsetsListener((v,ins)->{
                android.graphics.Insets i=ins.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout()|WindowInsets.Type.ime());
                v.setPadding(i.left,i.top,i.right,i.bottom);return WindowInsets.CONSUMED;
            });
        }else getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        startup=new LinearLayout(this);
        startup.setOrientation(LinearLayout.VERTICAL);startup.setGravity(Gravity.CENTER);
        int padding=dp(24);startup.setPadding(padding,padding,padding,padding);
        startup.setBackgroundColor(Color.parseColor("#172a2b"));
        frame.addView(startup,new FrameLayout.LayoutParams(-1,-1));
        openInterface();
        if(Build.VERSION.SDK_INT>=33)getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,this::back);
    }
    private int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
    private TextView startupText(String value,int size,int color){
        TextView text=new TextView(this);text.setText(value);text.setTextSize(size);text.setTextColor(color);
        text.setGravity(Gravity.CENTER);text.setPadding(0,dp(8),0,dp(8));return text;
    }
    private void openInterface(){
        if(destroyed)return;
        ready=false;startupFailure="";lastPlayer="";lastRevision=-1;
        int generation=++pageGeneration;
        main.removeCallbacks(startupTimeout);
        disposeWeb(web);
        startup.removeAllViews();startup.setVisibility(View.VISIBLE);
        ProgressBar progress=new ProgressBar(this);startup.addView(progress,new LinearLayout.LayoutParams(dp(32),dp(32)));
        startup.addView(startupText("Side A",22,Color.parseColor("#e3ebd7")));
        main.postDelayed(startupTimeout,15_000);
        try{
            final WebView view=new WebView(this);web=view;
            view.setBackgroundColor(Color.parseColor("#172a2b"));
            frame.addView(view,0,new FrameLayout.LayoutParams(-1,-1));
            WebSettings settings=view.getSettings();
            settings.setJavaScriptEnabled(true);settings.setAllowFileAccess(false);settings.setAllowContentAccess(false);
            settings.setDomStorageEnabled(false);settings.setSupportMultipleWindows(false);
            settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
            view.setWebViewClient(new WebViewClient(){
                @Override public boolean shouldOverrideUrlLoading(WebView v,WebResourceRequest request){return true;}
                @Override public boolean shouldOverrideUrlLoading(WebView v,String url){return true;}
                @Override public WebResourceResponse shouldInterceptRequest(WebView v,WebResourceRequest request){
                    Uri u=request.getUrl();
                    if ("data".equals(u.getScheme()) && u.toString().startsWith("data:image/")) return null;
                    String path=u.getPath();
                    if(!"https".equals(u.getScheme())||!"sidea.local".equals(u.getHost())||path==null||path.contains("..")||!path.matches("/[a-zA-Z0-9._/-]+"))return blocked();
                    String filename=path.substring(1);
                    if(!filename.matches("(?:index\\.html|(?:bootstrap|app|core|pages|playing|sound|car)\\.js|style\\.css|StarterArt/cover-[0-9]+\\.jpg)"))return blocked();
                    String mime=filename.endsWith(".html")?"text/html":filename.endsWith(".css")?"text/css":filename.endsWith(".js")?"application/javascript":"image/jpeg";
                    try{
                        Map<String,String> headers=new HashMap<>();
                        headers.put("Content-Security-Policy","default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; base-uri 'none'");
                        headers.put("X-Content-Type-Options","nosniff");
                        return new WebResourceResponse(mime,"UTF-8",200,"OK",headers,getAssets().open(filename));
                    }catch(IOException error){
                        if(!filename.endsWith(".jpg"))main.post(()->failStartup(generation,"resource"));
                        return blocked();
                    }
                }
                @Override public void onReceivedError(WebView v,WebResourceRequest request,WebResourceError error){
                    if(request.isForMainFrame())failStartup(generation,"resource");
                }
                @Override public void onReceivedHttpError(WebView v,WebResourceRequest request,WebResourceResponse error){
                    if(request.isForMainFrame())failStartup(generation,"resource");
                }
                @Override public boolean onRenderProcessGone(WebView v,RenderProcessGoneDetail detail){
                    if(generation==pageGeneration){failStartup(generation,"renderer");disposeWeb(v);}
                    return true;
                }
            });
            view.addJavascriptInterface(new Bridge(view,generation),"SideA");
            view.loadUrl("https://sidea.local/index.html");
        }catch(RuntimeException|LinkageError unavailable){disposeWeb(web);failStartup(generation,"webview");}
    }
    private void disposeWeb(WebView old){
        if(old==null)return;
        if(web==old)web=null;
        try{old.removeJavascriptInterface("SideA");old.stopLoading();frame.removeView(old);old.destroy();}
        catch(RuntimeException|LinkageError ignored){frame.removeView(old);}
    }
    private void uiReady(int generation){
        if(destroyed||generation!=pageGeneration||web==null)return;
        ready=true;startupFailure="";lastPlayer="";lastRevision=-1;
        main.removeCallbacks(startupTimeout);startup.setVisibility(View.GONE);
    }
    private void failStartup(int generation,String reason){
        if(destroyed||generation!=pageGeneration)return;
        ready=false;main.removeCallbacks(startupTimeout);
        if(reason.equals(startupFailure)&&startup.getVisibility()==View.VISIBLE)return;
        startupFailure=reason;startup.removeAllViews();startup.setVisibility(View.VISIBLE);
        startup.addView(startupText("暂时无法打开界面",22,Color.parseColor("#e3ebd7")));
        startup.addView(startupText("请重新打开；仍有问题时可复制兼容信息反馈。",14,Color.parseColor("#bacbc1")));
        Button retry=new Button(this);retry.setText("重新打开");retry.setAllCaps(false);
        retry.setOnClickListener(v->openInterface());startup.addView(retry,new LinearLayout.LayoutParams(dp(220),dp(52)));
        Button copy=new Button(this);copy.setText("复制兼容信息");copy.setAllCaps(false);
        copy.setOnClickListener(v->{
            ClipboardManager clipboard=(ClipboardManager)getSystemService(CLIPBOARD_SERVICE);
            if(clipboard!=null){clipboard.setPrimaryClip(ClipData.newPlainText("Side A 兼容信息",compatibilityInfo()));copy.setText("已复制");}
        });startup.addView(copy,new LinearLayout.LayoutParams(dp(220),dp(52)));
        startup.addView(startupText(compatibilityVersions(),12,Color.parseColor("#9fb5aa")));
    }
    private String compatibilityVersions(){
        String version="不可用";
        try{PackageInfo info=WebView.getCurrentWebViewPackage();if(info!=null)version=info.versionName;}catch(RuntimeException|LinkageError ignored){}
        return "Android "+Build.VERSION.RELEASE+" · WebView "+version;
    }
    private String compatibilityInfo(){
        String version="";
        try{version=getPackageManager().getPackageInfo(getPackageName(),0).versionName;}catch(android.content.pm.PackageManager.NameNotFoundException ignored){}
        return "Side A "+version+" ("+appUiMode()+")\n"+compatibilityVersions()+"\n启动阶段："+startupFailure;
    }
    private WebResourceResponse blocked(){return new WebResourceResponse("text/plain","UTF-8",403,"Forbidden",Collections.emptyMap(),new ByteArrayInputStream(new byte[0]));}
    @SuppressWarnings("deprecation")
    private void bars(boolean dark){
        int color=Color.parseColor(dark?"#172a2b":"#f9f6ef");
        frame.setBackgroundColor(color);
        getWindow().setStatusBarColor(color);getWindow().setNavigationBarColor(color);
        if(Build.VERSION.SDK_INT>=29){getWindow().setStatusBarContrastEnforced(false);getWindow().setNavigationBarContrastEnforced(false);}
        if(Build.VERSION.SDK_INT>=30){
            WindowInsetsController c=getWindow().getInsetsController();
            int light=WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS|WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
            if(c!=null)c.setSystemBarsAppearance(dark?0:light,light);
        }else getWindow().getDecorView().setSystemUiVisibility(dark?0:View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
    }
    private void back(){
        if(web==null||!ready){moveTaskToBack(true);return;}
        web.evaluateJavascript("Boolean(window.sideABack && window.sideABack())", result->{if(!"true".equals(result))moveTaskToBack(true);});
    }
    @Override public void onBackPressed(){back();}
    @Override protected void onResume(){
        super.onResume();active=true;main.removeCallbacks(tick);main.post(tick);
        CloudLibrary.start(getApplicationContext());
        network.execute(()->{
            if(CentralCatalog.enrollIfNeeded(getApplicationContext())){
                JSONObject next=settings(new JSONObject());
                main.post(()->{if(ready&&!destroyed)send("sideACatalogUpdated", next.toString());});
            }
        });
    }
    @Override protected void onPause(){active=false;main.removeCallbacks(tick);super.onPause();}
    @Override protected void onDestroy(){
        destroyed=true;main.removeCallbacks(tick);main.removeCallbacks(startupTimeout);
        network.shutdownNow();artwork.shutdownNow();actions.shutdown();
        disposeWeb(web);super.onDestroy();
    }
    private void send(String name,String parameters){
        if(!destroyed&&web!=null)web.evaluateJavascript("window."+name+" && window."+name+"("+parameters.replace("\u2028","\\u2028").replace("\u2029","\\u2029")+")",null);
    }
    private Object recommend()throws Exception{
        JSONObject seed=Library.seed(this);
        List<JSONObject> tracks=new ArrayList<>();
        if(seed!=null){
            try{
                JSONArray tags=catalog.genres(seed);Library.knownGenres(this,seed,tags);
            }catch(Exception ignored){}
            try{addUnique(tracks,rows(catalog.related(seed)));}catch(Exception ignored){}
        }
        addUnique(tracks,rows(catalog.starters()));
        JSONObject charts=catalog.discovery(false,false);
        addUnique(tracks,rows(array(charts,"newReleases")));addUnique(tracks,rows(array(charts,"hot")));
        return Library.recommend(this,tracks);
    }
    private JSONObject settings(JSONObject args){
        SharedPreferences prefs=getSharedPreferences("sidea.settings",MODE_PRIVATE);
        String op=text(args,"op");
        if("set".equals(op)){
            synchronized(Library.class){
            SharedPreferences.Editor e=prefs.edit();
            if(args.has("searchSource")) e.putString("searchSource",MusicSource.scope(text(args,"searchSource")));
            for(String key:new String[]{"preferLossless","losslessOnly","cellularDataSaver"})if(args.has(key))e.putBoolean(key,args.optBoolean(key));
            if(!e.commit())throw new IllegalStateException("偏好暂时无法保存");
            Library.preferencesChanged(this);
            }
        }else if("clear".equals(op))catalog.clear();
        JSONObject result=object("preferLossless",prefs.getBoolean("preferLossless",true),"losslessOnly",prefs.getBoolean("losslessOnly",false),"cellularDataSaver",prefs.getBoolean("cellularDataSaver",true),
                "searchSource",MusicSource.scope(prefs.getString("searchSource","all")),"allSources",new JSONArray(MusicSource.selections(prefs,"all")),
                "centralBase",CentralCatalog.base(prefs),"soundPreset",SoundPreset.normalize(prefs.getString("soundPreset",SoundPreset.ORIGINAL)),"soundPresets",AndroidSoundEffects.presets());
        if("storage".equals(op)||"clear".equals(op)) put(result,"cacheBytes",catalog.cacheBytes());
        return result;
    }
    private String appUiMode(){
        try{
            Bundle metadata=getPackageManager().getApplicationInfo(getPackageName(),android.content.pm.PackageManager.GET_META_DATA).metaData;
            return metadata!=null&&"car".equals(metadata.getString("studio.sidea.UI_MODE"))?"car":"phone";
        }catch(android.content.pm.PackageManager.NameNotFoundException e){return "phone";}
    }
    private Object handle(String action,JSONObject args)throws Exception{
        switch(action){
            case "init":return object("library",Library.snapshot(this),"starter",catalog.starters(),"player",PlaybackService.state(this),"settings",settings(new JSONObject()),"uiMode",appUiMode());
            case "sound":return PlaybackService.commandAndState(this,"sound",args.toString());
            case "player":return PlaybackService.state(this);
            case "library":return Library.snapshot(this);
            case "libraryAction":return Library.action(this,args);
            case "settings":return settings(args);
            case "prepareSearch":{
                CentralCatalog.enrollIfNeeded(getApplicationContext());
                return settings(new JSONObject());
            }
            case "playAction":{
                JSONObject result=PlaybackService.commandAndState(this,text(args,"op"),args.toString());
                main.postDelayed(()->{if(active){main.removeCallbacks(tick);main.post(tick);}},120);
                return result;
            }
            case "search": case "searchPage":{
                SharedPreferences prefs=getSharedPreferences("sidea.settings",MODE_PRIVATE);
                String selected=args.optString("searchSource",MusicSource.scope(prefs.getString("searchSource","all")));
                JSONObject result=catalog.searchPage(text(args,"query"),MusicSource.selections(prefs,selected),args.optInt("page",1));
                if(action.equals("searchPage"))return result;
                JSONArray items=array(result,"items");
                if(items.length()==0 && array(result,"bySource").length()==1){
                    JSONObject status=array(result,"bySource").getJSONObject(0);
                    if(!status.optBoolean("ok"))throw new IOException(text(status,"error"));
                }
                return catalog.rank(text(args,"query"),rows(items));
            }
            case "searchRank": case "searchEvidence":{
                String query=text(args,"query");
                List<JSONObject> songs=rows(args.optJSONArray("tracks"));
                if(action.equals("searchEvidence")){
                    List<JSONObject> publicSongs=new ArrayList<>();
                    for(JSONObject t:songs)if(!t.optBoolean("centralCatalog"))publicSongs.add(t);
                    if(!publicSongs.isEmpty())RecordingRanking.evidence(this,query,publicSongs);
                }
                return catalog.rank(query,songs);
            }
            case "discover":return catalog.discovery(args.optBoolean("force"),true);
            case "recommend":return recommend();
            case "related":return catalog.related(args.getJSONObject("track"));
            case "genres":return catalog.genres(args.getJSONObject("track"));
            case "lyrics":return catalog.lyrics(args.getJSONObject("track"));
            case "cover":{
                JSONObject t=args.getJSONObject("track");
                String embedded=PlaybackService.embeddedCover(id(t));
                return embedded==null||embedded.isEmpty()?catalog.cover(t):embedded;
            }
            case "sysBars": main.post(()->{if(!destroyed)bars(args.optBoolean("dark"));});return true;
            default:throw new IllegalArgumentException("未知操作");
        }
    }
    private final class Bridge {
        private final WebView ownerView;
        private final int generation;
        Bridge(WebView view,int generation){ownerView=view;this.generation=generation;}
        private boolean current(){return !destroyed&&generation==pageGeneration&&ownerView==web;}
        @JavascriptInterface public void uiReady(){main.post(()->{if(current())MainActivity.this.uiReady(generation);});}
        @JavascriptInterface public void uiFailed(String kind){
            // Never record JS exception messages, URLs, song names, or request parameters.
            String reason="runtime".equals(kind)?"runtime":"startup".equals(kind)?"startup":"script";
            main.post(()->{if(current()&&!ready)failStartup(generation,reason);});
        }
        @JavascriptInterface public void request(int id,String action,String payload){
            if(!current()||action==null)return;
            ExecutorService executor=action.equals("cover")?artwork:
                    Arrays.asList("search","searchPage","prepareSearch","searchRank","searchEvidence","discover","related","recommend","genres","lyrics").contains(action)?network:actions;
            try{executor.execute(()->{
                if(!current())return;
                Object result;boolean ok=true;
                try{
                    JSONObject args=new JSONObject(payload==null||payload.isEmpty()?"{}":payload);
                    result=handle(action,args);
                }catch(LinkageError unavailable){
                    ok=false;result="当前系统暂不支持此功能";
                    if("init".equals(action))main.post(()->{if(current())failStartup(generation,"native");});
                }catch(Exception e){ok=false;String m=e.getMessage();
                    result=m==null||m.length()>180?"暂时无法完成，请重试":m;}
                String json=result instanceof String?JSONObject.quote((String)result):String.valueOf(result);
                String parameters=id+","+ok+","+json;
                main.post(()->{if(current())send("sideAReply",parameters);});
            });}catch(RejectedExecutionException ignored){}
        }
    }
}
