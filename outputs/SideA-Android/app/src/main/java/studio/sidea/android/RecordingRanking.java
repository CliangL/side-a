package studio.sidea.android;

import android.content.Context;
import android.icu.text.Transliterator;
import android.os.Build;
import org.json.*;
import java.text.Normalizer;
import java.util.*;
import java.util.regex.Pattern;
import static studio.sidea.android.Json.*;

/** Evidence is scoped to a specific recording. Source search position is not a popularity count. */
final class RecordingRanking {
    private static final int UNKNOWN=0, ORIGINAL=1, COVER=2, ORIGINAL_ARTIST=4;
    private static final Pattern BRACKETS=Pattern.compile("[（(\\[【]([^）)\\]】]+)[）)\\]】]");
    private static final Pattern LIVE=Pattern.compile("现场|現場|演唱会|演唱會|(?i)(?:[（(【\\[]\\s*live\\b|\\blive(?:\\s+(?:at|in|version)\\b|\\s*$))");
    private static final Pattern BACKING=Pattern.compile("伴奏|纯音乐版|純音樂版|卡拉ok|(?i)\\b(instrumental|karaoke)\\b");
    private static final Pattern REMIX=Pattern.compile("混音|加速版|减速版|慢速版|(?i)\\b(remix|sped up|slowed)\\b");
    private static final Pattern COVER_TEXT=Pattern.compile("翻唱|翻弹|翻彈|原唱[:：]|(?i)cover\\s+(by|of)|[（(【\\[]\\s*cover\\b");
    private static final Transliterator converter=Build.VERSION.SDK_INT>=29?Transliterator.getInstance("Traditional-Simplified"):null;

