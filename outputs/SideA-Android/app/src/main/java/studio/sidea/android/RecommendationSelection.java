package studio.sidea.android;
import java.util.*;
import org.json.*;
import static studio.sidea.android.Json.*;
final class RecommendationSelection {
 static String key(JSONObject t){return text(t,"title").toLowerCase(Locale.ROOT).replaceAll("[^\\p{L}\\p{N}]","")+"|"+text(t,"artist").toLowerCase(Locale.ROOT).replaceAll("[^\\p{L}\\p{N}]","");}
 static JSONArray order(JSONArray tracks,Set<String> known,Set<String> shown,int limit){
  Set<String> seen=new HashSet<>();List<JSONObject> unseen=new ArrayList<>(),previous=new ArrayList<>();
  for(JSONObject t:rows(tracks))if(seen.add(key(t)))(shown.contains(key(t))?previous:unseen).add(t);
  List<JSONObject> result=new ArrayList<>();
  for(List<JSONObject> pool:Arrays.asList(unseen,previous)){
   List<JSONObject> fresh=new ArrayList<>(),familiar=new ArrayList<>();
   for(JSONObject t:pool)(known.contains(key(t))?familiar:fresh).add(t);
   int n=0,f=0,slot=0;
   while(result.size()<limit&&(n<fresh.size()||f<familiar.size())){
    if(n<fresh.size()&&(slot%4!=3||f>=familiar.size()))result.add(fresh.get(n++));
    else if(f<familiar.size())result.add(familiar.get(f++));
    slot++;
   }
  }
  return new JSONArray(result);
 }
 private RecommendationSelection(){}
}
