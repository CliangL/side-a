package studio.sidea.android;

import java.util.*;
import org.json.*;
import static studio.sidea.android.Json.*;

/** Three-way merge against the last acknowledged backup, including removals. */
final class LibraryMerge {
    static JSONObject copy(JSONObject value) {
        try{return new JSONObject(value.toString());}catch(JSONException e){throw new IllegalArgumentException(e);}
    }
    static boolean same(Object a,Object b) {
        if(a==JSONObject.NULL)a=null;if(b==JSONObject.NULL)b=null;
        if(a==b)return true;if(a==null||b==null)return false;
        if(a instanceof JSONObject&&b instanceof JSONObject){
            JSONObject x=(JSONObject)a,y=(JSONObject)b;if(x.length()!=y.length())return false;
            Iterator<String> keys=x.keys();while(keys.hasNext()){String k=keys.next();if(!y.has(k)||!same(x.opt(k),y.opt(k)))return false;}return true;
        }
        if(a instanceof JSONArray&&b instanceof JSONArray){
            JSONArray x=(JSONArray)a,y=(JSONArray)b;if(x.length()!=y.length())return false;
            for(int i=0;i<x.length();i++)if(!same(x.opt(i),y.opt(i)))return false;return true;
        }
        return a.equals(b);
    }
    static JSONObject merge(JSONObject base,JSONObject local,JSONObject remote) {
        return copy((JSONObject)value("",base,local,remote));
    }
    private static Object value(String path,Object base,Object local,Object remote) {
        if(same(local,base))return remote;
        if(same(remote,base)||same(local,remote))return local;
        // An explicit deletion must not be resurrected by stale edits.
        if(base!=null&&(local==null||remote==null))return null;
        if(local instanceof JSONObject&&remote instanceof JSONObject){
            JSONObject b=base instanceof JSONObject?(JSONObject)base:new JSONObject(),l=(JSONObject)local,r=(JSONObject)remote,out=new JSONObject();
            Set<String> keys=new LinkedHashSet<>();b.keys().forEachRemaining(keys::add);l.keys().forEachRemaining(keys::add);r.keys().forEachRemaining(keys::add);
            for(String key:keys){Object v=value(path+"/"+key,b.opt(key),l.opt(key),r.opt(key));if(v!=null)put(out,key,v);}return out;
        }
        if(local instanceof JSONArray&&remote instanceof JSONArray&&keyed(path))
            return arrayMerge(path,base instanceof JSONArray?(JSONArray)base:new JSONArray(),(JSONArray)local,(JSONArray)remote);
        // Daily counters are capped aggregates; replaying a backup must not double-count them.
        if(path.startsWith("/library/history/")&&local instanceof Number&&remote instanceof Number)
            return Math.max(((Number)local).longValue(),((Number)remote).longValue());
        return local;
    }
    private static boolean keyed(String path){return path.equals("/library/favorites")||path.equals("/library/recent")||path.equals("/library/playlists")||path.equals("/library/history")||path.matches("/library/playlists/[^/]+/tracks");}
    private static String key(String path,JSONObject row){
        if(path.equals("/library/history"))return row.optLong("day")+":"+text(row,"id");
        return path.equals("/library/playlists")?text(row,"id"):id(row);
    }
    private static Map<String,JSONObject> index(String path,JSONArray rows){
        Map<String,JSONObject> result=new LinkedHashMap<>();for(int i=0;i<rows.length();i++){
            JSONObject item=rows.optJSONObject(i);if(item!=null){String key=key(path,item);if(!key.isEmpty())result.put(key,item);}
        }return result;
    }
    private static JSONArray arrayMerge(String path,JSONArray base,JSONArray local,JSONArray remote){
        Map<String,JSONObject>b=index(path,base),l=index(path,local),r=index(path,remote);Set<String> order=new LinkedHashSet<>();
        // Preserve a remote reorder when this device did not reorder the collection.
        boolean changedOrder=!new ArrayList<>(l.keySet()).equals(new ArrayList<>(b.keySet()));
        order.addAll((changedOrder?l:r).keySet());order.addAll((changedOrder?r:l).keySet());
        JSONArray out=new JSONArray();for(String k:order){
            Object item=value(path+"/"+k,b.get(k),l.get(k),r.get(k));if(item!=null)out.put(item);
            if(path.equals("/library/recent")&&out.length()>=100)break;
        }return out;
    }
    private LibraryMerge(){}
}
