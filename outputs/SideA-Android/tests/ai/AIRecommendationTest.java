package studio.sidea.android;
import android.content.Context;
import java.lang.reflect.Field;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.*;
import static studio.sidea.android.Json.*;

public final class AIRecommendationTest {
 private static void check(boolean yes,String detail){if(!yes)throw new AssertionError(detail);}
 private static boolean busy()throws Exception{Field field=AIRecommendations.class.getDeclaredField("busy");field.setAccessible(true);synchronized(AIRecommendations.class){return field.getBoolean(null);}}
 private static void idle()throws Exception{long end=System.currentTimeMillis()+3000;while(busy()&&System.currentTimeMillis()<end)Thread.sleep(5);check(!busy(),"worker must finish");}
 private static void probeNow(Context ctx)throws Exception{Field field=AIRecommendations.class.getDeclaredField("nextProbe");field.setAccessible(true);synchronized(AIRecommendations.class){field.setLong(null,0);}AIRecommendations.refreshIfDue(ctx);idle();}
 public static void main(String[] args)throws Exception{
  try{
   Context ctx=new Context();AtomicInteger updated=new AtomicInteger();
   JSONArray tracks=new JSONArray().put(object("source","netease","trackID","a","title","A","artist","Artist"))
    .put(object("source","netease","trackID","b","title","B","artist","Artist"));
   AIRecommendations.ranked(ctx,tracks);
   AIRecommendations.setActive(ctx,true,updated::incrementAndGet);idle();
   check(CentralCatalog.modelCalls.get()==1,"first active run invokes model once");
   check(id(AIRecommendations.ranked(ctx,tracks).getJSONObject(0)).equals("netease:b"),"model ranking is displayed");
   Library.plays++;
   check(id(AIRecommendations.ranked(ctx,tracks).getJSONObject(0)).equals("netease:b"),"new listening must keep previous AI order");
   probeNow(ctx);
   check(CentralCatalog.modelCalls.get()==1,"normal change respects model cooldown");
   Library.hidden="netease:b";
   check(AIRecommendations.ranked(ctx,tracks).length()==1,"hidden song cannot return from old AI cache");
   Library.hidden="";CentralCatalog.revision="c".repeat(64);CentralCatalog.preferred="a";
   probeNow(ctx);
   check(CentralCatalog.modelCalls.get()==2,"new central model bypasses old cooldown");
   check(id(AIRecommendations.ranked(ctx,tracks).getJSONObject(0)).equals("netease:a"),"new model order replaces old cache");
   int probes=CentralCatalog.probes.get();
   AIRecommendations.setActive(ctx,false,null);probeNow(ctx);
   check(CentralCatalog.probes.get()==probes,"background app must not probe or generate");
   CentralCatalog.revision="d".repeat(64);CentralCatalog.slow=true;CentralCatalog.preferred="b";
   AIRecommendations.setActive(ctx,true,updated::incrementAndGet);idle();
   int slowPosts=CentralCatalog.modelCalls.get();
   check(!ctx.getSharedPreferences("sidea.ai",0).getString("pending","").isEmpty(),"queued job ID and input must be durable");
   probeNow(ctx);
   check(CentralCatalog.polls.get()==1&&CentralCatalog.modelCalls.get()==slowPosts,"running job uses GET despite cooldown");
   CentralCatalog.offline=true;probeNow(ctx);CentralCatalog.offline=false;
   check(!ctx.getSharedPreferences("sidea.ai",0).getString("pending","").isEmpty(),"network outage keeps pending ID");
   AIRecommendations.setActive(ctx,false,null);CentralCatalog.finished=true;
   Field revision=AIRecommendations.class.getDeclaredField("revision");revision.setAccessible(true);revision.set(null,null);
   AIRecommendations.setActive(ctx,true,updated::incrementAndGet);idle();
   check(CentralCatalog.modelCalls.get()==slowPosts,"background/restart recovery must not create another model task");
   check(ctx.getSharedPreferences("sidea.ai",0).getString("pending","").isEmpty(),"completed pending job is cleared");
   check(id(AIRecommendations.ranked(ctx,tracks).getJSONObject(0)).equals("netease:b"),"slow completed result displays immediately on resume");
   CentralCatalog.revision="e".repeat(64);CentralCatalog.finished=false;probeNow(ctx);
   JSONObject expired=new JSONObject(ctx.getSharedPreferences("sidea.ai",0).getString("pending","{}"));put(expired,"created",1);
   ctx.getSharedPreferences("sidea.ai",0).edit().putString("pending",expired.toString()).commit();
   CentralCatalog.cancelOffline=true;probeNow(ctx);
   check(!ctx.getSharedPreferences("sidea.ai",0).getString("pending","").isEmpty(),"uncertain cancellation must keep ID for retry");
   CentralCatalog.enabled=false;probeNow(ctx);
   check(ctx.getSharedPreferences("sidea.ai",0).getString("result","").isEmpty(),"disabled app clears visible ranking even if cancellation is unavailable");
   CentralCatalog.enabled=true;CentralCatalog.cancelOffline=false;probeNow(ctx);
   check(CentralCatalog.cancels.get()==1,"expired task is cancelled before forgetting its ID");
   AIRecommendations.setActive(ctx,false,null);
   Library.enabled=false;AIRecommendations.reset(ctx);
   check(!ctx.getSharedPreferences("sidea.ai",0).getString("result","").contains("ranked"),"disabling/reset removes cache");
   check(AIRecommendations.ranked(ctx,tracks).length()==2,"local recommendations remain usable");
   System.out.println("AI lifecycle: cold start, changed history, cooldown, exclusions, model switch, slow pending persistence, network outage and background resume passed");
  }catch(Throwable failure){failure.printStackTrace();System.exit(1);}
  System.exit(0);
 }
}
