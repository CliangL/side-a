package studio.sidea.android;

import android.app.Activity;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.graphics.Color;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.webkit.*;
import android.widget.FrameLayout;
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
    private WebView web;
    private FrameLayout frame;
    private Catalog catalog;
    private boolean active, ready;
    private long lastRevision=-1;
    private String lastPlayer="";
    private volatile boolean destroyed;
    private final Runnable tick=new Runnable(){ public void run(){
        if(!active||destroyed)return;
        if(ready){
            JSONObject state=PlaybackService.state(MainActivity.this);
            String raw=state.toString();
            if(!raw.equals(lastPlayer)){lastPlayer=raw;send("sideAPlayer",raw);}
            long revision=Library.revision();
            if(revision!=lastRevision){lastRevision=revision;send("sideALibrary",Library.snapshot(MainActivity.this).toString());send("sideAPreferences",settings(new JSONObject()).toString());}
        }
        main.postDelayed(this,700);
    }};
    @Override public void onCreate(Bundle state){
        super.onCreate(state);
        catalog=new Catalog(this);
        frame=new FrameLayout(this);
        web=new WebView(this);
        frame.addView(web,new FrameLayout.LayoutParams(-1,-1));
        setContentView(frame);
        boolean night=(getResources().getConfiguration().uiMode&Configuration.UI_MODE_NIGHT_MASK)==Configuration.UI_MODE_NIGHT_YES;
        bars(night);
        if(Build.VERSION.SDK_INT>=30){
            getWindow().setDecorFitsSystemWindows(false);
            frame.setOnApplyWindowInsetsListener((v,ins)->{
                android.graphics.Insets i=ins.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout()|WindowInsets.Type.ime());
                v.setPadding(i.left,i.top,i.right,i.bottom);return WindowInsets.CONSUMED;
            });
        }else getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        WebSettings s=web.getSettings();
        s.setJavaScriptEnabled(true);s.setAllowFileAccess(false);s.setAllowContentAccess(false);
        s.setDomStorageEnabled(false);s.setSupportMultipleWindows(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        web.setWebViewClient(new WebViewClient(){
            @Override public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest request){return true;}
            @Override public WebResourceResponse shouldInterceptRequest(WebView view,WebResourceRequest request){
                Uri u=request.getUrl();
                if ("data".equals(u.getScheme()) && u.toString().startsWith("data:image/")) return null;
                String path=u.getPath();
                if(!"https".equals(u.getScheme())||!"sidea.local".equals(u.getHost())||path==null||path.contains("..")||!path.matches("/[a-zA-Z0-9._/-]+"))return blocked();
                String filename=path.substring(1);
                if(!filename.matches("(?:index\\.html|(?:app|core|pages|playing)\\.js|style\\.css|StarterArt/cover-[0-9]+\\.jpg)"))return blocked();
                String mime=filename.endsWith(".html")?"text/html":filename.endsWith(".css")?"text/css":filename.endsWith(".js")?"application/javascript":filename.endsWith(".jpg")?"image/jpeg":filename.endsWith(".png")?"image/png":filename.endsWith(".svg")?"image/svg+xml":filename.endsWith(".json")?"application/json":"application/octet-stream";
                try{
                    Map<String,String> headers=new HashMap<>();
                    headers.put("Content-Security-Policy","default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; base-uri 'none'");
                    headers.put("X-Content-Type-Options","nosniff");
                    return new WebResourceResponse(mime,"UTF-8",200,"OK",headers,getAssets().open(filename));
                }catch(IOException error){return blocked();}
            }
            @Override public void onPageFinished(WebView view,String url){if("https://sidea.local/index.html".equals(url)){ready=true;lastPlayer="";}}
        });
        web.addJavascriptInterface(new Bridge(),"SideA");
        web.loadUrl("https://sidea.local/index.html");
        if(Build.VERSION.SDK_INT>=33)getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,this::back);
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
        if(web==null){finish();return;}
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
        destroyed=true;main.removeCallbacks(tick);network.shutdownNow();artwork.shutdownNow();actions.shutdown();
        web.removeJavascriptInterface("SideA");frame.removeView(web);web.destroy();super.onDestroy();
    }
    private void send(String name,String parameters){
        if(!destroyed)web.evaluateJavascript("window."+name+" && window."+name+"("+parameters.replace("\u2028","\\u2028").replace("\u2029","\\u2029")+")",null);
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
                "centralBase",CentralCatalog.base(prefs));
        if("storage".equals(op)||"clear".equals(op)) put(result,"cacheBytes",catalog.cacheBytes());
        return result;
    }
    private Object handle(String action,JSONObject args)throws Exception{
        switch(action){
            case "init":return object("library",Library.snapshot(this),"starter",catalog.starters(),"player",PlaybackService.state(this),"settings",settings(new JSONObject()));
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
        @JavascriptInterface public void request(int id,String action,String payload){
            if(destroyed||action==null)return;
            ExecutorService executor=action.equals("cover")?artwork:
                    Arrays.asList("search","searchPage","prepareSearch","searchRank","searchEvidence","discover","related","recommend","genres","lyrics").contains(action)?network:actions;
            executor.execute(()->{
                Object result;boolean ok=true;
                try{
                    JSONObject args=new JSONObject(payload==null||payload.isEmpty()?"{}":payload);
                    result=handle(action,args);
                }catch(Exception e){ok=false;String m=e.getMessage();
                    result=m==null||m.length()>180?"暂时无法完成，请重试":m;}
                String json=result instanceof String?JSONObject.quote((String)result):String.valueOf(result);
                String parameters=id+","+ok+","+json;
                main.post(()->send("sideAReply",parameters));
            });
        }
    }
}
