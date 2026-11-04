package studio.sidea.android;
import android.content.Context;
import org.json.*;
import static studio.sidea.android.Json.*;
final class Library {
 static volatile int plays=1;static volatile boolean enabled=true;static volatile String hidden="";
 static JSONObject aiProfile(Context ctx){return enabled?object("plays",plays):null;}
 static JSONArray aiAllowed(Context ctx,JSONArray candidates){JSONArray out=new JSONArray();for(JSONObject track:rows(candidates))if(!id(track).equals(hidden))out.put(track);return out;}
}
