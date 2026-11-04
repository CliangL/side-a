package studio.sidea.android;
import android.content.Context;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.*;
import static studio.sidea.android.Json.*;
final class CentralCatalog {
 static volatile boolean slow,finished,offline,cancelOffline;
 static volatile boolean enabled=true;
 static volatile String revision="a".repeat(64),preferred="b";
 static final AtomicInteger modelCalls=new AtomicInteger(),probes=new AtomicInteger(),polls=new AtomicInteger(),cancels=new AtomicInteger();
 static boolean cancelAI(Context ctx,String id){if(cancelOffline)return false;ai(ctx,"POST","/v1/ai/tasks/"+id+"/cancel",new JSONObject());return true;}
 static JSONObject ai(Context ctx,String method,String path,JSONObject input){
  if(offline)throw new IllegalStateException("synthetic offline");
  if(path.endsWith("/config")){probes.incrementAndGet();return object("config",object("revision",revision,"enabled",enabled));}
  if(path.endsWith("/cancel")){cancels.incrementAndGet();return object("task",object("id","synthetic-task","status","cancelled"));}
  if(method.equals("POST"))modelCalls.incrementAndGet();else polls.incrementAndGet();
  if(slow&&!finished)return object("task",object("id","synthetic-task","status",method.equals("POST")?"queued":"running"));
  return object("task",object("id","synthetic-task","status","succeeded","result",object("profile_summary","synthetic",
   "ranked",new JSONArray().put(object("id",AIRecommendations.hash("netease:"+preferred),"reason","synthetic")))));
 }
}
