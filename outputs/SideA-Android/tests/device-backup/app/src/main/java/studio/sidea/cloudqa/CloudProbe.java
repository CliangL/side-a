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
            JSONObject soundRemote=snap(obj("favorites",arr(a)));soundRemote.put("settings",obj("soundPreset","night"));
            settingsDisk.edit().remove("soundPreset").commit();setState(obj(),obj());
            check(mergeCloud(app,soundRemote,1).getJSONObject("settings").getString("soundPreset").equals("soft")&&settingsDisk.getString("soundPreset","").equals("soft"),"sound selection not restored");
            settingsDisk.edit().putString("soundPreset","vocal").commit();
            JSONObject other=copy(soundRemote);other.getJSONObject("settings").put("searchSource","kw");
            JSONObject soundMerged=mergeCloud(app,other,2).getJSONObject("settings");
            check(soundMerged.getString("soundPreset").equals("vocal")&&soundMerged.getString("searchSource").equals("kw"),"local sound choice lost during independent remote change");
            out.putString("persistence","8 failed-write/corrupt/missing/empty-remote/in-flight-edit/sound-restore assertions passed");
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
    void sound()throws Exception{
        // Generated PCM fixture: no network, accounts, library, or personal media.
        File tone=new File(app.getCacheDir(),"sound-test.wav");
        int rate=48000,frames=rate*3;java.nio.ByteBuffer bytes=java.nio.ByteBuffer.allocate(44+frames*2).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        bytes.put("RIFF".getBytes(StandardCharsets.US_ASCII)).putInt(36+frames*2).put("WAVEfmt ".getBytes(StandardCharsets.US_ASCII));
        bytes.putInt(16).putShort((short)1).putShort((short)1).putInt(rate).putInt(rate*2).putShort((short)2).putShort((short)16);
        bytes.put("data".getBytes(StandardCharsets.US_ASCII)).putInt(frames*2);
        for(int n=0;n<frames;n++){double t=n/(double)rate;bytes.putShort((short)(1600*(Math.sin(2*Math.PI*63*t)+Math.sin(2*Math.PI*1000*t)+Math.sin(2*Math.PI*4000*t))));}
        java.nio.file.Files.write(tone.toPath(),bytes.array());
        Class<?> wrapper=app.getClassLoader().loadClass("studio.sidea.android.AndroidSoundEffects"),control=app.getClassLoader().loadClass("studio.sidea.android.SoundEffects"),volumeClass=app.getClassLoader().loadClass("studio.sidea.android.SoundEffects$Volume");
        Object effects=call(wrapper,"create",new Class[]{});
        Method attach=method(control,"attach",int.class,volumeClass),select=method(control,"select",String.class),state=method(control,"status"),detach=method(control,"detach");
        android.media.MediaPlayer player=new android.media.MediaPlayer(),next=null;
        android.media.audiofx.Equalizer competitor=null;
        try{
            player.setAudioAttributes(new android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA).setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC).build());
            player.setDataSource(tone.getAbsolutePath());player.prepare();player.setLooping(true);player.start();
            Object gain=java.lang.reflect.Proxy.newProxyInstance(app.getClassLoader(),new Class[]{volumeClass},(p,m,a)->{player.setVolume((float)a[0],(float)a[0]);return null;});
            attach.invoke(effects,player.getAudioSessionId(),gain);check(state.invoke(effects).equals("off"),"original did not bypass effect");
            for(String id:new String[]{"vocal","bass","soft","commute","night"}){
                select.invoke(effects,id);check(state.invoke(effects).equals("active"),"device could not activate "+id+" effect");
            }
            int position=player.getCurrentPosition();Thread.sleep(700);check(player.isPlaying()&&player.getCurrentPosition()!=position,"effect selection interrupted native audio");
            competitor=new android.media.audiofx.Equalizer(100,player.getAudioSessionId());Thread.sleep(150);
            check(competitor.hasControl(),"higher priority test effect did not gain control");
            check((boolean)method(control,"check").invoke(effects)&&state.invoke(effects).equals("unavailable"),"lost hardware control reported false success");
            competitor.release();competitor=null;select.invoke(effects,"commute");check(state.invoke(effects).equals("active"),"effect did not recover control");
            player.pause();detach.invoke(effects);check(state.invoke(effects).equals("pending"),"pause failed to release effect");
            attach.invoke(effects,player.getAudioSessionId(),gain);player.start();check(state.invoke(effects).equals("active"),"resume failed to restore effect");
            detach.invoke(effects);player.stop();
            next=new android.media.MediaPlayer();next.setDataSource(tone.getAbsolutePath());next.prepare();
            android.media.MediaPlayer nextPlayer=next;
            Object nextGain=java.lang.reflect.Proxy.newProxyInstance(app.getClassLoader(),new Class[]{volumeClass},(p,m,a)->{nextPlayer.setVolume((float)a[0],(float)a[0]);return null;});
            check(next.getAudioSessionId()!=player.getAudioSessionId(),"new test player must have a new session");
            attach.invoke(effects,next.getAudioSessionId(),nextGain);next.start();check(state.invoke(effects).equals("active"),"next song lost chosen effect");
            select.invoke(effects,"original");check(state.invoke(effects).equals("off"),"original did not release native effect");
            out.putString("sound","5 real session EQ curves applied/read back; audio advanced; control loss fell back; pause/resume/new-session/original succeeded");
        }finally{
            detach.invoke(effects);if(competitor!=null)competitor.release();player.release();if(next!=null)next.release();tone.delete();
        }
    }
    void spatial()throws Exception{
        File tone=new File(app.getCacheDir(),"spatial-test.wav");
        int rate=48000,frames=rate*2;java.nio.ByteBuffer bytes=java.nio.ByteBuffer.allocate(44+frames*4).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        bytes.put("RIFF".getBytes(StandardCharsets.US_ASCII)).putInt(36+frames*4).put("WAVEfmt ".getBytes(StandardCharsets.US_ASCII));
        bytes.putInt(16).putShort((short)1).putShort((short)2).putInt(rate).putInt(rate*4).putShort((short)4).putShort((short)16);
        bytes.put("data".getBytes(StandardCharsets.US_ASCII)).putInt(frames*4);
        for(int n=0;n<frames;n++){bytes.putShort((short)(1800*Math.sin(2*Math.PI*440*n/rate)));bytes.putShort((short)(1800*Math.sin(2*Math.PI*660*n/rate)));}
        java.nio.file.Files.write(tone.toPath(),bytes.array());
        Class<?> wrapper=app.getClassLoader().loadClass("studio.sidea.android.AndroidSoundEffects"),control=app.getClassLoader().loadClass("studio.sidea.android.SoundEffects"),volumeClass=app.getClassLoader().loadClass("studio.sidea.android.SoundEffects$Volume"),auxClass=app.getClassLoader().loadClass("studio.sidea.android.SoundEffects$Aux");
        Object effects=call(wrapper,"create",new Class[]{});
        Method attach=method(control,"attach",int.class,volumeClass,auxClass),select=method(control,"select",String.class),state=method(control,"status"),detach=method(control,"detach"),checkState=method(control,"check");
        android.media.MediaPlayer player=new android.media.MediaPlayer();final float[] send={0};final int[] effectID={0};
        android.media.audiofx.EnvironmentalReverb occupiedRoom=null;android.media.audiofx.PresetReverb occupiedPreset=null;
        try{
            player.setDataSource(tone.getAbsolutePath());player.prepare();player.setLooping(true);player.start();
            Object gain=java.lang.reflect.Proxy.newProxyInstance(app.getClassLoader(),new Class[]{volumeClass},(p,m,a)->{player.setVolume((float)a[0],(float)a[0]);return null;});
            Object aux=java.lang.reflect.Proxy.newProxyInstance(app.getClassLoader(),new Class[]{auxClass},(p,m,a)->{if(m.getName().equals("attach")){effectID[0]=(int)a[0];player.attachAuxEffect(effectID[0]);}else{send[0]=(float)a[0];player.setAuxEffectSendLevel(send[0]);}return null;});
            attach.invoke(effects,player.getAudioSessionId(),gain,aux);
            for(String preset:new String[]{"hall","studio"}){
                select.invoke(effects,preset);checkState.invoke(effects);
                check(state.invoke(effects).equals("active"),"AOSP real room effect unavailable: "+preset);
                check(effectID[0]>0&&send[0]>0&&send[0]<.3f,"room must use a restrained explicit own-player aux send");
                int position=player.getCurrentPosition();Thread.sleep(250);check(player.isPlaying()&&position!=player.getCurrentPosition(),"room selection stopped playback");
                method(control,"reset").invoke(effects);check(state.invoke(effects).equals("active"),"seek tail reset did not reattach");
                select.invoke(effects,"original");check(effectID[0]==0&&send[0]==0,"original left reverb send attached");
                out.putString(preset,"real auxiliary reverb enabled; own send and detach verified");
            }
            for(int i=0;i<12;i++){
                select.invoke(effects,i%2==0?"hall":"studio");
                check(state.invoke(effects).equals("active"),"rapid room switch fell back");
                method(control,"reset").invoke(effects);check(state.invoke(effects).equals("active"),"rapid room reset fell back");
            }
            out.putString("roomEngine",(String)method(control,"engine").invoke(effects));
            out.putString("switching","12 immediate room switches and tail resets kept effect active");
            select.invoke(effects,"surround");for(int i=0;i<4;i++){Thread.sleep(160);checkState.invoke(effects);}
            String surround=(String)state.invoke(effects);check(surround.equals("active")||surround.equals("unavailable"),"virtualizer activation stuck pending");
            if(surround.equals("active")){
                Field f=control.getDeclaredField("spatial");f.setAccessible(true);Object handle=f.get(effects);
                check((boolean)method(handle.getClass(),"processing").invoke(handle),"enabled virtualizer must have active route");
            }
            out.putString("surround",surround+" (speaker route capability checked)");
            select.invoke(effects,"hall");
            occupiedRoom=new android.media.audiofx.EnvironmentalReverb(100,0);occupiedPreset=new android.media.audiofx.PresetReverb(100,0);
            occupiedPreset.setPreset(android.media.audiofx.PresetReverb.PRESET_SMALLROOM);
            short expected=occupiedPreset.getPreset();int decay=occupiedRoom.getDecayTime();
            Thread.sleep(250);checkState.invoke(effects);
            check(state.invoke(effects).equals("unavailable")&&effectID[0]==0&&send[0]==0,"lost shared engine control did not disconnect own player");
            select.invoke(effects,"hall");check(state.invoke(effects).equals("unavailable"),"competing app effect was taken over");
            check(occupiedPreset.getPreset()==expected&&occupiedRoom.getDecayTime()==decay,"other app's reverb was changed");
            check(effectID[0]==0&&send[0]==0,"unavailable room retained a send");
            out.putString("ownership","higher-priority auxiliary engines remain untouched; original and seek cleanup passed");
        }finally{detach.invoke(effects);if(occupiedRoom!=null)occupiedRoom.release();if(occupiedPreset!=null)occupiedPreset.release();player.release();tone.delete();}
    }
    void identity()throws Exception{
        try(InputStream setup=app.getAssets().open("SideASetup.txt")){throw new Exception("Identity fixture must not contain an enrollment ticket");}
        catch(FileNotFoundException expected){}
        String seed;try(InputStream input=app.getAssets().open("SideARecoverySeed.txt")){ByteArrayOutputStream raw=new ByteArrayOutputStream();byte[] buffer=new byte[128];int count;while((count=input.read(buffer))!=-1)raw.write(buffer,0,count);seed=raw.toString("US-ASCII").trim();}
        check(seed.equals("sidea-synthetic-recovery-seed-for-emulator-050"),"Identity fixture requires the documented synthetic seed");
        String androidId=android.provider.Settings.Secure.getString(app.getContentResolver(),android.provider.Settings.Secure.ANDROID_ID);
        check(androidId!=null&&androidId.matches("[0-9a-fA-F]{1,16}")&&!androidId.matches("0+"),"Emulator has no stable ID");
        String actual=(String)call(central,"recovery",new Class[]{Context.class},app);
        check(actual.equals(call(central,"recovery",new Class[]{Context.class},app)),"Recovery changed between calls");
        javax.crypto.Mac mac=javax.crypto.Mac.getInstance("HmacSHA256");
        mac.init(new javax.crypto.spec.SecretKeySpec(seed.getBytes(StandardCharsets.US_ASCII),"HmacSHA256"));
        byte[] old=mac.doFinal(("SideA recovery v1|"+androidId.toLowerCase(java.util.Locale.ROOT)).getBytes(StandardCharsets.UTF_8));
        StringBuilder oldValue=new StringBuilder();for(byte b:old)oldValue.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
        boolean car=app.getPackageName().equals("studio.sidea.car");
        if(car){
            check(!actual.equals(oldValue.toString()),"Car identity collided with old phone namespace");
            mac.init(new javax.crypto.spec.SecretKeySpec(seed.getBytes(StandardCharsets.US_ASCII),"HmacSHA256"));
            byte[] changed=mac.doFinal(("SideA recovery v1|car|"+androidId.toLowerCase(java.util.Locale.ROOT)).getBytes(StandardCharsets.UTF_8));
            StringBuilder expected=new StringBuilder();for(byte b:changed)expected.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
            check(actual.equals(expected.toString()),"Car recovery namespace differs from specification");
        }else check(actual.equals(oldValue.toString()),"Phone recovery is no longer byte-compatible with v1");
        out.putString("identity-package",app.getPackageName());
        out.putString("identity-digest",digest(actual));
        out.putString("android-id-digest",digest(androidId));
        out.putString("identity",car?"Stable car namespace, isolated from phone v1":"Phone derivation byte-compatible with existing v1");
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
            switch(mode){case "identity":identity();break;case "sound":sound();break;case "spatial":spatial();break;case "unit":tests();persistenceTests();break;case "seed":seedOld();break;case "upgrade":upgrade();break;case "restore":restore();break;case "offline":offline();break;case "conflict":conflict();break;case "sources":sources();break;case "checkpoint":startCloud();waitBackup();evidence.edit().putString("expected",capture().toString()).commit();out.putString("checkpoint","current library and source preference acknowledged");break;default:throw new Exception("unknown mode");}
            try(FileOutputStream file=new FileOutputStream(evidenceFile)){file.write(new JSONObject(evidence.getAll()).toString().getBytes(StandardCharsets.UTF_8));}
            out.putString("result","PASS");finish(Activity.RESULT_OK,out);
        }catch(Throwable failure){Throwable t=failure;while(t.getCause()!=null)t=t.getCause();out.putString("result","FAIL");out.putString("detail",t.getClass().getSimpleName()+": "+t.getMessage());finish(Activity.RESULT_CANCELED,out);}
    }
}
