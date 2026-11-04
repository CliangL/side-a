package studio.sidea.android;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.graphics.*;
import android.media.*;
import android.media.session.*;
import android.net.*;
import android.os.*;
import android.util.Base64;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;
import static studio.sidea.android.Json.*;

/** Owns the Android player, independent of Activity and WebView lifetimes. */
public final class PlaybackService extends Service {
    private static final String CHANNEL = "sidea.playback", PREFS = "sidea.playback", SETTINGS = "sidea.settings";
    private static final int NOTIFICATION = 712;
    private static final Map<String,String> commands = new ConcurrentHashMap<>();
    private static final Map<String,CompletableFuture<JSONObject>> acknowledgements=new ConcurrentHashMap<>();
    private static volatile JSONObject snapshot;
    private static final String[] STATE_FIELDS={"queue","track","index","playing","loading","elapsed","duration","quality","error","mode","sleepEnd","embeddedCoverId","sound"};
    private static volatile Embedded embedded;
    private static final class Embedded {
        final String id, url;
        Embedded(String id,String url) { this.id=id; this.url=url; }
    }

    /** Only the request token crosses Binder, even when the user selects a large playlist. */
    public static void command(Context context, String action, String payload) {
        submit(context,action,payload,null);
    }
    /** The bridge calls this on its serial worker, never on the main thread. */
    public static JSONObject commandAndState(Context context,String action,String payload) throws Exception {
        if(Looper.myLooper()==Looper.getMainLooper()) throw new IllegalStateException("Media command must run off main thread");
        CompletableFuture<JSONObject> reply=new CompletableFuture<>();
        String token=submit(context,action,payload,reply);
        try { return reply.get(10,TimeUnit.SECONDS); }
        finally { acknowledgements.remove(token); }
    }
    private static String submit(Context context,String action,String payload,CompletableFuture<JSONObject> reply) {
        Context c=context.getApplicationContext();
        Intent intent=new Intent(c, PlaybackService.class).setAction(action);
        String token=UUID.randomUUID().toString();
        commands.put(token, payload==null ? "{}" : payload);
        if(reply!=null) acknowledgements.put(token,reply);
        intent.putExtra("token",token);
        try {
            if (playAction(action)) c.startForegroundService(intent);
            else c.startService(intent);
        } catch (RuntimeException e) { commands.remove(token); acknowledgements.remove(token); throw e; }
        return token;
    }
    private static boolean playAction(String s) {
        return "play".equals(s) || "toggle".equals(s) || "next".equals(s) || "previous".equals(s) || "resume".equals(s);
    }
    private static JSONObject parse(String s) {
        try { return new JSONObject(s==null?"{}":s); } catch (JSONException e) { return new JSONObject(); }
    }
    public static JSONObject state(Context c) {
        JSONObject current=snapshot;
        if (current!=null) { try { return new JSONObject(current,STATE_FIELDS); } catch(JSONException ignored) {} }
        JSONObject saved=parse(c.getSharedPreferences(PREFS,0).getString("resume",""));
        JSONArray q=array(saved,"queue");
        int i=Math.max(0,Math.min(q.length()-1,saved.optInt("index")));
        return object("queue",q,"index",i,"track",q.optJSONObject(i),"playing",false,"loading",false,
            "elapsed",saved.optDouble("elapsed",0),"duration",saved.optDouble("duration",0),"mode",saved.optString("mode","sequence"),
            "quality","等待音源","error","","sleepEnd",0,"embeddedCoverId","",
            "sound",AndroidSoundEffects.pending(c.getSharedPreferences(SETTINGS,0).getString("soundPreset",SoundPreset.ORIGINAL)));
    }
    public static String embeddedCover(String id) {
        Embedded image=embedded;
        return image!=null && image.id.equals(id) ? image.url : "";
    }

