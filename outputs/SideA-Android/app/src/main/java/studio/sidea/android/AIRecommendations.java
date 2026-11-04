package studio.sidea.android;

import android.content.Context;
import android.content.SharedPreferences;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import org.json.*;
import static studio.sidea.android.Json.*;

/** Private summaries and IDs only. Configuration probes are free; playback never waits for AI. */
final class AIRecommendations {
    private static final ExecutorService worker=Executors.newSingleThreadExecutor();
    private static boolean busy,active;
    private static long retryAfter,nextProbe,generation;
    private static String revision;
    private static JSONArray latestCandidates=new JSONArray();
    private static Runnable onChanged;
    static String hash(String value){
        try{
            StringBuilder out=new StringBuilder();
            for(byte b:MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)))out.append(String.format(Locale.ROOT,"%02x",b&255));
            return out.toString();
        }catch(Exception impossible){throw new IllegalStateException(impossible);}
    }
    static String clipped(String value,int limit){return value.substring(0,value.offsetByCodePoints(0,Math.min(limit,value.codePointCount(0,value.length()))));}
    static JSONArray reorder(JSONArray candidates,JSONObject result){
        Map<String,JSONObject> originals=new LinkedHashMap<>();for(JSONObject t:rows(candidates))originals.put(hash(id(t)),t);
        List<JSONObject> ordered=new ArrayList<>();
        for(JSONObject entry:rows(array(result,"ranked"))){JSONObject track=originals.remove(text(entry,"id"));if(track!=null)ordered.add(track);}
        ordered.addAll(originals.values());return new JSONArray(ordered);
    }
    static synchronized void setActive(Context ctx,boolean value,Runnable changed){
        active=value;onChanged=value?changed:null;
        if(value){nextProbe=0;refreshIfDue(ctx);}
    }
    static synchronized void reset(Context ctx){
        ctx.getSharedPreferences("sidea.ai",Context.MODE_PRIVATE).edit().clear().apply();
        retryAfter=0;nextProbe=0;generation++;
    }
    static synchronized JSONArray ranked(Context ctx,JSONArray candidates){
        latestCandidates=candidates;
        if(Library.aiProfile(ctx)==null)return firstPage(candidates);
        refreshIfDue(ctx);
        SharedPreferences cache=ctx.getSharedPreferences("sidea.ai",Context.MODE_PRIVATE);
        if(cache.getLong("expires",0)>System.currentTimeMillis()){
            try{return firstPage(reorder(Library.aiAllowed(ctx,candidates),new JSONObject(cache.getString("result","{}"))));}catch(JSONException ignored){}
        }
        return firstPage(candidates);
    }
    private static synchronized boolean isActive(){return active;}
    private static void changed(){Runnable callback;synchronized(AIRecommendations.class){callback=active?onChanged:null;}if(callback!=null)callback.run();}
    static synchronized void refreshIfDue(Context context){
        if(!active||busy||System.currentTimeMillis()<nextProbe)return;
        Context ctx=context.getApplicationContext();
        if(Library.aiProfile(ctx)==null)return;
        busy=true;nextProbe=System.currentTimeMillis()+60000;long ownGeneration=generation;
        worker.execute(()->{
            SharedPreferences cache=ctx.getSharedPreferences("sidea.ai",Context.MODE_PRIVATE);
            try{
                JSONObject config=CentralCatalog.ai(ctx,"GET","/v1/ai/config",null).getJSONObject("config");
                if(!isActive())return;
                String current=text(config,"revision");
                if(!current.matches("[0-9a-f]{64}"))return;
                if(!config.optBoolean("enabled")){
                    cache.edit().remove("result").remove("expires").remove("fingerprint").commit();changed();
                }
                JSONObject pending=null;
                try{String raw=cache.getString("pending","");if(!raw.isEmpty())pending=new JSONObject(raw);}catch(JSONException invalid){cache.edit().remove("pending").commit();}
                if(pending!=null&&(!current.equals(text(pending,"revision"))||!config.optBoolean("enabled")||System.currentTimeMillis()-pending.optLong("created")>21600000)){
                    String taskId=text(pending,"id");
                    if(!CentralCatalog.cancelAI(ctx,taskId))return;
                    cache.edit().remove("pending").commit();pending=null;
                }
                synchronized(AIRecommendations.class){
                    if(generation!=ownGeneration)return;
                    String previous=revision==null?cache.getString("revision",""):revision;
                    if(!current.equals(previous)){cache.edit().clear().commit();retryAfter=0;changed();}
                    revision=current;
                }
                if(!config.optBoolean("enabled")){cache.edit().clear().commit();changed();return;}
                if(!isActive())return;
                // Query the existing job before any cooldown, including after process
                // restart or backgrounding. A slow model never causes a second POST.
                if(pending!=null){
                    String taskId=text(pending,"id");
                    if(!taskId.matches("[A-Za-z0-9_-]{1,80}")){cache.edit().remove("pending").commit();return;}
                    JSONObject job=CentralCatalog.ai(ctx,"GET","/v1/ai/tasks/"+taskId,null).getJSONObject("task");
                    if(isActive())receive(ctx,job,pending,ownGeneration);
                    return;
                }
                JSONObject profile=Library.aiProfile(ctx);if(profile==null)return;
                JSONArray candidates;synchronized(AIRecommendations.class){candidates=latestCandidates;}
                JSONArray metadata=new JSONArray();
                for(JSONObject track:rows(Library.aiAllowed(ctx,candidates)))metadata.put(object("id",hash(id(track)),
                        "title",clipped(text(track,"title"),80),"artist",clipped(text(track,"artist"),80),"album",clipped(text(track,"album"),80)));
                if(metadata.length()==0)return;
                JSONObject input=object("profile",profile,"candidates",metadata);String fingerprint=hash(input.toString());
                if(fingerprint.equals(cache.getString("fingerprint",""))&&cache.getLong("expires",0)>System.currentTimeMillis())return;
                synchronized(AIRecommendations.class){
                    retryAfter=Math.max(retryAfter,cache.getLong("retryAfter",0));
                    if(!active||generation!=ownGeneration||System.currentTimeMillis()<retryAfter)return;
                    retryAfter=System.currentTimeMillis()+600000;
                    cache.edit().putLong("retryAfter",retryAfter).commit();
                }
                JSONObject job=CentralCatalog.ai(ctx,"POST","/v1/ai/recommend",input).getJSONObject("task");
                String taskId=text(job,"id");if(!taskId.matches("[A-Za-z0-9_-]{1,80}"))return;
                pending=object("id",taskId,"revision",current,"fingerprint",fingerprint,"created",System.currentTimeMillis(),"input",input);
                synchronized(AIRecommendations.class){
                    if(generation!=ownGeneration||Library.aiProfile(ctx)==null)return;
                    // Preserve the ID even when the UI just backgrounded. No further
                    // GET or model request occurs until a foreground owner resumes.
                    cache.edit().putString("pending",pending.toString()).putString("revision",current).commit();
                }
                if(isActive())receive(ctx,job,pending,ownGeneration);
            }catch(Exception unavailable){ /* Keep local recommendations and pending job for a later connection. */ }
            finally{synchronized(AIRecommendations.class){busy=false;nextProbe=System.currentTimeMillis()+60000;}}
        });
    }
    private static void receive(Context ctx,JSONObject job,JSONObject pending,long ownGeneration){
        if(!text(job,"id").equals(text(pending,"id")))return;
        SharedPreferences cache=ctx.getSharedPreferences("sidea.ai",Context.MODE_PRIVATE);
        String status=text(job,"status");boolean saved=false;
        synchronized(AIRecommendations.class){
            if(generation!=ownGeneration||!active||Library.aiProfile(ctx)==null)return;
            if("succeeded".equals(status)){
                JSONObject result=job.optJSONObject("result");
                if(result!=null&&array(result,"ranked").length()>0){
                    saved=cache.edit().putString("fingerprint",text(pending,"fingerprint")).putString("revision",text(pending,"revision"))
                            .putString("result",result.toString()).putLong("expires",System.currentTimeMillis()+21600000).remove("pending").commit();
                }else cache.edit().remove("pending").commit();
            }else if(!Arrays.asList("queued","leased","running").contains(status))cache.edit().remove("pending").commit();
        }
        if(saved)changed();
    }
    private static JSONArray firstPage(JSONArray tracks){
        List<JSONObject> list=rows(tracks);return new JSONArray(list.subList(0,Math.min(24,list.size())));
    }
    private AIRecommendations(){}
}
