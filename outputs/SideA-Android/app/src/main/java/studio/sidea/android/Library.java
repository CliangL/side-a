package studio.sidea.android;

import android.content.Context;
import android.content.SharedPreferences;
import java.time.LocalDate;
import java.util.*;
import org.json.*;
import static studio.sidea.android.Json.*;

/** The service and UI share one store. Playback may outlive the Activity. */
final class Library {
    private static JSONObject state;
    private static JSONObject acknowledgedBase;
    private static long revision=0;
    private static final Map<String,Long> skips=new HashMap<>();
    private static SharedPreferences disk(Context ctx){return ctx.getSharedPreferences("sidea.library",Context.MODE_PRIVATE);}
    private static JSONObject data(Context ctx) {
        if(state==null){
            String raw=disk(ctx).getString("collection",null);
            try{
                if(raw==null){JSONObject saved=cloudBase(ctx).optJSONObject("library");state=saved==null?new JSONObject():LibraryMerge.copy(saved);}
                else state=new JSONObject(raw);
            }
            catch(JSONException e){
                disk(ctx).edit().putString("unreadable-"+System.currentTimeMillis(),raw).commit();
                state=new JSONObject();
                // Recover a usable baseline before accepting new offline edits. Never substitute an empty collection for a corrupt one.
                try{JSONObject saved=cloudBase(ctx).optJSONObject("library");if(saved!=null)state=LibraryMerge.copy(saved);}catch(JSONException ignored){}
            }
        }
        return state;
    }
    private static void save(Context ctx){
        revision++;
        if(!disk(ctx).edit().putString("collection",data(ctx).toString()).commit())throw new IllegalStateException("资料库暂时无法保存");
        CloudLibrary.changed(ctx);
    }
    private static final String[] CLOUD_FIELDS={"favorites","playlists","recent","history","hidden","genres","muted","trackingEnabled"};
    static final String[] CLOUD_PREFERENCES={"preferLossless","losslessOnly","cellularDataSaver"};
    static synchronized JSONObject cloudSnapshot(Context ctx){
        JSONObject local=new JSONObject(),settings=new JSONObject();JSONObject d=data(ctx);
        for(String key:CLOUD_FIELDS)if(d.has(key))put(local,key,d.opt(key));
        SharedPreferences prefs=ctx.getSharedPreferences("sidea.settings",Context.MODE_PRIVATE);
        for(String key:CLOUD_PREFERENCES)if(prefs.contains(key))put(settings,key,prefs.getBoolean(key,false));
        if(prefs.contains("searchSource"))put(settings,"searchSource",MusicSource.scope(prefs.getString("searchSource","all")));
        if(prefs.contains("soundPreset"))put(settings,"soundPreset",SoundPreset.normalize(prefs.getString("soundPreset",SoundPreset.ORIGINAL)));
        return LibraryMerge.copy(object("schema",1,"platform","android","library",local,"settings",settings));
    }
    private static JSONObject cloudBase(Context ctx)throws JSONException{
        // SharedPreferences updates its process cache even when commit returns false. Only a confirmed write advances this base.
        if(acknowledgedBase==null)acknowledgedBase=new JSONObject(disk(ctx).getString("cloudBase","{}"));
        return acknowledgedBase;
    }
    static synchronized boolean cloudDirty(Context ctx)throws JSONException{return !LibraryMerge.same(cloudBase(ctx),cloudSnapshot(ctx));}
    static synchronized JSONObject mergeCloud(Context ctx,JSONObject remote,long remoteRevision)throws Exception{
        JSONObject base=cloudBase(ctx),local=cloudSnapshot(ctx);
        // A profile with no backup is not a command to delete this device's existing library.
        if(remoteRevision==0&&remote.length()==0)base=new JSONObject();
        JSONObject merged=LibraryMerge.merge(base,local,remote),library=merged.optJSONObject("library"),settings=merged.optJSONObject("settings");
        if(library==null)library=new JSONObject();if(settings==null)settings=new JSONObject();
        JSONObject clean=new JSONObject();for(String key:CLOUD_FIELDS)if(library.has(key))put(clean,key,library.opt(key));
        SharedPreferences.Editor options=ctx.getSharedPreferences("sidea.settings",Context.MODE_PRIVATE).edit();
        for(String key:CLOUD_PREFERENCES){if(settings.has(key))options.putBoolean(key,settings.getBoolean(key));else options.remove(key);}
        if(settings.has("searchSource"))options.putString("searchSource",MusicSource.scope(settings.getString("searchSource")));else options.remove("searchSource");
        if(settings.has("soundPreset"))options.putString("soundPreset",SoundPreset.normalize(settings.getString("soundPreset")));else options.remove("soundPreset");
        if(!options.commit())throw new java.io.IOException("偏好暂时无法保存");
        // Local changes and the remote base advance in one durable write, even if the process stops before PUT.
        if(!disk(ctx).edit().putString("collection",clean.toString()).putString("cloudBase",remote.toString()).putLong("cloudRevision",remoteRevision)
                .commit())throw new java.io.IOException("资料库暂时无法保存");
        acknowledgedBase=LibraryMerge.copy(remote);state=clean;
        if(!LibraryMerge.same(local,cloudSnapshot(ctx)))revision++;
        return cloudSnapshot(ctx);
    }
    static synchronized void acknowledgeCloud(Context ctx,JSONObject sent,long remoteRevision)throws Exception{
        // A user may have edited the library while the request was in flight; only advance the acknowledged base.
        cloudBase(ctx);
        if(!disk(ctx).edit().putString("cloudBase",sent.toString()).putLong("cloudRevision",remoteRevision).commit())throw new java.io.IOException("备份状态暂时无法保存");
        acknowledgedBase=LibraryMerge.copy(sent);
    }
    private static List<JSONObject> list(JSONObject d,String k){return rows(array(d,k));}
    private static JSONObject map(JSONObject d,String k){
        JSONObject v=d.optJSONObject(k);if(v==null){v=new JSONObject();put(d,k,v);}return v;
    }
    private static void list(JSONObject d,String key,List<JSONObject> rows){put(d,key,new JSONArray(rows));}
    private static JSONObject find(List<JSONObject> tracks,String id){
        for(JSONObject t:tracks)if(id(t).equals(id))return t;return null;
    }
    private static void remember(JSONObject d,JSONObject t){
        List<JSONObject> recent=list(d,"recent");recent.removeIf(old->id(old).equals(id(t)));
        recent.add(0,t);list(d,"recent",recent.subList(0,Math.min(100,recent.size())));
    }
    public static synchronized void record(Context ctx,JSONObject track,String event,double listened,double duration){
        if(track==null||text(track,"trackID").isEmpty())return;
        JSONObject d=data(ctx);long now=System.currentTimeMillis(),day=LocalDate.now().toEpochDay();
        boolean starts=event.equals("manualPlay")||event.equals("autoPlay")||event.equals("replay");
        if(starts)remember(d,track);
        if(!d.optBoolean("trackingEnabled",true)||"autoPlay".equals(event)){
            if(starts)save(ctx);return;
        }
        boolean quick=event.equals("skip")&&listened>0&&listened<12&&(duration<=0||listened<duration*0.25);
        boolean completion=event.equals("complete")&&listened>=Math.min(45,Math.max(8,duration*0.6));
        if(!starts&&!quick&&!completion)return;
        List<JSONObject> history=list(d,"history");history.removeIf(h->h.optLong("day")<day-120);
        JSONObject sample=null;String key=id(track);
        for(JSONObject h:history)if(h.optLong("day")==day&&key.equals(text(h,"id"))){sample=h;break;}
        if(sample==null){sample=object("day",day,"id",key,"track",track);history.add(sample);}
        if("manualPlay".equals(event)){put(sample,"choices",Math.min(3,sample.optInt("choices")+1));skips.remove(key);}
        if("replay".equals(event)){put(sample,"replays",Math.min(2,sample.optInt("replays")+1));skips.remove(key);}
        if(quick){put(sample,"skips",Math.min(2,sample.optInt("skips")+1));skips.put(key,now);}
        if(completion)put(sample,"complete",1);
        list(d,"history",history);save(ctx);
    }
    private static Map<String,Double> weights(JSONObject d){
        Map<String,Double> w=new HashMap<>();if(!d.optBoolean("trackingEnabled",true))return w;
        for(JSONObject t:list(d,"favorites"))w.put(id(t),4.0);
        Map<String,Integer> skippedDays=new HashMap<>();List<JSONObject> history=list(d,"history");
        for(JSONObject h:history)if(h.optInt("skips")>0)skippedDays.merge(text(h,"id"),1,Integer::sum);
        long today=LocalDate.now().toEpochDay();
        for(JSONObject h:history){
            String id=text(h,"id");double decay=Math.exp(-Math.max(0,today-h.optLong("day"))/35.0);
            double penalty=skippedDays.getOrDefault(id,0)>1?0.8*h.optInt("skips"):0;
            w.merge(id,decay*(0.7*h.optInt("choices")+1.8*h.optInt("replays")+0.5*h.optInt("complete")-penalty),Double::sum);
        }return w;
    }
    private static List<JSONObject> known(JSONObject d){
        List<JSONObject> a=list(d,"favorites");addUnique(a,list(d,"recent"));
        List<JSONObject> history=new ArrayList<>();
        for(JSONObject h:list(d,"history"))if(h.optJSONObject("track")!=null)history.add(h.optJSONObject("track"));
        addUnique(a,history);return a;
    }
    private static JSONObject seed(JSONObject d){
        Map<String,Double> w=weights(d);double best=0;JSONObject result=null;
        for(JSONObject t:known(d)){double v=w.getOrDefault(id(t),0.0);
            if(v>best&&!map(d,"hidden").optBoolean(id(t))){best=v;result=t;}
        }return result;
    }
    public static synchronized JSONObject seed(Context ctx){return seed(data(ctx));}
    static synchronized void knownGenres(Context ctx,JSONObject t,JSONArray tags){
        if(t==null||tags==null||tags.length()==0||!data(ctx).optBoolean("trackingEnabled",true))return;
        JSONObject m=map(data(ctx),"genres");
        if(tags.toString().equals(String.valueOf(m.opt(id(t)))))return;
        put(m,id(t),tags);save(ctx);
    }
    private static String reason(JSONObject d,JSONObject seed){
        if(seed==null)return "从几张唱片开始，听见新的声音";
        int days=0;String key=id(seed),title=text(seed,"title");
        for(JSONObject h:list(d,"history"))if(key.equals(text(h,"id"))&&h.optInt("choices")+h.optInt("replays")>0)days++;
        if(days>1)return "因为你有 "+days+" 天主动听了《"+title+"》";
        if(find(list(d,"favorites"),key)!=null)return "因为你收藏了《"+title+"》";
        return "沿着《"+title+"》继续发现";
    }
    static synchronized JSONObject snapshot(Context ctx){
        JSONObject d=data(ctx),seed=seed(d);
        // Return independent JSON to callers on other threads.
        JSONObject result=object("favorites",array(d,"favorites"),"playlists",array(d,"playlists"),"recent",array(d,"recent"),
                "trackingEnabled",d.optBoolean("trackingEnabled",true),"seed",seed,"reason",reason(d,seed),"revision",revision);
        try{return new JSONObject(result.toString());}catch(JSONException e){throw new IllegalStateException(e);}
    }
    static synchronized long revision(){return revision;}
    static synchronized void preferencesChanged(Context ctx){revision++;CloudLibrary.changed(ctx);}
    static synchronized JSONObject action(Context ctx,JSONObject args)throws Exception{
        JSONObject d=data(ctx),track=args.optJSONObject("track");
        String op=text(args,"op"),name=text(args,"name").trim(),pid=text(args,"id");
        List<JSONObject> plays=list(d,"playlists");JSONObject playlist=null;
        for(JSONObject pl:plays)if(text(pl,"id").equals(pid)){playlist=pl;break;}
        switch(op){
            case "favorite": {
                if(track==null)throw new IllegalArgumentException("请选择歌曲");
                List<JSONObject> fav=list(d,"favorites");String key=id(track);
                if(find(fav,key)!=null)fav.removeIf(v->id(v).equals(key));
                else{fav.add(0,track);map(d,"hidden").remove(key);}
                list(d,"favorites",fav);break;
            }
            case "create":{
                if(name.isEmpty())throw new IllegalArgumentException("请填写歌单名称");
                List<JSONObject> songs=new ArrayList<>();addUnique(songs,rows(args.optJSONArray("tracks")));
                plays.add(0,object("id",UUID.randomUUID().toString(),"name",name,"tracks",new JSONArray(songs),"cover",null));break;
            }
            case "rename": if(playlist!=null&&!name.isEmpty())put(playlist,"name",name);break;
            case "delete": plays.removeIf(v->pid.equals(text(v,"id")));break;
            case "add": case "remove": case "reorder": case "setCover":{
                if(playlist==null)throw new IllegalArgumentException("歌单已不存在");
                List<JSONObject> items=list(playlist,"tracks");
                if(op.equals("add")){
                    if(track!=null)addUnique(items,Collections.singletonList(track));
                    addUnique(items,rows(args.optJSONArray("tracks")));
                }else if(op.equals("remove")){
                    Set<String> remove=new HashSet<>();JSONArray ids=array(args,"ids");
                    for(int i=0;i<ids.length();i++)remove.add(ids.optString(i));
                    if(track!=null)remove.add(id(track));
                    items.removeIf(v->remove.contains(id(v)));
                    JSONObject cover=playlist.optJSONObject("cover");if(cover!=null&&remove.contains(id(cover)))put(playlist,"cover",null);
                }else if(op.equals("setCover")){
                    if(track==null||find(items,id(track))!=null)put(playlist,"cover",track);
                }else {
                    int from=args.optInt("from",-1),to=args.optInt("to",-1);
                    if(from>=0&&from<items.size()&&to>=0&&to<items.size())items.add(to,items.remove(from));
                }
                list(playlist,"tracks",items);break;
            }
            case "dislike":if(track!=null)put(map(d,"hidden"),id(track),true);break;
            case "reduceStyle":{
                JSONArray tags=array(args,"tags");for(int i=0;i<tags.length();i++)put(map(d,"muted"),tags.optString(i).toLowerCase(Locale.ROOT),true);
                if(track!=null&&tags.length()>0){Set<String> union=new LinkedHashSet<>();JSONArray old=map(d,"genres").optJSONArray(id(track));
                    if(old!=null)for(int i=0;i<old.length();i++)union.add(old.optString(i));
                    for(int i=0;i<tags.length();i++)union.add(tags.optString(i));
                    put(map(d,"genres"),id(track),new JSONArray(union));}break;
            }
            case "tracking":put(d,"trackingEnabled",args.optBoolean("enabled",true));break;
            case "reset":for(String k:new String[]{"hidden","history","genres","muted"})d.remove(k);skips.clear();break;
            default:throw new IllegalArgumentException("未知资料库操作");
        }
        list(d,"playlists",plays);save(ctx);return snapshot(ctx);
    }
    static synchronized JSONArray aiAllowed(Context ctx,JSONArray candidates){
        JSONObject d=data(ctx),muted=map(d,"muted"),genres=map(d,"genres"),hidden=map(d,"hidden");
        JSONArray allowed=new JSONArray();
        for(JSONObject t:rows(candidates)){
            String key=id(t);if(hidden.optBoolean(key)||System.currentTimeMillis()-skips.getOrDefault(key,0L)<3600000)continue;
            JSONArray tags=genres.optJSONArray(key);if(tags==null)tags=array(t,"genres");boolean blocked=false;
            for(int j=0;j<tags.length();j++)blocked|=muted.optBoolean(tags.optString(j).toLowerCase(Locale.ROOT));
            if(!blocked)allowed.put(t);
        }
        return allowed;
    }
    private static Set<String> knownKeys(JSONObject d){Set<String> keys=new HashSet<>();for(JSONObject t:known(d))keys.add(RecommendationSelection.key(t));return keys;}
    private static Set<String> shown(Context ctx){
        Set<String> keys=new LinkedHashSet<>();try{JSONArray a=new JSONArray(ctx.getSharedPreferences("sidea.discovery",0).getString("shown","[]"));for(int i=0;i<a.length();i++)keys.add(a.optString(i));}catch(JSONException ignored){}return keys;
    }
    static synchronized JSONArray discoveryOrder(Context ctx,JSONArray tracks,int limit){return RecommendationSelection.order(tracks,knownKeys(data(ctx)),shown(ctx),limit);}
    static synchronized JSONObject aiFlags(Context ctx,JSONObject t){
        Set<String> recent=new HashSet<>();for(JSONObject r:list(data(ctx),"recent")){recent.add(RecommendationSelection.key(r));if(recent.size()>=12)break;}
        String key=RecommendationSelection.key(t);return object("familiar",knownKeys(data(ctx)).contains(key),"recent",recent.contains(key),"shown",shown(ctx).contains(key));
    }
    static synchronized int recommendationTurn(Context ctx){return ctx.getSharedPreferences("sidea.discovery",0).getInt("turn",0);}
    static synchronized void nextRecommendations(Context ctx,JSONArray displayed){
        SharedPreferences p=ctx.getSharedPreferences("sidea.discovery",0);
        if(System.currentTimeMillis()-p.getLong("changed",0)<2000)return;
        Set<String> keys=shown(ctx);for(JSONObject t:rows(displayed)){String k=RecommendationSelection.key(t);keys.remove(k);keys.add(k);}
        List<String> all=new ArrayList<>(keys);if(all.size()>96)all=all.subList(all.size()-96,all.size());
        p.edit().putString("shown",new JSONArray(all).toString()).putInt("turn",p.getInt("turn",0)+1).putLong("changed",System.currentTimeMillis()).apply();
        ctx.getSharedPreferences("sidea.ai",0).edit().remove("result").remove("expires").remove("fingerprint").apply();
    }
    static synchronized List<String> discoveryArtists(Context ctx){
        if(!data(ctx).optBoolean("trackingEnabled",true))return new ArrayList<>();
        LinkedHashSet<String> artists=new LinkedHashSet<>();JSONObject seed=seed(data(ctx));if(seed!=null)artists.add(text(seed,"artist"));
        for(JSONObject t:list(data(ctx),"favorites")){artists.add(text(t,"artist"));if(artists.size()>=2)break;}
        artists.remove("");return new ArrayList<>(artists);
    }
    static synchronized JSONObject aiProfile(Context ctx){
        JSONObject d=data(ctx);if(!d.optBoolean("trackingEnabled",true))return null;
        JSONArray favorites=new JSONArray(),listening=new JSONArray(),muted=new JSONArray();
        for(JSONObject t:list(d,"favorites")){if(favorites.length()>=10)break;favorites.put(aiSignal(t));}
        LinkedHashMap<String,JSONObject> signals=new LinkedHashMap<>();
        List<JSONObject> history=list(d,"history");Collections.reverse(history);long cutoff=LocalDate.now().toEpochDay()-30;
        for(JSONObject h:history){
            JSONObject track=h.optJSONObject("track");if(track==null||h.optLong("day")<cutoff)continue;
            String identity=id(track);JSONObject signal=signals.get(identity);
            if(signal==null){signal=aiSignal(track);signals.put(identity,signal);}
            for(String[] pair:new String[][]{{"choices","choices"},{"replays","replays"},{"completions","complete"},{"quick_skips","skips"}})
                put(signal,pair[0],signal.optInt(pair[0])+h.optInt(pair[1]));
        }
        LinkedHashSet<String> order=new LinkedHashSet<>();for(JSONObject t:list(d,"recent"))order.add(id(t));order.addAll(signals.keySet());
        for(String key:order){if(listening.length()>=12)break;JSONObject signal=signals.get(key);if(signal!=null)listening.put(signal);}
        JSONObject styles=map(d,"muted");List<String> keys=new ArrayList<>();styles.keys().forEachRemaining(keys::add);Collections.sort(keys);
        for(String k:keys){if(muted.length()>=12)break;if(styles.optBoolean(k))muted.put(AIRecommendations.clipped(k,30));}
        if(favorites.length()==0&&listening.length()==0)return null;
        return object("favorites",favorites,"listening",listening,"muted_styles",muted);
    }
    private static JSONObject aiSignal(JSONObject track){
        return object("title",AIRecommendations.clipped(text(track,"title"),60),"artist",AIRecommendations.clipped(text(track,"artist"),60),
                "choices",0,"replays",0,"completions",0,"quick_skips",0);
    }
    static synchronized JSONArray recommend(Context ctx,List<JSONObject> candidates){
        return recommend(ctx,candidates,24);
    }
    static synchronized JSONArray recommend(Context ctx,List<JSONObject> candidates,int limit){
        JSONObject d=data(ctx);
        Map<String,Double> w=weights(d),artist=new HashMap<>(),genre=new HashMap<>(),scores=new HashMap<>();
        JSONObject tagMap=map(d,"genres"),hidden=map(d,"hidden"),muted=map(d,"muted");
        for(JSONObject t:known(d)){
            String key=id(t);double value=Math.min(7,Math.max(-3,w.getOrDefault(key,0.0)));
            artist.merge(text(t,"artist").toLowerCase(Locale.ROOT),value,Double::sum);
            JSONArray tags=tagMap.optJSONArray(key);if(tags==null)tags=array(t,"genres");
            for(int i=0;i<tags.length();i++)genre.merge(tags.optString(i).toLowerCase(Locale.ROOT),value,Double::sum);
        }
        List<JSONObject> songs=new ArrayList<>();addUnique(songs,candidates);songs.removeIf(t->hidden.optBoolean(id(t)));
        if(!d.optBoolean("trackingEnabled",true))return new JSONArray(songs.subList(0,Math.min(limit,songs.size())));
        Set<String> recent=new HashSet<>();for(JSONObject t:list(d,"recent")){recent.add(id(t));if(recent.size()>=8)break;}
        for(int i=0;i<songs.size();i++){
            JSONObject t=songs.get(i);String key=id(t);JSONArray tags=tagMap.optJSONArray(key);if(tags==null)tags=array(t,"genres");
            double style=0;boolean silenced=false;
            for(int j=0;j<tags.length();j++){String tag=tags.optString(j).toLowerCase(Locale.ROOT);style=Math.max(style,genre.getOrDefault(tag,0.0));silenced|=muted.optBoolean(tag);}
            boolean skipped=System.currentTimeMillis()-skips.getOrDefault(key,0L)<3600000;
            double score=Math.min(4,artist.getOrDefault(text(t,"artist").toLowerCase(Locale.ROOT),0.0))+Math.min(3,style)*0.7+
                    2.0/(i+1)-(skipped?12:recent.contains(key)?4:0)-(silenced?12:0);
            scores.put(key,score);
        }
        songs.sort((a,b)->Double.compare(scores.get(id(b)),scores.get(id(a))));
        Map<String,Integer> counts=new HashMap<>();List<JSONObject> first=new ArrayList<>(),extras=new ArrayList<>();
        for(JSONObject t:songs){String k=text(t,"artist").toLowerCase(Locale.ROOT);int n=counts.getOrDefault(k,0);
            (n<2?first:extras).add(t);counts.put(k,n+1);}
        first.addAll(extras);return discoveryOrder(ctx,new JSONArray(first),limit);
    }
}