    private static String fold(String s){
        String value=Normalizer.normalize(s==null?"":s,Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
        if(converter!=null)synchronized(converter){value=converter.transliterate(value);}
        return value;
    }
    private static String key(String s){
        return fold(s).replaceAll("[^\\p{L}\\p{N}]+","");
    }
    private static String version(String s){
        if(COVER_TEXT.matcher(s).find())return "翻唱";
        if(BACKING.matcher(s).find())return "伴奏";
        if(REMIX.matcher(s).find())return "混音";
        if(LIVE.matcher(s).find())return "现场";
        return "";
    }
    private static String base(String name){
        String raw=fold(name);
        java.util.regex.Matcher m=BRACKETS.matcher(raw);
        StringBuffer out=new StringBuffer();
        while(m.find()){
            if(!version(m.group()).isEmpty())m.appendReplacement(out,"");
        }
        m.appendTail(out);
        return key(out.toString().replaceFirst("(?i)\\s+[-–—]\\s+(live|remix|instrumental|cover|现场|伴奏|翻唱).*?$",""));
    }
    private static String artists(String display){
        TreeSet<String> parts=new TreeSet<>();
        for(String part:display.split("[/／、;；]")){String value=key(part);if(!value.isEmpty())parts.add(value);}
        return String.join("|",parts);
    }
    static String searchTerm(String raw) {
        String value=raw.trim();
        // Remove an explicit search instruction, retaining ordinary titles containing these characters.
        String cleaned=value.replaceFirst("^原唱[：:\\s]+","")
                .replaceFirst("(?:\\s+原唱|[（(【]\\s*原唱\\s*[）)】])$","").trim();
        return cleaned.isEmpty()?value:cleaned;
    }
    static String originalTerm(String raw) {
        String term=searchTerm(raw);
        String title=term.replaceFirst("(?:的)?原唱$","").trim();
        return title.isEmpty()?term:title;
    }
    private static boolean exactQuery(String q,String title,String displayArtist) {
        if(q.isEmpty()||title.isEmpty())return false;
        if(q.equals(title))return true;
        List<String> credited=new ArrayList<>();
        credited.add(displayArtist);
        credited.addAll(Arrays.asList(displayArtist.split(" / |、|；|;|(?i)\\s+(?:&|feat\\.?|ft\\.?)\\s+")));
        for(String artist:credited){
            String a=key(artist);
            if(!a.isEmpty() && (q.equals(a+title)||q.equals(title+a)))return true;
        }
        return false;
    }
    private static String displayArtist(JSONArray array){
        List<String> parts=new ArrayList<>();
        for(JSONObject artist:rows(array))parts.add(text(artist,"name"));
        return String.join(" / ",parts);
    }
    private static final class Ref {
        String id,title,fullTitle,artist,displayArtist,album;int status,pop;long released;boolean linked;
        Ref(JSONObject row,boolean linked){
            this.linked=linked;
            id=text(row,linked?"songId":"id");
            title=base(text(row,"name"));
            fullTitle=key(text(row,"name"));
            released=row.optLong("publishTime");
            displayArtist=displayArtist(row.optJSONArray(linked?"artists":"ar"));
            artist=artists(displayArtist);
            album=key(text(row.optJSONObject(linked?"albumMeta":"al"),"name"));
            int type=row.optInt("originCoverType",0);
            status=linked?ORIGINAL:(type==ORIGINAL||type==COVER?type:UNKNOWN);
            pop=linked?-1:row.optInt("pop",-1);
            if(pop<0||pop>100)pop=-1;
        }
        boolean usable(){return !id.isEmpty()&&!title.isEmpty()&&!artist.isEmpty();}
    }
    private static void append(List<Ref> refs,JSONArray songs){
        for(JSONObject row:rows(songs)){
            Ref r=new Ref(row,false);
            JSONObject original=row.optJSONObject("originSongSimpleData");
            if(original!=null){
                Ref relation=new Ref(original,true);
                if(relation.usable()&&!relation.id.equals(r.id)){
                    refs.add(relation);
                    r.status=COVER;
                }
            }
            if(r.usable())refs.add(r);
        }
    }

    private static JSONArray cloudSearch(Catalog catalog,String term)throws Exception{
        JSONObject reply=catalog.referenceData("/api/cloudsearch/pc","s",term,"type","1","offset","0","limit","50");
        JSONObject result=reply.optJSONObject("result");
        return result==null?new JSONArray():array(result,"songs");
    }
    private static JSONObject details(Catalog catalog,Collection<String> ids)throws Exception{
        JSONArray c=new JSONArray();
        for(String id:ids)c.put(object("id",id));
        return catalog.referenceData("/api/v3/song/detail","c",c.toString());
    }

    /** Expand an exact song search from publisher-provided recording links, including absent GD hits. */
    static void includeOriginals(Catalog catalog,String term,List<JSONObject> tracks) {
        JSONArray songs;
        try{songs=cloudSearch(catalog,term);}catch(Exception unavailable){return;}
        List<Ref> refs=new ArrayList<>();
        append(refs,songs);
        String query=key(term);
        Map<String,Ref> wanted=new LinkedHashMap<>();
        Map<String,JSONObject> known=new HashMap<>(), access=new HashMap<>();
        for(JSONObject row:rows(songs)){
            known.put(text(row,"id"),row);
            JSONObject privilege=row.optJSONObject("privilege");
            if(privilege!=null)access.put(text(row,"id"),privilege);
        }
        // Use an explicit cover-to-original pointer first when a title has many namesakes.
        for(boolean linked:new boolean[]{true,false}){
            for(Ref r:refs){
                if(r.linked!=linked || r.status!=ORIGINAL || !r.id.matches("[0-9]+"))continue;
                if(wanted.size()>=8)break;
                if(exactQuery(query,r.fullTitle,r.displayArtist))wanted.putIfAbsent(r.id,r);
            }
        }
        if(!wanted.isEmpty()){
            try{
                JSONObject reply=details(catalog,wanted.keySet());
                for(JSONObject row:rows(reply.optJSONArray("songs")))known.put(text(row,"id"),row);
                for(JSONObject row:rows(reply.optJSONArray("privileges")))access.put(text(row,"id"),row);
                append(refs,reply.optJSONArray("songs"));
            }catch(Exception unavailable){ /* An original returned by cloud search already has a full catalog identity. */ }
        }
        Map<String,JSONObject> byID=new HashMap<>();
        for(JSONObject t:tracks)byID.put(text(t,"trackID"),t);
        for(Ref ref:wanted.values()){
            JSONObject row=known.get(ref.id);if(row==null)continue;
            Ref detail=new Ref(row,false);
            if(detail.status==COVER || !detail.artist.equals(ref.artist) || !detail.fullTitle.equals(ref.fullTitle))continue;
            JSONObject t=byID.get(ref.id);
            if(t==null){
                t=Catalog.fromNet(row);if(t==null)continue;
                put(t,"canonicalRecovered",true);
                put(t,"sourceRank",tracks.size()+1);tracks.add(t);byID.put(ref.id,t);
            }
            put(t,"catalogDurationMS",row.optLong("dt"));
            JSONObject privilege=access.get(ref.id);
            if(privilege!=null && privilege.optInt("st")<0)
                put(t,"originAccessNote","网易云目录标记受限");
        }
        for(JSONObject t:tracks)put(t,"recordingEvidence",recognize(t,refs));
    }

    static void evidence(Context context,String query,List<JSONObject> tracks){
        if(tracks.isEmpty()||query.trim().isEmpty())return;
        Catalog catalog=new Catalog(context);
        List<Ref> refs=new ArrayList<>();
        Set<String> detailed=new HashSet<>();
        try {
            JSONArray songs=cloudSearch(catalog,originalTerm(query));
            append(refs,songs);
            for(JSONObject s:rows(songs))detailed.add(text(s,"id"));
        } catch(Exception unavailable){ /* Sorting by local relevance, version and charts still works. */ }
        Set<String> ids=new LinkedHashSet<>();
        for(JSONObject t:tracks)if(MusicSource.defaultNetEase(t)&&text(t,"trackID").matches("[0-9]+"))ids.add(text(t,"trackID"));
        ids.removeAll(detailed);
        List<String> missing=new ArrayList<>(ids);
        // A page contains 25 songs per source. Batch details, never one metadata request per result.
        for(int start=0;start<missing.size();start+=60){
            try{JSONObject reply=details(catalog,missing.subList(start,Math.min(start+60,missing.size())));
                append(refs,reply.optJSONArray("songs"));}
            catch(Exception unavailable){break;}
        }
        for(JSONObject t:tracks){
            JSONObject fact=recognize(t,refs);
            JSONObject prev=t.optJSONObject("recordingEvidence");
            // A transient reference lookup must not erase recording facts from the first search page.
            if(prev!=null){
                if(fact.optInt("status")==UNKNOWN)put(fact,"status",prev.optInt("status"));
                if(fact.optInt("pop",-1)<0)put(fact,"pop",prev.optInt("pop",-1));
                if(fact.optLong("released")==0)put(fact,"released",prev.optLong("released"));
                if(text(fact,"chartId").isEmpty())put(fact,"chartId",text(prev,"chartId"));
                if(prev.optBoolean("linked"))put(fact,"linked",true);
            }
            put(t,"recordingEvidence",fact);
        }
    }

    private static JSONObject recognize(JSONObject t,List<Ref> refs){
        String artist=artists(text(t,"artist")),title=base(text(t,"title")),album=key(text(t,"album")),v=version(fold(text(t,"title")));
        boolean nativeID=MusicSource.defaultNetEase(t);
        int status=UNKNOWN,pop=-1;String matched="";long released=0;boolean linked=false;
        if(nativeID) {
            // Prefer explicit metadata for this recording; an original-song pointer can have the same id.
            for(Ref r:refs)if(r.id.equals(text(t,"trackID"))){
                if(r.status==COVER)status=COVER;
                else if(r.status==ORIGINAL && status!=COVER)status=ORIGINAL;
                if(r.linked)linked=true;
                if(r.pop>=0)pop=r.pop;
                if(r.released>0)released=r.released;
                matched=r.id;
            }
        }
        boolean uploader="bilibili".equals(text(t,"source"));
        if(!uploader&&!title.isEmpty()&&!artist.isEmpty() && (!nativeID || status==UNKNOWN)){
            boolean original=false,cover=false,artistLinked=false;
            Set<String> exact=new HashSet<>();Ref equivalent=null;
            for(Ref r:refs) {
                if(!title.equals(r.title)||!artist.equals(r.artist))continue;
                if(r.status==ORIGINAL){original=true;if(r.linked)artistLinked=true;}
                if(r.status==COVER)cover=true;
                if(!album.isEmpty()&&album.equals(r.album)&&key(text(t,"title")).equals(r.fullTitle)){
                    exact.add(r.id);
                    if(equivalent==null||r.pop>=0)equivalent=r;
                }
            }
            if(!nativeID && exact.size()==1 && equivalent!=null){
                matched=equivalent.id;pop=equivalent.pop;released=equivalent.released;
                if(equivalent.status==COVER)status=COVER;
                else if(equivalent.status==ORIGINAL)status=ORIGINAL_ARTIST;
            }
            if(status==UNKNOWN && original && !cover)status=ORIGINAL_ARTIST;
            if(status==ORIGINAL_ARTIST)linked=artistLinked;
        }
        if(v.equals("翻唱"))status=COVER;
        return object("status",status,"pop",pop,"chartId",matched,"released",released,"linked",linked);
    }

    private static String badge(int status,String v,int chart){
        List<String> tags=new ArrayList<>();
        if(status==COVER||v.equals("翻唱")) tags.add("翻唱");
        else if(status==ORIGINAL||status==ORIGINAL_ARTIST) tags.add(v.isEmpty()&&status==ORIGINAL?"原唱":"原唱歌手");
        if(!v.isEmpty()&&!v.equals("翻唱"))tags.add(v);
        if(chart>0)tags.add("网易云热歌榜 #"+chart);
        return String.join(" · ",tags);
    }

    private static final class Row {
        final JSONObject t;final int relevance,requested,recording,corroborated,confirmed,hot,pop,position; final long releaseOrder;
        Row(JSONObject t,String query,String requestedVersion,Map<String,Integer> chart,int position){
            this.t=t;this.position=t.optInt("sourceRank",position+1);
            String raw=text(t,"title"),title=key(raw),base=base(raw),artist=key(text(t,"artist")),v=version(fold(raw));
            JSONObject ev=t.optJSONObject("recordingEvidence");
            int status=ev==null?UNKNOWN:ev.optInt("status");
            if(v.equals("翻唱"))status=COVER;
            String literal=key(query);
            String q=key(fold(originalTerm(query)).replaceAll("(?i)\\blive\\b|\\bremix\\b|\\binstrumental\\b|\\bcover\\b|现场|伴奏|翻唱|混音",""));
            // Match the requested title/artist combination before using any evidence about other songs.
            if(!literal.isEmpty() && !literal.equals(q) && literal.equals(title))relevance=6;
            else if(literal.equals(title) || exactQuery(q,title,text(t,"artist")) || exactQuery(q,base,text(t,"artist")))relevance=5;
            else if(!artist.isEmpty()&&q.equals(artist))relevance=4;
            else if(!q.isEmpty()&&(title.contains(q)||artist.contains(q)))relevance=3;
            else if(!base.isEmpty()&&q.contains(base))relevance=2;
            else relevance=1;
            requested=!requestedVersion.isEmpty()&&(v.equals(requestedVersion)||(requestedVersion.equals("翻唱")&&status==COVER))?1:0;
            if(status==COVER)recording=0;
            else if(status==ORIGINAL || status==ORIGINAL_ARTIST)recording=v.isEmpty()?6:2;
            else recording=v.isEmpty()?3:1;
            corroborated=ev!=null && ev.optBoolean("linked") && (status==ORIGINAL||status==ORIGINAL_ARTIST)?1:0;
            confirmed=status==ORIGINAL?1:0;
            long released=ev==null?0:ev.optLong("released");
            releaseOrder=recording>=5 && released>0?released:Long.MAX_VALUE;
            String chartId=MusicSource.defaultNetEase(t)?text(t,"trackID"):text(ev,"chartId");
            hot=chart.getOrDefault(chartId,Integer.MAX_VALUE);
            pop=ev==null?-1:ev.optInt("pop",-1);
            String note=badge(status,v,hot==Integer.MAX_VALUE?0:hot);
            if(hot==Integer.MAX_VALUE && pop>=0)note+=(note.isEmpty()?"":" · ")+"网易热度 "+pop;
            put(t,"rankBadge",note);
        }
    }
    static JSONArray rank(List<JSONObject> tracks,String query,JSONArray hotSongs){
        Map<String,Integer> chart=new HashMap<>();int n=0;
        for(JSONObject song:rows(hotSongs)){n++;if(MusicSource.defaultNetEase(song))chart.putIfAbsent(text(song,"trackID"),n);}
        List<Row> scored=new ArrayList<>();int position=0;String requested=version(fold(query));
        if(requested.isEmpty() && fold(query).matches("(?s).*?\\blive\\b.*"))requested="现场";
        if(requested.isEmpty() && fold(query).matches("(?s).*?\\bcover\\b.*"))requested="翻唱";
        for(JSONObject t:tracks)scored.add(new Row(t,query,requested,chart,position++));
        scored.sort(Comparator.<Row>comparingInt(r->r.relevance).reversed()
            .thenComparing(Comparator.<Row>comparingInt(r->r.requested).reversed())
            .thenComparing(Comparator.<Row>comparingInt(r->r.recording).reversed())
            .thenComparing(Comparator.<Row>comparingInt(r->r.corroborated).reversed())
            .thenComparingInt(r->r.hot)
            .thenComparing(Comparator.<Row>comparingInt(r->r.pop).reversed())
            .thenComparingLong(r->r.releaseOrder)
            .thenComparing(Comparator.<Row>comparingInt(r->r.confirmed).reversed())
            .thenComparingInt(r->r.position)
            .thenComparing(r->id(r.t)));
        JSONArray result=new JSONArray();for(Row row:scored)result.put(row.t);return result;
    }
}