    private final AudioAttributes attributes = new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build();
    private final ExecutorService fetches=Executors.newFixedThreadPool(3);
    private HandlerThread thread;
    private Handler owner;
    private Catalog catalog;
    private MediaSession session;
    private AudioManager audio;
    private AudioFocusRequest focus;
    private MediaPlayer engine;
    private final SoundEffects sound=AndroidSoundEffects.create();
    private volatile boolean destroyed;
    private volatile boolean foreground;
    private long generation;
    private Future<?> lookup, artLookup;
    private List<JSONObject> queue = new ArrayList<>();
    private JSONArray queueSnapshot=new JSONArray();
    private int index;
    private double elapsed, duration, listened, lastPosition;
    private boolean ready, wantsPlay, playing, started, loading, resumeOnFocus, buffering, retried, hasFocus;
    private String mode="sequence", startEvent="manualPlay", quality="等待音源", error="";
    private long sleepEnd, lastTick, lastSaved, lastProgress;
    private Bitmap art;
    private volatile Notification displayed;

    @Override public void onCreate() {
        super.onCreate();
        thread=new HandlerThread("SideA audio");
        thread.start(); owner=new Handler(thread.getLooper());
        catalog=new Catalog(this);
        audio=(AudioManager)getSystemService(AUDIO_SERVICE);
        focus=new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN).setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(this::focusChanged,owner).setWillPauseWhenDucked(true).build();
        NotificationManager manager=getSystemService(NotificationManager.class);
        NotificationChannel channel=new NotificationChannel(CHANNEL,"音乐播放",NotificationManager.IMPORTANCE_LOW);
        channel.setSound(null,null); channel.setShowBadge(false); manager.createNotificationChannel(channel);
        session=new MediaSession(this,"Side A");
        session.setSessionActivity(openApp());
        session.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { if (!wantsPlay) { promote(); resume(); } }
            @Override public void onPause() { pause(false); }
            @Override public void onStop() { pause(false); }
            @Override public void onSeekTo(long ms) { seek(ms/1000d); }
            @Override public void onSkipToNext() { promote(); advance(false,true); }
            @Override public void onSkipToPrevious() { promote(); advance(true,true); }
        },owner);
        if (Build.VERSION.SDK_INT>=33) registerReceiver(unplug,new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(unplug,new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY));
        owner.post(()->{
            JSONObject saved=parse(getSharedPreferences(PREFS,0).getString("resume",""));
            queue=rows(array(saved,"queue"));
            queueSnapshot=new JSONArray(queue);
            index=Math.max(0,Math.min(queue.size()-1,saved.optInt("index")));
            elapsed=saved.optDouble("elapsed",0); duration=saved.optDouble("duration",0); mode=saved.optString("mode","sequence");
            sound.select(getSharedPreferences(SETTINGS,0).getString("soundPreset",SoundPreset.ORIGINAL));
            publish(false); owner.post(ticker);
        });
    }

    private final BroadcastReceiver unplug=new BroadcastReceiver() {
        @Override public void onReceive(Context c,Intent i) { owner.post(()->pause(false)); }
    };
    @Override public int onStartCommand(Intent intent,int flags,int id) {
        if (intent==null) return START_NOT_STICKY;
        String action=intent.getAction(), token=intent.getStringExtra("token");
        String raw=token==null ? "{}" : commands.remove(token);
        if (playAction(action)) promote();
        CompletableFuture<JSONObject> reply=token==null?null:acknowledgements.get(token);
        owner.post(()->{
            try {
                if(destroyed) throw new IllegalStateException("播放服务正在关闭");
                if(playAction(action) && !foreground) promote();
                dispatch(action,parse(raw));
                if(reply!=null) reply.complete(state(this));
            } catch(RuntimeException e) {
                if(reply!=null) reply.completeExceptionally(e);
                else fail("无法执行播放操作");
            }
        });
        return START_NOT_STICKY;
    }
    @Override public IBinder onBind(Intent i) { return null; }
    @Override public void onDestroy() {
        destroyed=true;
        unregisterReceiver(unplug);
        owner.post(()->{
            persist(); releaseEngine(); abandonFocus(); session.release();
            fetches.shutdownNow(); snapshot=null; embedded=null;
            owner.removeCallbacksAndMessages(null); thread.quitSafely();
        });
        super.onDestroy();
    }

    private void dispatch(String action, JSONObject args) {
        if (action==null) return;
        switch(action) {
            case "play": {
                List<JSONObject> songs=rows(array(args,"tracks")); int target=args.optInt("index");
                if (target<0 || target>=songs.size()) { demoteIfIdle(); return; }
                boolean replay=current()!=null && id(current()).equals(id(songs.get(target)));
                if (!replay) recordSkip();
                queue=songs; select(target,replay?"replay":"manualPlay",0); break;
            }
            case "toggle": if (wantsPlay) pause(false); else resume(); break;
            case "resume": resume(); break;
            case "pause": pause(false); break;
            case "next": advance(false,true); break;
            case "previous": advance(true,true); break;
            case "seek": seek(args.optDouble("seconds",0)); break;
            case "enqueue": {
                JSONObject song=args.optJSONObject("track");
                if (song!=null && !text(song,"trackID").isEmpty()) queue.add(args.optBoolean("next") && !queue.isEmpty() ? index+1 : queue.size(),song);
                persist(); publish(true); break;
            }
            case "remove": remove(args.optInt("index",-1)); break;
            case "move": {
                int from=args.optInt("from",-1), to=args.optInt("to",-1);
                if (from>=0 && from<queue.size() && to>=0 && to<queue.size() && from!=to) {
                    JSONObject song=queue.remove(from); queue.add(to,song);
                    if (index==from) index=to;
                    else if (from<index && to>=index) index--;
                    else if (from>index && to<=index) index++;
                    persist(); publish(false);
                } break;
            }
            case "mode": {
                String s=args.optString("mode");
                if (s.equals("sequence") || s.equals("shuffle") || s.equals("repeatOne")) { mode=s; persist(); publish(false); }
                break;
            }
            case "sleep": {
                int minutes=args.optInt("minutes",0);
                sleepEnd=minutes>0 ? System.currentTimeMillis()+Math.min(1440,minutes)*60000L : 0;
                publish(false); break;
            }
            case "sound": {
                String requested=args.optString("preset",SoundPreset.ORIGINAL);
                if(!requested.equals(SoundPreset.normalize(requested)))throw new IllegalArgumentException("未知音效");
                synchronized(Library.class){
                    SharedPreferences prefs=getSharedPreferences(SETTINGS,0);
                    String previous=prefs.getString("soundPreset",SoundPreset.ORIGINAL);
                    if(!prefs.edit().putString("soundPreset",requested).commit()){
                        prefs.edit().putString("soundPreset",previous).commit();
                        throw new IllegalStateException("音效暂时无法保存");
                    }
                    Library.preferencesChanged(this);
                }
                sound.select(requested); publish(false); break;
            }
            case "quality": {
                synchronized(Library.class){
                SharedPreferences.Editor prefs=getSharedPreferences(SETTINGS,0).edit();
                for(String k:new String[]{"preferLossless","cellularDataSaver","losslessOnly"}) if(args.has(k)) prefs.putBoolean(k,args.optBoolean(k));
                prefs.commit();Library.preferencesChanged(this);
                }break;
            }
        }
    }

    private JSONObject current() { return queue.isEmpty()? null:queue.get(index); }
    private void remove(int at) {
        if (at<0 || at>=queue.size()) return;
        boolean selected=at==index, wasPlaying=wantsPlay;
        queue.remove(at);
        if (at<index) index--;
        index=Math.max(0,Math.min(index,queue.size()-1));
        if (selected) {
            if (wasPlaying && !queue.isEmpty()) { select(index,"autoPlay",0); return; }
            releaseEngine(); wantsPlay=false; elapsed=0; duration=0; clearArt(); error=""; quality="等待音源"; abandonFocus();
            demoteIfIdle();
        }
        persist(); publish(true);
    }
    private void advance(boolean back,boolean explicit) {
        if (current()==null) {demoteIfIdle(); return;}
        if (back && elapsed>3) { seek(0); if(!wantsPlay) demoteIfIdle(); return; }
        if (explicit) recordSkip();
        int n=queue.size(), target;
        if (!back && mode.equals("shuffle") && n>1) target=(index+1+ThreadLocalRandom.current().nextInt(n-1))%n;
        else target=(index+(back?-1:1)+n)%n;
        select(target,"autoPlay",0);
    }
    private void resume() {
        if (current()==null) {demoteIfIdle();return;}
        resumeOnFocus=false;
        if (wantsPlay && ready) return;
        if (ready && engine!=null) { wantsPlay=true; startReady(); }
        else select(index,"manualPlay",elapsed);
    }
    private void pause(boolean interrupted) {
        updatePosition();
        boolean was=wantsPlay; wantsPlay=false; resumeOnFocus=interrupted && was;
        if (engine!=null && ready) try { if(engine.isPlaying()) engine.pause(); } catch(RuntimeException ignored) {}
        sound.detach();
        playing=false; loading=false; lastTick=0;
        if (!interrupted) abandonFocus();
        persist(); publish(true);
        if(!resumeOnFocus) demoteIfIdle();
    }
    private void focusChanged(int change) {
        if (change==AudioManager.AUDIOFOCUS_GAIN) {
            if (resumeOnFocus && current()!=null) { resumeOnFocus=false; promote(); resume(); }
        } else if (change==AudioManager.AUDIOFOCUS_LOSS) {
            pause(false);
        } else if ((change==AudioManager.AUDIOFOCUS_LOSS_TRANSIENT || change==AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK) && wantsPlay) {
            pause(true);
        }
    }
    private void abandonFocus() {
        if(hasFocus) { hasFocus=false; audio.abandonAudioFocusRequest(focus); }
    }
    private void select(int target,String event,double offset) {
        releaseEngine(); clearArt();
        index=target; elapsed=Math.max(0,offset); duration=0; listened=0; started=false; retried=false;
        loading=true; wantsPlay=true; resumeOnFocus=false; error=""; quality="正在连接"; startEvent=event;
        persist(); publish(true); resolve();
    }
    private void releaseEngine() {
        sound.detach();
        generation++;
        if(lookup!=null) lookup.cancel(true);
        if(artLookup!=null) artLookup.cancel(true);
        if(engine!=null) {
            engine.setOnErrorListener(null); engine.setOnPreparedListener(null); engine.setOnCompletionListener(null);
            engine.setOnInfoListener(null); engine.setOnSeekCompleteListener(null); engine.release(); engine=null;
        }
        ready=false; playing=false; buffering=false; loading=false; lastTick=0;
    }
    private void clearArt() { art=null; embedded=null; }
    private boolean cellular() {
        try {
            ConnectivityManager cm=getSystemService(ConnectivityManager.class);
            NetworkCapabilities nc=cm.getNetworkCapabilities(cm.getActiveNetwork());
            return nc==null || nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR);
        } catch (RuntimeException ignored) { return true; }
    }
    private void resolve() {
        final JSONObject track=current();
        if (track==null) return;
        long attempt=generation;
        lastProgress=SystemClock.elapsedRealtime();
        boolean cell=cellular();
        SharedPreferences prefs=getSharedPreferences(SETTINGS,0);
        boolean strict=prefs.getBoolean("losslessOnly",false);
        boolean prefer=prefs.getBoolean("preferLossless",true) && !(cell && prefs.getBoolean("cellularDataSaver",true));
        lookup=fetches.submit(()->{
            try {
                JSONObject stream=choose(track,strict,prefer);
                if(!Thread.currentThread().isInterrupted()) owner.post(()->{ if(valid(attempt)) prepare(stream,attempt); });
            } catch(Exception e) {
                owner.post(()->{ if(valid(attempt)) fail(e.getMessage()); });
            }
        });
    }
    private boolean valid(long id) { return generation==id && !destroyed; }
    private JSONObject choose(JSONObject song,boolean strict,boolean prefer) throws Exception {
        JSONObject compressed=null; Exception failure=null;
        if(strict || prefer) {
            for(int request:new int[]{999,740}) {
                if(Thread.currentThread().isInterrupted()) throw new InterruptedException();
                try {
                    JSONObject stream=catalog.stream(song,request);
                    if(stream.optBoolean("flac")) return stream;
                    if(compressed==null || stream.optInt("br")>compressed.optInt("br")) compressed=stream;
                } catch(Exception e) { failure=e; }
            }
            if(strict) throw new IOException(compressed==null && failure!=null && failure.getMessage()!=null ? failure.getMessage() : "这首歌没有可验证的无损版本");
            if(compressed!=null) return compressed;
        }
        return catalog.stream(song,320);
    }
    private void prepare(JSONObject stream,long attempt) {
        try {
            quality=stream.optBoolean("flac") ? "无损 · FLAC" + (stream.optInt("bits")>0 ? " "+stream.optInt("bits")+"-bit" : "")
                    : stream.optInt("br")>0 ? stream.optInt("br")+" kbps" : "在线音频";
            MediaPlayer p=new MediaPlayer(); engine=p;
            p.addOnRoutingChangedListener(routing->{
                if(engine==p && ready && wantsPlay){attachSound(p);publish(false);}
            },owner);
            p.setAudioAttributes(attributes); p.setWakeMode(this,PowerManager.PARTIAL_WAKE_LOCK);
            p.setOnErrorListener((mp,what,extra)->{ if(valid(attempt)) recover("播放器无法读取音源，请重试"); return true; });
            p.setOnPreparedListener(mp->{
                if(!valid(attempt)) return;
                ready=true; duration=Math.max(0,mp.getDuration()/1000d);
                long expected=current().optLong("catalogDurationMS",0);
                if(stream.optBoolean("trial"))quality="试听 · "+quality;
                else if(duration>0 && duration<=60 && expected>=120000 && duration*1000<expected/2)
                    quality="片段 · "+quality;
                if(elapsed>0) mp.seekTo(Math.round(elapsed*1000),MediaPlayer.SEEK_CLOSEST);
                if(wantsPlay) startReady(); else {loading=false;publish(true);}
            });
            p.setOnCompletionListener(mp->{if(valid(attempt)) completed();});
            p.setOnInfoListener((mp,what,extra)->{
                if(valid(attempt) && (what==MediaPlayer.MEDIA_INFO_BUFFERING_START || what==MediaPlayer.MEDIA_INFO_BUFFERING_END)) {
                    updatePosition(); buffering=what==MediaPlayer.MEDIA_INFO_BUFFERING_START; loading=buffering&&wantsPlay;
                    if(buffering) { playing=false;lastTick=0;lastProgress=SystemClock.elapsedRealtime(); }
                    publish(true);
                }
                return false;
            });
            p.setOnSeekCompleteListener(mp->{if(valid(attempt)) { lastTick=0; updatePosition(); publish(false); }});
            String address=text(stream,"url"); Map<String,String> headers=new HashMap<>();
            headers.put("User-Agent","Mozilla/5.0"); headers.put("Referer",MusicSource.mediaReferer(address,MusicSource.referer(MusicSource.endpointOf(current()))));
            p.setDataSource(this,Uri.parse(address),headers); p.prepareAsync();
            fetchCover(current(),stream,attempt);
        } catch(Exception e) { recover("无法打开这首歌，点播放可重试"); }
    }
    private void attachSound(MediaPlayer target) {
        // Route changes (speaker/headphones/Bluetooth) retry only effects; never start playback.
        sound.select(getSharedPreferences(SETTINGS,0).getString("soundPreset",SoundPreset.ORIGINAL));
        sound.attach(target.getAudioSessionId(),gain->target.setVolume(gain,gain),new SoundEffects.Aux(){
            public void attach(int effect){target.attachAuxEffect(effect);}
            public void send(float level){target.setAuxEffectSendLevel(level);}
        });
    }
    private void startReady() {
        if(engine==null || !ready || !wantsPlay) return;
        if(!hasFocus) {
            hasFocus=audio.requestAudioFocus(focus)==AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
            if(!hasFocus) {fail("暂时无法获得音频焦点，请稍后重试");return;}
        }
        try {
            attachSound(engine);
            engine.start(); loading=true; lastTick=0; lastPosition=engine.getCurrentPosition()/1000d;
            lastProgress=SystemClock.elapsedRealtime(); publish(true);
        } catch(RuntimeException e) { recover("未能开始播放，请重试"); }
    }
    private void recover(String message) {
        if(retried || !wantsPlay) {fail(message);return;}
        updatePosition(); releaseEngine(); retried=true; loading=true;
        publish(true); resolve();
    }
    private void fail(String message) {
        releaseEngine(); wantsPlay=false; resumeOnFocus=false; abandonFocus();
        error=message==null || message.isEmpty()?"音源暂不可用，请重试":message;
        persist(); publish(true); demoteIfIdle();
    }
    private void completed() {
        updatePosition();
        if(started && current()!=null) Library.record(this,current(),"complete",listened,duration);
        if(mode.equals("repeatOne")) select(index,"autoPlay",0);
        else if(index<queue.size()-1 || mode.equals("shuffle")) advance(false,false);
        else {
            releaseEngine(); elapsed=0; wantsPlay=false; abandonFocus(); persist(); publish(true); demoteIfIdle();
        }
    }
    private void seek(double seconds) {
        if(!Double.isFinite(seconds) || current()==null) return;
        elapsed=Math.max(0,duration>0?Math.min(duration,seconds):seconds);
        if(ready) {
            try { sound.reset(); engine.seekTo(Math.round(elapsed*1000),MediaPlayer.SEEK_CLOSEST); } catch(RuntimeException ignored) {}
        }
        lastTick=0; lastPosition=elapsed; persist(); publish(true);
    }
    private void updatePosition() {
        if(!ready || engine==null) return;
        try {
            double now=engine.getCurrentPosition()/1000d;
            long tick=SystemClock.elapsedRealtime();
            boolean progressing=wantsPlay && !buffering && engine.isPlaying() && now>lastPosition;
            if(progressing) {
                if(lastTick>0) listened+=Math.min(Math.max(0,now-lastPosition),(tick-lastTick)/1000d);
                if(!started) { started=true; Library.record(this,current(),startEvent,0,duration); }
                boolean drawingBuffer=loading || !playing;
                playing=true;loading=false;lastProgress=tick;
                if(drawingBuffer) updateSystem(true);
            }
            elapsed=now; lastPosition=now;lastTick=tick;
        } catch(IllegalStateException ignored) {}
    }
    private void recordSkip() {
        updatePosition(); if(started && current()!=null) Library.record(this,current(),"skip",listened,duration);
    }
    private final Runnable ticker=new Runnable(){public void run(){
        if(destroyed) return;
        long now=SystemClock.elapsedRealtime();
        if(sleepEnd>0 && System.currentTimeMillis()>=sleepEnd) { sleepEnd=0;pause(false); }
        updatePosition();
        String selected=SoundPreset.normalize(getSharedPreferences(SETTINGS,0).getString("soundPreset",SoundPreset.ORIGINAL));
        boolean soundChanged=!selected.equals(sound.preset());
        if(soundChanged)sound.select(selected);
        if(sound.check()||soundChanged)publish(false);
        if(wantsPlay && now-lastProgress>28000) recover("播放连接超时");
        if(wantsPlay && now-lastSaved>6000) {persist();lastSaved=now;}
        if(wantsPlay) publish(false);
        owner.postDelayed(this,500);
    }};
    private void persist() {
        queueSnapshot=new JSONArray(queue);
        getSharedPreferences(PREFS,0).edit().putString("resume",object("queue",queueSnapshot,"index",index,
            "elapsed",elapsed,"duration",duration,"mode",mode).toString()).apply();
    }
    private void publish(boolean system) {
        Embedded cover=embedded;
        snapshot=object("queue",queueSnapshot,"track",current(),"index",index,"playing",playing,"loading",loading,
                "elapsed",elapsed,"duration",duration,"quality",quality,"error",error,"mode",mode,"sleepEnd",sleepEnd,
                "embeddedCoverId",cover==null?"":cover.id,"sound",AndroidSoundEffects.state(sound));
        if(system) updateSystem(true);
    }

    private PendingIntent openApp() {
        Intent intent=getPackageManager().getLaunchIntentForPackage(getPackageName());
        if(intent==null) return null;
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(this,0,intent,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
    }
    private PendingIntent control(String action,int request) {
        Intent i=new Intent(this,PlaybackService.class).setAction(action);
        int flags=PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT;
        return playAction(action)?PendingIntent.getForegroundService(this,request,i,flags):PendingIntent.getService(this,request,i,flags);
    }
    private Notification notification(JSONObject song, boolean running, Bitmap picture) {
        Notification.Builder b=new Notification.Builder(this,CHANNEL)
                .setSmallIcon(android.R.drawable.ic_media_play).setContentIntent(openApp())
                .setVisibility(Notification.VISIBILITY_PUBLIC).setOnlyAlertOnce(true)
                .setShowWhen(false).setCategory(Notification.CATEGORY_TRANSPORT).setOngoing(running)
                .setContentTitle(song==null ? "Side A" : text(song,"title")).setContentText(song==null?"私人唱片室":text(song,"artist"))
                .addAction(android.R.drawable.ic_media_previous,"上一首",control("previous",1))
                .addAction(running?android.R.drawable.ic_media_pause:android.R.drawable.ic_media_play,running?"暂停":"播放",control(running?"pause":"resume",2))
                .addAction(android.R.drawable.ic_media_next,"下一首",control("next",3));
        if(picture!=null)b.setLargeIcon(picture);
        if(session!=null)b.setStyle(new Notification.MediaStyle().setMediaSession(session.getSessionToken()).setShowActionsInCompactView(0,1,2));
        return b.build();
    }
    private void updateSystem(boolean notify) {
        if(destroyed) return;
        JSONObject track=current();
        if(track==null) {
            session.setActive(false); session.setMetadata(null); displayed=null;
            if(!wantsPlay) getSystemService(NotificationManager.class).cancel(NOTIFICATION);
            return;
        }
        MediaMetadata.Builder metadata=new MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE,text(track,"title"))
                .putString(MediaMetadata.METADATA_KEY_ARTIST,text(track,"artist"))
                .putString(MediaMetadata.METADATA_KEY_ALBUM,text(track,"album"))
                .putLong(MediaMetadata.METADATA_KEY_DURATION,(long)(duration*1000));
        if(art!=null) metadata.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART,art);
        session.setMetadata(metadata.build());
        int state = !error.isEmpty()?PlaybackState.STATE_ERROR:loading?PlaybackState.STATE_BUFFERING:playing?PlaybackState.STATE_PLAYING:PlaybackState.STATE_PAUSED;
        PlaybackState.Builder bs=new PlaybackState.Builder().setActions(PlaybackState.ACTION_SEEK_TO|PlaybackState.ACTION_PLAY_PAUSE|
                PlaybackState.ACTION_PLAY|PlaybackState.ACTION_PAUSE|PlaybackState.ACTION_SKIP_TO_NEXT|PlaybackState.ACTION_SKIP_TO_PREVIOUS|PlaybackState.ACTION_STOP)
                .setState(state,(long)(elapsed*1000),playing?1f:0f,SystemClock.elapsedRealtime());
        if(!error.isEmpty())bs.setErrorMessage(error);
        session.setPlaybackState(bs.build()); session.setActive(true);
        displayed=notification(track,wantsPlay,art);
        if(notify) getSystemService(NotificationManager.class).notify(NOTIFICATION,displayed);
    }
    private synchronized void promote() {
        Notification n=displayed;
        if(n==null)n=notification(null,false,null);
        if(Build.VERSION.SDK_INT>=29) startForeground(NOTIFICATION,n,ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        else startForeground(NOTIFICATION,n);
        foreground=true;
    }
    private synchronized void demoteIfIdle() {
        if(!wantsPlay && foreground) {
            stopForeground(current()==null?STOP_FOREGROUND_REMOVE:STOP_FOREGROUND_DETACH);
            foreground=false;
        }
    }

    private void fetchCover(JSONObject track,JSONObject stream,long attempt) {
        artLookup=fetches.submit(()->{
            Bitmap bitmap=null; Embedded found=null;
            try {
                if(stream.optBoolean("flac")) {
                    byte[] photo=flacPicture(text(stream,"url"),MusicSource.referer(MusicSource.endpointOf(track)));
                    bitmap=sampledBitmap(photo);
                    if(bitmap!=null) {
                        ByteArrayOutputStream jpeg=new ByteArrayOutputStream();
                        bitmap.compress(Bitmap.CompressFormat.JPEG,85,jpeg);
                        found=new Embedded(id(track),"data:image/jpeg;base64,"+Base64.encodeToString(jpeg.toByteArray(),Base64.NO_WRAP));
                    }
                }
            } catch(Exception ignored) {}
            if(Thread.currentThread().isInterrupted()) return;
            if(bitmap==null) try {
                String u=catalog.cover(track); int separator=u.indexOf(',');
                if(separator>=0) bitmap=sampledBitmap(Base64.decode(u.substring(separator+1),Base64.DEFAULT));
            } catch(Exception ignored) {}
            final Bitmap picture=bitmap; final Embedded result=found;
            owner.post(()->{if(valid(attempt)) {art=picture;embedded=result;publish(true);} });
        });
    }
    private static Bitmap sampledBitmap(byte[] data) {
        if(data==null || data.length==0)return null;
        BitmapFactory.Options opts=new BitmapFactory.Options(); opts.inJustDecodeBounds=true;
        BitmapFactory.decodeByteArray(data,0,data.length,opts);
        if(opts.outWidth<=0 || opts.outHeight<=0) return null;
        opts.inSampleSize=1;
        while(Math.max(opts.outWidth,opts.outHeight)/opts.inSampleSize>768)opts.inSampleSize*=2;
        opts.inJustDecodeBounds=false;
        return BitmapFactory.decodeByteArray(data,0,data.length,opts);
    }
    // Read metadata only. A missing picture must never cause a full song download.
    private static byte[] flacPicture(String address,String referer) throws IOException {
        final int budget=2*1024*1024;
        HttpURLConnection req=(HttpURLConnection)new URL(address).openConnection();
        req.setRequestProperty("Range","bytes=0-"+(budget-1));
        req.setRequestProperty("User-Agent","Mozilla/5.0");
        req.setRequestProperty("Referer",MusicSource.mediaReferer(address,referer));
        req.setConnectTimeout(5000);req.setReadTimeout(6500);
        try(DataInputStream in=new DataInputStream(new BufferedInputStream(req.getInputStream()))) {
            if(in.readInt()!=0x664c6143) return null;
            int total=4;
            while(total+4<=budget && !Thread.currentThread().isInterrupted()) {
                int head=in.readUnsignedByte(),length=(in.readUnsignedByte()<<16)|(in.readUnsignedByte()<<8)|in.readUnsignedByte();
                total+=4+length;if(total>budget) return null;
                if((head&127)==6) {
                    byte[] block=new byte[length];in.readFully(block);
                    DataInputStream fields=new DataInputStream(new ByteArrayInputStream(block));
                    fields.readInt();skipBytes(fields,fields.readInt(),length);skipBytes(fields,fields.readInt(),length);
                    for(int i=0;i<4;i++)fields.readInt();
                    int size=fields.readInt();
                    if(size<=0 || size>fields.available())return null;
                    byte[] result=new byte[size];fields.readFully(result);return result;
                }
                skipBytes(in,length,budget);
                if((head&128)!=0) break;
            }
        } finally {req.disconnect();}
        return null;
    }
    private static void skipBytes(DataInputStream in,int count,int limit) throws IOException {
        if(count<0 || count>limit)throw new IOException("Invalid FLAC picture");
        while(count>0) {
            int skipped=in.skipBytes(count);
            if(skipped==0) {in.readByte();skipped=1;}
            count-=skipped;
        }
    }
}
