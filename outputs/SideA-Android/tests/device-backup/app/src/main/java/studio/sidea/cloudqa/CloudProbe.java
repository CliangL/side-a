package studio.sidea.cloudqa;
import android.app.*;
import android.content.*;
import android.os.*;
import android.webkit.WebView;
import android.view.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.concurrent.*;
import java.lang.reflect.*;

public final class CloudProbe extends Instrumentation {
    Bundle opts,out=new Bundle();Context app;SharedPreferences evidence;Class<?> library,central,cloud,merge;
    WebView web;
    @Override public void onCreate(Bundle options){super.onCreate(options);opts=options;start();}
    static JSONObject obj(Object... args)throws Exception{JSONObject x=new JSONObject();for(int i=0;i<args.length;i+=2)x.put((String)args[i],args[i+1]);return x;}
    Method method(Class<?> c,String n,Class<?>... t)throws Exception{Method m=c.getDeclaredMethod(n,t);m.setAccessible(true);return m;}
    Object call(Class<?> c,String n,Class<?>[] t,Object... a)throws Exception{return method(c,n,t).invoke(null,a);}
    void check(boolean yes,String message)throws Exception{if(!yes)throw new Exception(message);}
    JSONObject copy(JSONObject x)throws Exception{return new JSONObject(x.toString());}
    boolean same(Object a,Object b)throws Exception{return (boolean)call(merge,"same",new Class[]{Object.class,Object.class},a,b);}
    JSONObject combine(JSONObject b,JSONObject l,JSONObject r)throws Exception{return (JSONObject)call(merge,"merge",new Class[]{JSONObject.class,JSONObject.class,JSONObject.class},b,l,r);}
    JSONObject track(String suffix)throws Exception{return obj("source","qq","trackID","qa-cloud-"+suffix,"title","设备恢复测试 "+suffix,"artist","Side A QA","album","验证","centralCatalog",true,"apiEndpoint","https://music.cliang.top/v1/music");}
    JSONObject snap(JSONObject rows)throws Exception{return obj("schema",1,"platform","android","library",rows,"settings",obj());}
    JSONArray arr(Object... a){JSONArray rows=new JSONArray();for(Object x:a)rows.put(x);return rows;}
    void tests()throws Exception{
        JSONObject a=track("A"),b=track("B"),c=track("C"),base=snap(obj("favorites",arr(a),"playlists",arr(obj("id","p","name","旧名称","tracks",arr(a,b)))));
        check(same(combine(obj(),snap(obj()),base),base),"empty reinstall replaced remote backup");
        JSONObject local=copy(base),remote=copy(base);local.getJSONObject("library").put("favorites",arr());remote.getJSONObject("library").put("favorites",arr(a,c));
        JSONArray merged=combine(base,local,remote).getJSONObject("library").getJSONArray("favorites");check(merged.length()==1&&merged.getJSONObject(0).getString("trackID").equals(c.getString("trackID")),"deleted favorite resurrected");
        local=copy(base);remote=copy(base);local.getJSONObject("library").put("playlists",arr());remote.getJSONObject("library").getJSONArray("playlists").getJSONObject(0).put("name","另一安装修改");
        check(combine(base,local,remote).getJSONObject("library").getJSONArray("playlists").length()==0,"deleted playlist resurrected");
        local=copy(base);remote=copy(base);local.getJSONObject("library").getJSONArray("playlists").getJSONObject(0).put("name","我的名称");remote.getJSONObject("library").getJSONArray("playlists").getJSONObject(0).put("tracks",arr(b,a,c));
        JSONObject pl=combine(base,local,remote).getJSONObject("library").getJSONArray("playlists").getJSONObject(0);check(pl.getString("name").equals("我的名称")&&pl.getJSONArray("tracks").length()==3&&same(pl.getJSONArray("tracks").get(0),b),"independent playlist edits lost");
        base=snap(obj("history",arr(obj("day",123,"id","qq:A","choices",1))));local=snap(obj());remote=snap(obj("history",arr(obj("day",123,"id","qq:A","choices",2))));
        check(!combine(base,local,remote).getJSONObject("library").has("history"),"preference reset resurrected old history");
        base=snap(obj("favorites",arr(a)));local=snap(obj("favorites",arr(b,a)));remote=snap(obj("favorites",arr(c,a)));
        check(combine(base,local,remote).getJSONObject("library").getJSONArray("favorites").length()==3,"concurrent additions lost");
        base=snap(obj());base.put("settings",obj("preferLossless",true));local=copy(base);local.getJSONObject("settings").put("preferLossless",false);remote=copy(base);remote.getJSONObject("settings").put("cellularDataSaver",false);
        JSONObject settings=combine(base,local,remote).getJSONObject("settings");check(!settings.getBoolean("preferLossless")&&!settings.getBoolean("cellularDataSaver"),"independent preferences lost");
        Class<?> sources=app.getClassLoader().loadClass("studio.sidea.android.MusicSource");
        for(String address:new String[]{"https://kw-sycdn.kuwo.cn/fixture.mp3","https://KW-SYCDN.KUWO.CN/fixture.mp3"})
            check("https://www.kuwo.cn/".equals(call(sources,"mediaReferer",new Class[]{String.class,String.class},address,"fallback")),"Kuwo public header absent");
        for(String address:new String[]{"https://kw-sycdn.kuwo.cn.evil.example/fixture.mp3","https://kw-sycdn.kuwo.cn@evil.example/fixture.mp3","https://other.kuwo.cn/fixture.mp3"})
            check("fallback".equals(call(sources,"mediaReferer",new Class[]{String.class,String.class},address,"fallback")),"Kuwo header escaped host allowlist");
        out.putString("merge","7 restore/deletion/reorder/concurrency/preference assertions passed");
        out.putString("headers","5 real/lookalike-domain public-header assertions passed");
    }
    void setState(JSONObject data,JSONObject base)throws Exception{
        app.getSharedPreferences("sidea.library",0).edit().putString("collection",data.toString()).putString("cloudBase",base.toString()).putLong("cloudRevision",1).commit();
        for(String key:new String[]{"state","acknowledgedBase"}){Field f=library.getDeclaredField(key);f.setAccessible(true);f.set(null,null);}
    }
    JSONObject mergeCloud(Context ctx,JSONObject remote,long version)throws Exception{return (JSONObject)call(library,"mergeCloud",new Class[]{Context.class,JSONObject.class,long.class},ctx,remote,version);}
    void persistenceTests()throws Exception{
        Field executorField=cloud.getDeclaredField("worker");executorField.setAccessible(true);
        CountDownLatch started=new CountDownLatch(1),blocked=new CountDownLatch(1);
        ((ScheduledExecutorService)executorField.get(null)).submit(()->{started.countDown();try{blocked.await();}catch(InterruptedException ignored){}});
        check(started.await(3,TimeUnit.SECONDS),"backup worker not isolated");
        SharedPreferences disk=app.getSharedPreferences("sidea.library",0),settingsDisk=app.getSharedPreferences("sidea.settings",0);
        java.util.Map<String,?> old=new java.util.HashMap<>(disk.getAll()),oldSettings=new java.util.HashMap<>(settingsDisk.getAll());
        try{
            JSONObject a=track("A"),b=track("B"),c=track("C"),base=snap(obj("favorites",arr(a))),remote=snap(obj("favorites",arr()));
            Context failed=new ContextWrapper(app){
                @Override public SharedPreferences getSharedPreferences(String name,int mode){
                    SharedPreferences actual=super.getSharedPreferences(name,mode);if(!name.equals("sidea.library"))return actual;
                    return (SharedPreferences)java.lang.reflect.Proxy.newProxyInstance(getClassLoader(),new Class[]{SharedPreferences.class},(proxy,m,args)->{
                        Object value=m.invoke(actual,args);
                        if(!m.getName().equals("edit"))return value;
                        SharedPreferences.Editor editor=(SharedPreferences.Editor)value;
                        return java.lang.reflect.Proxy.newProxyInstance(getClassLoader(),new Class[]{SharedPreferences.Editor.class},(ep,em,ea)->{
                            Object result=em.invoke(editor,ea);if(em.getName().equals("commit"))return false;
                            return result instanceof SharedPreferences.Editor?ep:result;
                        });
                    });
                }
            };
            setState(base.getJSONObject("library"),base);
            try{mergeCloud(failed,remote,2);throw new Exception("expected failed commit");}catch(InvocationTargetException expected){check(expected.getCause() instanceof IOException,"unexpected write error");}
            check(mergeCloud(app,remote,2).getJSONObject("library").getJSONArray("favorites").length()==0,"failed commit advanced base and resurrected deletion");
            setState(base.getJSONObject("library"),base);
            try{call(library,"acknowledgeCloud",new Class[]{Context.class,JSONObject.class,long.class},failed,remote,2L);throw new Exception("expected failed acknowledge");}catch(InvocationTargetException expected){check(expected.getCause() instanceof IOException,"unexpected acknowledge error");}
            check(same(call(library,"cloudBase",new Class[]{Context.class},app),base),"failed acknowledge advanced in-memory base");
            setState(base.getJSONObject("library"),base);
            check(same(mergeCloud(app,obj(),0).getJSONObject("library"),base.getJSONObject("library")),"absent remote profile erased existing local data");
            for(boolean missing:new boolean[]{false,true}){
                setState(base.getJSONObject("library"),base);
                SharedPreferences.Editor ed=disk.edit();if(missing)ed.remove("collection");else ed.putString("collection","not json");ed.commit();
                action(obj("op","favorite","track",b));
                JSONArray rows=mergeCloud(app,base,1).getJSONObject("library").getJSONArray("favorites");
                check(rows.length()==2&&rows.toString().contains("qa-cloud-A")&&rows.toString().contains("qa-cloud-B"),"damaged/missing collection recovery discarded post-recovery edit");
            }
            setState(base.getJSONObject("library"),base);JSONObject sent=mergeCloud(app,base,1);
            action(obj("op","favorite","track",c));
            call(library,"acknowledgeCloud",new Class[]{Context.class,JSONObject.class,long.class},app,sent,2L);
            check((boolean)call(library,"cloudDirty",new Class[]{Context.class},app)&&capture().getJSONObject("library").getJSONArray("favorites").length()==2,"acknowledgment discarded in-flight local edit");
            out.putString("persistence","6 failed-write/corrupt/missing/empty-remote/in-flight-edit assertions passed");
        }finally{
            for(SharedPreferences store:new SharedPreferences[]{disk,settingsDisk}){
            SharedPreferences.Editor ed=store.edit().clear();for(java.util.Map.Entry<String,?> item:(store==disk?old:oldSettings).entrySet()){
                Object v=item.getValue();if(v instanceof String)ed.putString(item.getKey(),(String)v);else if(v instanceof Long)ed.putLong(item.getKey(),(Long)v);else if(v instanceof Integer)ed.putInt(item.getKey(),(Integer)v);else if(v instanceof Boolean)ed.putBoolean(item.getKey(),(Boolean)v);
            }ed.commit();}
            for(String key:new String[]{"state","acknowledgedBase"}){Field f=library.getDeclaredField(key);f.setAccessible(true);f.set(null,null);}
        }
    }
    void action(JSONObject args)throws Exception{call(library,"action",new Class[]{Context.class,JSONObject.class},app,args);}
    JSONObject capture()throws Exception{return (JSONObject)call(library,"cloudSnapshot",new Class[]{Context.class},app);}
    String digest(String input)throws Exception{byte[] d=MessageDigest.getInstance("SHA-256").digest(input.getBytes(StandardCharsets.UTF_8));StringBuilder b=new StringBuilder();for(byte x:d)b.append(String.format("%02x",x&255));return b.toString();}
    String identityFile()throws Exception{return new String(java.nio.file.Files.readAllBytes(new File(app.getNoBackupFilesDir(),"central-installation").toPath()),StandardCharsets.US_ASCII);}
    String tokenDigest()throws Exception{return digest(app.getSharedPreferences("sidea.settings",0).getString("centralSecret",""));}
    Object reply(String method,String path,JSONObject body)throws Exception{return call(central,"library",new Class[]{Context.class,String.class,String.class,JSONObject.class},app,method,path,body);}
    JSONObject body(Object reply)throws Exception{Field f=reply.getClass().getDeclaredField("body");f.setAccessible(true);return (JSONObject)f.get(reply);}
    int status(Object reply)throws Exception{Field f=reply.getClass().getDeclaredField("status");f.setAccessible(true);return (int)f.get(reply);}
    void startCloud()throws Exception{call(cloud,"start",new Class[]{Context.class},app);}
    void waitBackup()throws Exception{
        long end=SystemClock.elapsedRealtime()+75000;
        while(SystemClock.elapsedRealtime()<end){
            if(app.getSharedPreferences("sidea.library",0).getLong("cloudRevision",0)>0&&!(boolean)call(library,"cloudDirty",new Class[]{Context.class},app))return;
            Thread.sleep(250);
        }throw new Exception("Backup didn't become acknowledged; no credentials logged");
    }
    void seedOld()throws Exception{
        check(app.getPackageManager().getPackageInfo(app.getPackageName(),0).versionName.equals("0.4.4"),"upgrade fixture must begin at 0.4.4");
        call(central,"enrollIfNeeded",new Class[]{Context.class},app);
        check(!app.getSharedPreferences("sidea.settings",0).getString("centralBase","").isEmpty(),"old install enrollment failed");
        app.getSharedPreferences("sidea.library",0).edit().clear().commit();
        JSONObject a=track("A"),b=track("B");
        action(obj("op","favorite","track",a));action(obj("op","create","name","旧版的私人歌单","tracks",arr(a,b)));
        for(String event:new String[]{"manualPlay","replay","complete"})call(library,"record",new Class[]{Context.class,JSONObject.class,String.class,double.class,double.class},app,a,event,150.0,180.0);
        call(library,"record",new Class[]{Context.class,JSONObject.class,String.class,double.class,double.class},app,b,"skip",3.0,180.0);
        action(obj("op","dislike","track",b));action(obj("op","reduceStyle","track",b,"tags",arr("fixture-rock")));
        app.getSharedPreferences("sidea.settings",0).edit().putBoolean("preferLossless",false).putBoolean("cellularDataSaver",false).commit();
        String raw=app.getSharedPreferences("sidea.library",0).getString("collection","");
        check(app.getSharedPreferences("sidea.library",0).edit().putString("collection",raw).commit(),"old fixture flush failed");
        evidence.edit().putString("oldCollection",raw).putString("oldInstallation",digest(identityFile())).putString("oldToken",tokenDigest()).commit();
        out.putString("upgrade","0.4.4 existing UUID, credential, favorites, playlist, daily skips/replays and preferences prepared");
    }
    void upgrade()throws Exception{
        check(tokenDigest().equals(evidence.getString("oldToken","")),"upgrade replaced original credential");
        check(digest(identityFile()).equals(evidence.getString("oldInstallation","")),"upgrade replaced installation UUID");
        String current=app.getSharedPreferences("sidea.library",0).getString("collection","{}");
        check(same(new JSONObject(current),new JSONObject(evidence.getString("oldCollection","{}"))),"upgrade collection mismatch: actual "+current.length()+" chars; expected "+evidence.getString("oldCollection","").length()+" chars");
        evidence.edit().putString("recoveryDigest",digest((String)call(central,"recovery",new Class[]{Context.class},app))).commit();
        startCloud();waitBackup();
        check(same(new JSONObject(evidence.getString("oldCollection","{}")),capture().getJSONObject("library")),"backup migration altered old collection");
        evidence.edit().putString("expected",capture().toString()).commit();
        out.putString("upgrade","0.4.4 → 0.4.5 retained UUID/token and all old library/preference data; server acknowledged backup");
    }
    void restore()throws Exception{
        check(app.getSharedPreferences("sidea.library",0).getString("collection",null)==null,"uninstall did not clear local data");
        startCloud();waitBackup();
        check(!digest(identityFile()).equals(evidence.getString("oldInstallation","")),"fresh install reused old UUID");
        check(!tokenDigest().equals(evidence.getString("oldToken","")),"fresh install reused old bearer");
        check(digest((String)call(central,"recovery",new Class[]{Context.class},app)).equals(evidence.getString("recoveryDigest","")),"same-signature device recovery changed");
        check(same(capture(),new JSONObject(evidence.getString("expected","{}"))),"reinstall backup mismatch");
        out.putString("restore","Actual uninstall → reinstall restored collection + histories + preferences, with new UUID/token and unchanged device recovery");
    }
    void offline()throws Exception{
        JSONObject before=capture();evidence.edit().putString("beforeOffline",before.toString()).commit();
        action(obj("op","favorite","track",track("A")));action(obj("op","favorite","track",track("B")));
        String pid=capture().getJSONObject("library").getJSONArray("playlists").getJSONObject(0).getString("id");
        action(obj("op","rename","id",pid,"name","断网时改的名称"));action(obj("op","tracking","enabled",false));
        JSONObject now=capture();check(now.getJSONObject("library").getJSONArray("favorites").length()==1,"offline favorite edit failed");
        check((boolean)call(library,"cloudDirty",new Class[]{Context.class},app),"offline edits not pending");
        check(same(now.getJSONObject("library"),new JSONObject(app.getSharedPreferences("sidea.library",0).getString("collection","{}"))),"offline changes not durable");
        evidence.edit().putString("offline",now.toString()).commit();
        out.putString("offline","Favorite deletion/addition, playlist rename and tracking choice saved locally while network blocked");
    }
    void conflict()throws Exception{
        check(same(capture(),new JSONObject(evidence.getString("offline","{}"))),"process restart lost offline changes");
        JSONObject before=body(reply("GET","/v1/library",null));JSONObject remote=copy(before.getJSONObject("data"));
        remote.getJSONObject("library").getJSONArray("favorites").put(track("C"));
        remote.getJSONObject("library").getJSONArray("playlists").getJSONObject(0).put("cover",track("A"));
        Object write=reply("PUT","/v1/library",obj("revision",before.getLong("revision"),"data",remote));check(status(write)==200,"competing remote edit failed");
        Object stale=reply("PUT","/v1/library",obj("revision",before.getLong("revision"),"data",new JSONObject(evidence.getString("offline","{}"))));
        check(status(stale)==409&&body(stale).getLong("revision")>before.getLong("revision"),"CAS did not reject stale upload");
        startCloud();waitBackup();JSONObject combined=capture().getJSONObject("library"),pl=combined.getJSONArray("playlists").getJSONObject(0);
        String favs=combined.getJSONArray("favorites").toString();check(!favs.contains("qa-cloud-A")&&favs.contains("qa-cloud-B")&&favs.contains("qa-cloud-C"),"conflict lost favorites or resurrected deletion");
        check(pl.getString("name").equals("断网时改的名称")&&pl.getJSONObject("cover").getString("trackID").equals("qa-cloud-A"),"playlist merge lost independent edit");
        check(!combined.getBoolean("trackingEnabled"),"offline preference overwritten");
        evidence.edit().putString("expected",capture().toString()).commit();
        out.putString("conflict","Offline edits survived restart and merged remote changes; stale CAS rejected; deleted favorite stayed deleted");
    }
    WebView find(View root){if(root instanceof WebView)return (WebView)root;if(root instanceof ViewGroup){ViewGroup group=(ViewGroup)root;for(int i=0;i<group.getChildCount();i++){WebView found=find(group.getChildAt(i));if(found!=null)return found;}}return null;}
    String js(String script)throws Exception{CountDownLatch latch=new CountDownLatch(1);String[] answer={""};runOnMainSync(()->web.evaluateJavascript(script,value->{answer[0]=value;latch.countDown();}));check(latch.await(8,TimeUnit.SECONDS),"JS timeout");return answer[0];}
    void waitJS(String condition,int seconds)throws Exception{long until=SystemClock.elapsedRealtime()+1000L*seconds;while(SystemClock.elapsedRealtime()<until){if("true".equals(js("!!("+condition+")")))return;Thread.sleep(250);}throw new Exception("UI condition timed out: "+condition);}
    void sources()throws Exception{
        Activity activity=startActivitySync(new Intent().setClassName("studio.sidea.android","studio.sidea.android.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        runOnMainSync(()->web=find(activity.getWindow().getDecorView()));waitJS("st.starter.length===6 && st.settings.centralBase==='https://music.cliang.top'",40);
        js("actions.search()");waitJS("document.getElementById('searchScopes')",5);
        check("true".equals(js("['all','qq','wy','kw','jx'].every(s=>document.querySelector('[data-act=selectSource][data-arg='+s+']'))")),"source tabs missing");
        for(String provider:new String[]{"qq","wy","kw","jx"}){
            js("document.querySelector('[data-act=selectSource][data-arg="+provider+"]').click()");
            waitJS("st.settings.searchSource==='"+provider+"'",5);
            String query=provider.equals("kw")?"卡农":"hello";
            js("var q=document.getElementById('query');q.value="+JSONObject.quote(query)+";q.dispatchEvent(new Event('input',{bubbles:true}))");
            waitJS("current().q==="+JSONObject.quote(query)+" && current().items?.length>0 && !current().busy",70);
            check("true".equals(js("current().items.every(t=>t.centralCatalog && t.trackID.startsWith('"+provider+".'))")),"source leak for "+provider);
            out.putString("source-"+provider,"native search returned only selected provider");
            if(provider.equals("kw")){
                js("req('settings',{op:'set',preferLossless:false,losslessOnly:false}).then(()=>{const t=current().items.find(t=>t.trackID==='kw.Mzg2MDQ4NTIx') || {source:'central',trackID:'kw.Mzg2MDQ4NTIx',title:'卡农',artist:'',apiEndpoint:'https://music.cliang.top/v1/music',centralCatalog:true};return req('playAction',{op:'play',tracks:[t],index:0})})");
                waitJS("st.player.track?.trackID==='kw.Mzg2MDQ4NTIx' && st.player.playing && st.player.elapsed>1 && st.player.duration>240",70);
                double start=Double.parseDouble(js("st.player.elapsed"));Thread.sleep(1500);double end=Double.parseDouble(js("st.player.elapsed"));
                check(end>start,"Kuwo native audio did not advance");out.putString("kw-playback","Complete "+js("st.player.duration")+" second track progressed "+start+" → "+end+" seconds; public CDN headers only");
                js("req('playAction',{op:'pause'});if(st.playerOpen)hidePlayer()");
            }
        }
        check("true".equals(js("document.documentElement.scrollWidth<=innerWidth && el('searchScopes').getBoundingClientRect().right<=innerWidth")),"source tabs overflow phone viewport");
        js("document.querySelector('[data-act=selectSource][data-arg=qq]').click()");waitJS("st.settings.searchSource==='qq'",5);
        js("var q=document.getElementById('query');q.value='菊花台';q.dispatchEvent(new Event('input',{bubbles:true}))");
        waitJS("current().items?.some(t=>t.title==='菊花台' && /周杰[伦倫]/.test(t.artist) && t.album==='依然范特西')",70);
        js("req('settings',{op:'set',preferLossless:true,cellularDataSaver:false}).then(()=>{const song=current().items.find(t=>t.title==='菊花台'&&/周杰[伦倫]/.test(t.artist)&&t.album==='依然范特西');document.querySelector('[data-act=playRow][data-arg='+CSS.escape(key(song))+']').click()})");
        waitJS("st.player.playing && st.player.elapsed>1",70);
        double began=Double.parseDouble(js("st.player.elapsed"));Thread.sleep(1800);double later=Double.parseDouble(js("st.player.elapsed"));
        check(later>began,"native music did not advance");
        check("true".equals(js("/FLAC/.test(st.player.quality)")),"QQ original did not provide verified FLAC");
        out.putString("qq-quality", "Verified FLAC reported by the native stream probe and player");
        out.putString("native-playback","QQ original 菊花台 progressed "+began+" → "+later+" seconds inside native player");
        js("req('playAction',{op:'pause'});if(st.playerOpen)hidePlayer()");
        js("document.querySelector('[data-act=selectSource][data-arg=wy]').click()");waitJS("st.settings.searchSource==='wy'",5);
        startCloud();waitBackup();check(capture().getJSONObject("settings").getString("searchSource").equals("wy"),"search preference not backed up");
        evidence.edit().putString("expected",capture().toString()).commit();
        android.graphics.Bitmap image=getUiAutomation().takeScreenshot();
        try(FileOutputStream file=new FileOutputStream(new File(app.getExternalFilesDir(null),"source-tabs.png"))){image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,file);}image.recycle();
        out.putString("sources","source tabs working; search selection included in acknowledged backup");
    }
    @Override public void onStart(){
        try{
            check("ranchu".equals(Build.HARDWARE)||"goldfish".equals(Build.HARDWARE),"Fixture instrumentation is restricted to emulators");
            app=getTargetContext();evidence=app.getSharedPreferences("sidea.qa.evidence",0);
            File evidenceFile=new File(app.getExternalFilesDir(null),"qa-evidence.json");
            if(evidenceFile.isFile()){
                JSONObject saved=new JSONObject(new String(java.nio.file.Files.readAllBytes(evidenceFile.toPath()),StandardCharsets.UTF_8));
                SharedPreferences.Editor ed=evidence.edit();java.util.Iterator<String> keys=saved.keys();while(keys.hasNext()){String k=keys.next();ed.putString(k,saved.getString(k));}ed.commit();
            }
            library=app.getClassLoader().loadClass("studio.sidea.android.Library");central=app.getClassLoader().loadClass("studio.sidea.android.CentralCatalog");
            String mode=opts.getString("mode","unit");
            if(!mode.equals("seed")){cloud=app.getClassLoader().loadClass("studio.sidea.android.CloudLibrary");merge=app.getClassLoader().loadClass("studio.sidea.android.LibraryMerge");}
            switch(mode){case "unit":tests();persistenceTests();break;case "seed":seedOld();break;case "upgrade":upgrade();break;case "restore":restore();break;case "offline":offline();break;case "conflict":conflict();break;case "sources":sources();break;case "checkpoint":startCloud();waitBackup();evidence.edit().putString("expected",capture().toString()).commit();out.putString("checkpoint","current library and source preference acknowledged");break;default:throw new Exception("unknown mode");}
            try(FileOutputStream file=new FileOutputStream(evidenceFile)){file.write(new JSONObject(evidence.getAll()).toString().getBytes(StandardCharsets.UTF_8));}
            out.putString("result","PASS");finish(Activity.RESULT_OK,out);
        }catch(Throwable failure){Throwable t=failure;while(t.getCause()!=null)t=t.getCause();out.putString("result","FAIL");out.putString("detail",t.getClass().getSimpleName()+": "+t.getMessage());finish(Activity.RESULT_CANCELED,out);}
    }
}
