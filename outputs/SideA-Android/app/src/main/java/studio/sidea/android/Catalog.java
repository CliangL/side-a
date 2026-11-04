package studio.sidea.android;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.util.Base64;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.*;
import org.json.*;
import static studio.sidea.android.Json.*;

public final class Catalog {
    private static final String GD = MusicSource.GD;
    private static final String NET = "https://music.163.com";
    private static final long DAY = 86400000L;
    private static final Object disk = new Object();
    private static final Object[] lanes = new Object[32];
    static { for(int i=0;i<lanes.length;i++) lanes[i]=new Object(); }
    private static long generation;
    private static final ArrayDeque<Long> calls = new ArrayDeque<>();
    private static final ExecutorService enrichment = Executors.newFixedThreadPool(4);
    private static final Pattern stamp = Pattern.compile("\\[(\\d{1,4}):(\\d{1,2}(?:\\.\\d+)?)\\]");
    private final Context ctx;
    private final File cache;
    public Catalog(Context context) {
        ctx=context.getApplicationContext(); cache=new File(ctx.getCacheDir(),"SideAMedia");
    }
    static byte[] read(InputStream in,int limit) throws IOException {
        try(InputStream input=in; ByteArrayOutputStream out=new ByteArrayOutputStream()) {
            byte[] buf=new byte[16384]; int n;
            while((n=input.read(buf))!=-1) {
                if(out.size()+n>limit) throw new IOException("服务器返回内容过大");
                out.write(buf,0,n);
            }
            return out.toByteArray();
        }
    }
    private static String url(String path,String... pairs) {
        Uri.Builder b=Uri.parse(path).buildUpon();
        for(int i=0;i<pairs.length;i+=2) b.appendQueryParameter(pairs[i],pairs[i+1]);
        return b.build().toString();
    }
    private static String secureURL(String raw) throws IOException {
        if(raw.startsWith("http://")) raw="https://"+raw.substring(7);
        URL u=new URL(raw);
        if(!"https".equals(u.getProtocol()) || u.getHost().isEmpty() || u.getUserInfo()!=null) throw new IOException("音源地址不可用");
        return u.toExternalForm();
    }
    private static HttpURLConnection open(String address,String referer) throws IOException {
        HttpURLConnection c=(HttpURLConnection)new URL(secureURL(address)).openConnection();
        c.setConnectTimeout(8500); c.setReadTimeout(12000);
        c.setRequestProperty("User-Agent","Mozilla/5.0");
        c.setRequestProperty("Referer",referer);
        return c;
    }
    private static void budget(boolean play) throws IOException {
        synchronized(calls) {
            long now=android.os.SystemClock.elapsedRealtime();
            while(!calls.isEmpty() && now-calls.peekFirst()>=300000) calls.removeFirst();
            if(calls.size()>=(play?50:44)) throw new IOException("音乐源请求较频繁，请稍后重试");
            calls.add(now);
        }
    }
    private byte[] network(String address,boolean play,int limit) throws Exception {
        String base=address.split("\\?",2)[0];
        String referer=MusicSource.referer(base);
        return network(address,play,limit,referer);
    }
    private byte[] network(String address,boolean play,int limit,String referer) throws Exception {
        if(address.startsWith(GD+"?")) budget(play);
        HttpURLConnection c=open(address,referer);
        try {
            if(c.getResponseCode()/100!=2) throw new IOException("音乐源暂不可用，请稍后再试");
            return read(c.getInputStream(),limit);
        } finally { c.disconnect(); }
    }
    private File file(String key,boolean cover) throws Exception {
        byte[] digest=MessageDigest.getInstance("SHA-256").digest(key.getBytes(StandardCharsets.UTF_8));
        StringBuilder name=new StringBuilder(cover?"c-":"m-");
        for(byte b:digest) name.append(Character.forDigit((b>>4)&15,16)).append(Character.forDigit(b&15,16));
        return new File(cache,name.toString());
    }
    private byte[] cached(String key,long age,boolean cover) throws Exception {
        synchronized(disk) {
            File f=file(key,cover);
            try {
                return f.isFile() && System.currentTimeMillis()-f.lastModified()<age ? Files.readAllBytes(f.toPath()) : null;
            } catch(IOException unavailable){ return null; }
        }
    }
    private long epoch(){ synchronized(disk){ return generation; } }
    private void store(String key,byte[] bytes,boolean cover,long epoch) throws Exception {
        synchronized(disk) {
            if(epoch!=generation || bytes.length==0) return;
            if(!cache.isDirectory()&&!cache.mkdirs()) return;
            File f=file(key,cover), tmp=null;
            try {
                tmp=File.createTempFile("pending-",".buf",cache);
                Files.write(tmp.toPath(),bytes);
                tmp.renameTo(f);
            } catch(IOException unavailable){
                // A full disk must not discard a usable network response.
            } finally { if(tmp!=null) tmp.delete(); }
        }
    }
    void clear() {
        synchronized(disk) {
            generation++;
            File[] files=cache.listFiles();
            if(files==null)return;
            for(File f:files) if(!f.delete() && f.exists()) throw new IllegalStateException("部分缓存未能清理，请重试");
        }
    }
    long cacheBytes() {
        synchronized(disk) {
            long size=0;
            File[] files=cache.listFiles();
            if(files!=null) for(File f:files) size+=f.length();
            return size;
        }
    }
    private Object fetch(String address,long ttl,boolean play) throws Exception {
        Object lane=lanes[(address.hashCode()&Integer.MAX_VALUE)%lanes.length];
        synchronized(lane) {
            byte[] data=ttl>0?cached(address,ttl,false):null;
            long epoch=epoch(); boolean fresh=data==null;
            if(fresh)data=network(address,play,8*1024*1024);
            Object result=new JSONTokener(new String(data,StandardCharsets.UTF_8)).nextValue();
            if(result instanceof JSONObject) {
                JSONObject obj=(JSONObject)result;
                if(obj.has("error") || (obj.has("code")&&obj.optInt("code")!=200))throw new IOException("音乐源暂不可用");
            }
            if(fresh && ttl>0)store(address,data,false,epoch);
            return result;
        }
    }
    private Object catalogData(String address,boolean central,long ttl,boolean play)throws Exception {
        return central ? CentralCatalog.get(ctx.getSharedPreferences("sidea.settings",0),address) : fetch(address,ttl,play);
    }
    JSONArray starters() throws Exception {
        JSONArray a=new JSONArray(new String(read(ctx.getAssets().open("starter.json"),100000),StandardCharsets.UTF_8));
        for(JSONObject t:rows(a))put(t,"id",id(t));
        return a;
    }
    private JSONArray search(String term,MusicSource source,int page) throws Exception {
        if(page<1 || page>10000)throw new IllegalArgumentException("无效的搜索页码");
        if(term.trim().isEmpty())return new JSONArray();
        List<JSONObject> found=new ArrayList<>();
        JSONArray src=new JSONArray();
        try {
            String address=url(source.endpoint,"types","search","source",source.code,"name",term.trim(),"count","25","pages",String.valueOf(page));
            if(!source.provider.isEmpty())address=url(address,"provider",source.provider);
            Object reply=catalogData(address,source.central,DAY,false);
            if(!(reply instanceof JSONArray))throw new IOException("接口未返回曲目列表");
            src=(JSONArray)reply;
        } catch(Exception primaryUnavailable) {
            if(source.central)throw primaryUnavailable;
            if(!source.isDefaultNetEase())throw new IOException(source.label+" 暂时无法搜索，请检查曲库配置或稍后重试",primaryUnavailable);
        }
        Set<String> gdSeen=new HashSet<>();
        for(JSONObject row:rows(src)){
            String key=text(row,"id"), title=text(row,"name");
            if(!source.provider.isEmpty() && (!key.startsWith(source.provider+".") ||
                    row.has("provider_id") && !source.provider.equals(text(row,"provider_id"))))continue;
            if(!source.code.equalsIgnoreCase(text(row,"source")) || key.isEmpty() || title.isEmpty() || !gdSeen.add(key))continue;
            String artist=row.optJSONArray("artist")!=null ? joinNames(array(row,"artist")) : text(row,"artist");
            JSONObject t=object("source",source.code,"trackID",key,"title",title,"artist",artist,"album",text(row,"album"),"pictureID",text(row,"pic_id"),"lyricID",text(row,"lyric_id"),"genres",new JSONArray(),"sourceLabel",source.label);
            if(!GD.equals(source.endpoint))put(t,"apiEndpoint",source.endpoint);
            if(source.central){
                put(t,"centralCatalog",true);
                if(row.has("provider_id"))put(t,"providerID",text(row,"provider_id"));
                String label=MusicSource.providerLabel(key.split("\\.",2)[0]);
                if(label.equals("统一曲库")&&!text(row,"provider_name").isEmpty())label=text(row,"provider_name");
                put(t,"sourceLabel",label);
            }
            put(t,"id",id(t));found.add(t);
        }
        if(!source.isDefaultNetEase() && source.provider.isEmpty() && src.length()>0 && found.isEmpty())
            throw new IOException("接口未返回可确认属于 "+source.label+" 的曲目，请检查音源代码");
        if(found.isEmpty() && source.isDefaultNetEase()){
            JSONObject reply=(JSONObject)fetch(url(NET+"/api/search/get/web","s",term.trim(),"type","1","offset",String.valueOf(25*(page-1)),"limit","25"),3600000,false);
            JSONObject result=reply.optJSONObject("result");
            if(result==null)throw new IOException("搜索暂不可用，请重试");
            Set<String> seen=new HashSet<>();
            for(JSONObject row:rows(array(result,"songs"))){
                JSONObject t=fromNet(row);if(t!=null && seen.add(id(t)))found.add(t);
            }
        }
        for(int i=0;i<found.size();i++)put(found.get(i),"sourceRank",(page-1)*25+i+1);
        return new JSONArray(found);
    }
    private JSONObject oneSourcePage(String query,String selection,int page){
        MusicSource source=MusicSource.from(ctx.getSharedPreferences("sidea.settings",0),selection);
        String term=RecordingRanking.searchTerm(query);
        List<JSONObject> tracks=new ArrayList<>();
        Exception firstError=null;
        try { tracks.addAll(rows(search(term,source,page))); }
        catch (Exception error) { firstError=error; }
        if(page==1 && source.isDefaultNetEase() && !term.isEmpty()){
            RecordingRanking.includeOriginals(this,RecordingRanking.originalTerm(query),tracks);
        }
        if(firstError!=null && tracks.isEmpty()){
            return object("selection",selection,"ok",false,"label",source.label,"items",new JSONArray(),
                    "error",firstError.getMessage()==null?"曲库暂时不可用":firstError.getMessage());
        }
        return object("selection",selection,"ok",true,"label",source.label,"items",new JSONArray(tracks));
    }
    JSONObject searchPage(String query,List<String> selections,int page) throws Exception {
        List<JSONObject> statuses=new ArrayList<>();
        if(selections.size()==1)statuses.add(oneSourcePage(query,selections.get(0),page));
        else {
            List<Future<JSONObject>> tasks=new ArrayList<>();
            for(String selection:selections)tasks.add(enrichment.submit(()->oneSourcePage(query,selection,page)));
            for(Future<JSONObject> task:tasks)statuses.add(task.get());
        }
        List<JSONObject> tracks=new ArrayList<>();
        for(JSONObject status:statuses){
            JSONArray pageRows=array(status,"items"); addUnique(tracks,rows(pageRows));
            status.remove("items");put(status,"count",pageRows.length());
        }
        return object("items",new JSONArray(tracks),"bySource",new JSONArray(statuses));
    }
    JSONObject referenceData(String path,String... pairs) throws Exception {
        return (JSONObject)fetch(url(NET+path,pairs),DAY,false);
    }
    JSONArray rank(String query,List<JSONObject> tracks) {
        return RecordingRanking.rank(tracks,query,array(chart(true,false,false),"tracks"));
    }
    private static String joinNames(JSONArray a){
        List<String> names=new ArrayList<>();
        if(a==null)return "";
        for(int i=0;i<a.length();i++){
            JSONObject person=a.optJSONObject(i);
            String name=person==null?a.optString(i):text(person,"name"); if(!name.isEmpty())names.add(name);
        }return String.join(" / ",names);
    }
    public JSONObject stream(JSONObject t,int bitrate)throws Exception{
        JSONObject row=(JSONObject)catalogData(url(MusicSource.endpointOf(t),"types","url","source",text(t,"source"),"id",text(t,"trackID"),"br",String.valueOf(bitrate)),t.optBoolean("centralCatalog"),0,true);
        String returned=text(row,"source");
        if(!returned.isEmpty()&&!returned.equalsIgnoreCase(text(t,"source")))throw new IOException("播放接口返回了不同曲库，已停止播放");
        String raw=text(row,"url");
        if(raw.isEmpty())throw new IOException("当前曲库没有这首歌的可播地址");
        String address=secureURL(raw);
        HttpURLConnection c=open(address,MusicSource.mediaReferer(address,MusicSource.referer(MusicSource.endpointOf(t))));
        c.setRequestProperty("Range","bytes=0-63");
        byte[] bytes=new byte[42];int n=0;
        try{
            if(c.getResponseCode()/100!=2)throw new IOException("播放地址已失效");
            try(InputStream in=c.getInputStream()){while(n<bytes.length){int count=in.read(bytes,n,bytes.length-n);if(count<0)break;n+=count;}}
        }finally{c.disconnect();}
        boolean flac=n>=4&&bytes[0]=='f'&&bytes[1]=='L'&&bytes[2]=='a'&&bytes[3]=='C';
        int bits=flac&&n>=42&&(bytes[4]&127)==0?1+((bytes[20]&1)<<4)+((bytes[21]&255)>>4):0;
        JSONObject trial=row.optJSONObject("freeTrialInfo");
        boolean isTrial=(trial!=null && trial.optDouble("end",0)>trial.optDouble("start",0))
                || row.optBoolean("isPreview",false) || row.optBoolean("isTrial",false);
        return object("url",address,"flac",flac,"bits",bits,"br",row.optInt("br",0),"trial",isTrial);
    }
    public String cover(JSONObject t)throws Exception{
        String key=id(t);Object lane=lanes[(key.hashCode()&Integer.MAX_VALUE)%lanes.length];
        // Only protect the image load itself; fetch() may use a different stripe for API data.
        byte[] data=cached("art"+key,7*DAY,true);
        if(data!=null)return imageURL(data);
        String tid=text(t,"trackID");
        if(tid.matches("[0-9]+")&&MusicSource.defaultNetEase(t)){
            try{return imageURL(read(ctx.getAssets().open("StarterArt/cover-"+tid+".jpg"),3*1024*1024));}catch(FileNotFoundException ignored){}
        }
        long epoch=epoch();String raw=text(t,"artworkURL");
        if(raw.isEmpty()){
            String pic=text(t,"pictureID");if(pic.isEmpty())return "";
            JSONObject meta=(JSONObject)catalogData(url(MusicSource.endpointOf(t),"types","pic","source",text(t,"source"),"id",pic,"size","500"),t.optBoolean("centralCatalog"),7*DAY,false);
            raw=text(meta,"url");
        }
        if(raw.isEmpty())return "";
        synchronized(lane){
            data=cached("art"+key,7*DAY,true);
            if(data==null){
                byte[] original=network(secureURL(raw),false,10*1024*1024,MusicSource.referer(MusicSource.endpointOf(t)));
                BitmapFactory.Options options=new BitmapFactory.Options();options.inJustDecodeBounds=true;
                BitmapFactory.decodeByteArray(original,0,original.length,options);
                if(options.outWidth<=0||options.outHeight<=0)return "";
                options.inJustDecodeBounds=false;options.inSampleSize=1;
                while(Math.max(options.outWidth,options.outHeight)/options.inSampleSize>1024)options.inSampleSize*=2;
                Bitmap bitmap=BitmapFactory.decodeByteArray(original,0,original.length,options);if(bitmap==null)return "";
                ByteArrayOutputStream out=new ByteArrayOutputStream();bitmap.compress(Bitmap.CompressFormat.JPEG,87,out);bitmap.recycle();
                data=out.toByteArray();store("art"+key,data,true,epoch);
            }
        }
        return imageURL(data);
    }
    private String imageURL(byte[] data){return "data:image/jpeg;base64,"+Base64.encodeToString(data,Base64.NO_WRAP);}
    JSONArray lyrics(JSONObject t)throws Exception{
        String id=text(t,"lyricID");if(id.isEmpty())id=text(t,"trackID");
        try {
            JSONObject raw=(JSONObject)catalogData(url(MusicSource.endpointOf(t),"types","lyric","source",text(t,"source"),"id",id),t.optBoolean("centralCatalog"),7*DAY,false);
            JSONArray lines=lines(text(raw,"lyric"),text(raw,"tlyric"));if(lines.length()>0)return lines;
        }catch(Exception first){if(!MusicSource.defaultNetEase(t))throw first;}
        if(!id.matches("[0-9]+")||!MusicSource.defaultNetEase(t))return new JSONArray();
        JSONObject raw=(JSONObject)fetch(url(NET+"/api/song/lyric","id",id,"lv","-1","tv","-1"),7*DAY,false);
        return lines(text(raw.optJSONObject("lrc"),"lyric"),text(raw.optJSONObject("tlyric"),"lyric"));
    }
    private static TreeMap<Integer,String> parse(String raw){
        TreeMap<Integer,String> entries=new TreeMap<>();
        for(String line:raw.split("\\r?\\n")){
            Matcher m=stamp.matcher(line);List<Integer> times=new ArrayList<>();int end=0;
            while(m.find()){
                times.add((int)Math.round(1000*(60*Integer.parseInt(m.group(1))+Double.parseDouble(m.group(2)))));
                end=m.end();
            }
            String value=line.substring(end).trim();if(!value.isEmpty())for(Integer time:times)entries.put(time,value);
        }return entries;
    }
    private static JSONArray lines(String orig,String translated){
        TreeMap<Integer,String> tr=parse(translated);JSONArray result=new JSONArray();
        for(Map.Entry<Integer,String> e:parse(orig).entrySet())result.put(object("time",e.getKey()/1000.0,"text",e.getValue(),"translation",e.getValue().equals(tr.get(e.getKey()))?"":tr.get(e.getKey())));
        return result;
    }
    static JSONObject fromNet(JSONObject row) {
        JSONObject album=row.optJSONObject("album");
        if(album==null)album=row.optJSONObject("al");
        if(album==null)return null;
        String artist=joinNames(row.has("artists")?row.optJSONArray("artists"):row.optJSONArray("ar"));
        String key=text(row,"id"), title=text(row,"name");
        if(artist.isEmpty()||title.isEmpty()||key.isEmpty())return null;
        String pic=text(album,"picId_str");if(pic.isEmpty())pic=text(album,"pic_str");
        if(pic.isEmpty())pic=text(album,"picId");
        String art=text(album,"picUrl").replace("http://","https://");
        if(!art.matches("https://[A-Za-z0-9.-]+\\.music\\.126\\.net/.*"))art="";
        if(!art.isEmpty())art=art.split("\\?")[0]+"?param=500y500";
        long released=row.optLong("publishTime");
        if(released<=0 && "Single".equals(album.optString("type")))released=album.optLong("publishTime");
        return object("id","netease:"+key,"source","netease","trackID",key,"title",title,"artist",artist,"album",text(album,"name"),"pictureID",pic,"lyricID",key,"artworkURL",art,"released",released,"catalogDurationMS",row.optLong("dt",row.optLong("duration")),"genres",new JSONArray());
    }
    private static LocalDate date(long ms){return Instant.ofEpochMilli(ms).atZone(ZoneId.of("Asia/Shanghai")).toLocalDate();}
    private static String label(long ms){LocalDate d=date(ms);return d.getMonthValue()+"月"+d.getDayOfMonth()+"日";}
    private String chartAddr(boolean hot){return url(NET+"/api/playlist/detail","id",hot?"3778678":"3779629");}
    private JSONObject chart(boolean hot,boolean force,boolean allowNetwork){
        String addr=chartAddr(hot);JSONObject reply=null;boolean stale=false;
        try{
            if(allowNetwork){
                if(force){
                    long epoch=epoch();byte[] bytes=network(addr,false,8*1024*1024);reply=new JSONObject(new String(bytes,StandardCharsets.UTF_8));
                    if(reply.optInt("code")!=200||reply.optJSONObject("result")==null)throw new IOException("榜单无数据");
                    store(addr,bytes,false,epoch);
                }else reply=(JSONObject)fetch(addr,3600000,false);
            }else{byte[] bytes=cached(addr,7*DAY,false);if(bytes!=null)reply=new JSONObject(new String(bytes,StandardCharsets.UTF_8));}
        }catch(Exception error){
            stale=true;
            try{byte[] bytes=cached(addr,7*DAY,false);if(bytes!=null)reply=new JSONObject(new String(bytes,StandardCharsets.UTF_8));}catch(Exception ignored){}
        }
        JSONArray songs=new JSONArray();JSONObject chart=reply==null?null:reply.optJSONObject("result");
        String name=hot?"网易云热歌榜":"网易云新歌榜";
        if(chart!=null){
            long updated=chart.optLong("updateTime");if(updated>0)name+=" · "+label(updated)+"更新";
            Set<String> seen=new HashSet<>();LocalDate cutoff=date(System.currentTimeMillis()).minusDays(6);
            for(JSONObject row:rows(array(chart,"tracks"))){
                JSONObject t=fromNet(row);if(t==null||!seen.add(id(t)))continue;
                if(!hot){
                    long ms=t.optLong("released");if(ms<=0||ms>System.currentTimeMillis()||date(ms).isBefore(cutoff))continue;
                    put(t,"releaseLabel",label(ms)+" 发行");
                }
                songs.put(t);
            }
        }
        return object("tracks",songs,"source",name,"stale",stale||chart==null);
    }
    JSONObject discovery(boolean force,boolean online){
        Future<JSONObject> hot=enrichment.submit(()->chart(true,force,online));
        JSONObject fresh=chart(false,force,online);
        JSONObject popular;
        try{popular=hot.get();}catch(Exception e){popular=object("tracks",new JSONArray(),"source","网易云热歌榜","stale",true);}
        return object("hot",popular.optJSONArray("tracks"),"newReleases",fresh.optJSONArray("tracks"),"hotSource",popular.optString("source"),"newSource",fresh.optString("source"),
            "notice",popular.optBoolean("stale")||fresh.optBoolean("stale")?"部分榜单暂时无法刷新，可稍后重试":"");
    }
    JSONArray genres(JSONObject t)throws Exception{
        if(!MusicSource.defaultNetEase(t))return array(t,"genres");
        String addr=url(NET+"/api/song/play/about/block/page","songId",text(t,"trackID"));
        JSONObject obj=(JSONObject)fetch(addr,30*DAY,false); JSONObject data=obj.optJSONObject("data");
        Set<String> tags=new LinkedHashSet<>();
        if(data!=null)for(JSONObject block:rows(array(data,"blocks"))){
            if(!"SONG_PLAY_ABOUT_SONG_BASIC".equals(text(block,"code")))continue;
            for(JSONObject section:rows(array(block,"creatives"))){
                if(!"songTag".equals(text(section,"creativeType")))continue;
                for(JSONObject r:rows(array(section,"resources"))){
                    if(!"melody_style".equals(text(r,"resourceType")))continue;
                    JSONObject ui=r.optJSONObject("uiElement");if(ui==null)continue;
                    for(String s:text(ui.optJSONObject("mainTitle"),"title").split("-"))
                        if(!s.trim().isEmpty())tags.add(s.trim());
                }
            }
        }
        return new JSONArray(tags);
    }
    JSONArray related(JSONObject t)throws Exception{
        if(t==null||!MusicSource.defaultNetEase(t))return new JSONArray();
        String key="neighbors/v1/"+id(t);byte[] stored=cached(key,DAY,false);if(stored!=null)return new JSONArray(new String(stored,StandardCharsets.UTF_8));
        long epoch=epoch();JSONArray result=new JSONArray();
        try{
            JSONObject reply=(JSONObject)fetch(url(NET+"/api/discovery/simiSong","songid",text(t,"trackID"),"limit","15"),DAY,false);
            Set<String> seen=new HashSet<>();seen.add(id(t));
            List<Future<JSONObject>> pending=new ArrayList<>();
            for(JSONObject row:rows(array(reply,"songs"))){
                JSONObject item=fromNet(row);if(item==null||!seen.add(id(item)))continue;
                pending.add(enrichment.submit(()->{try{put(item,"genres",genres(item));}catch(Exception ignored){}return item;}));
                if(pending.size()>=6)break;
            }
            for(Future<JSONObject> f:pending)result.put(f.get());
            if(result.length()>0)store(key,result.toString().getBytes(StandardCharsets.UTF_8),false,epoch);
        }catch(Exception e){stored=cached(key,30*DAY,false);if(stored==null)throw e;return new JSONArray(new String(stored,StandardCharsets.UTF_8));}
        return result;
    }
}
