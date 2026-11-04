package studio.sidea.android;

import android.content.SharedPreferences;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.*;
import org.json.JSONObject;
import static studio.sidea.android.Json.*;

final class MusicSource {
    static final String GD="https://music-api.gdstudio.xyz/api.php";
    final String endpoint, code, label;
    final boolean central;
    final String provider;
    MusicSource(String endpoint, String code, String label) {
        this(endpoint,code,label,false,"");
    }
    private MusicSource(String endpoint,String code,String label,boolean central,String provider){
        this.central=central;
        this.provider=provider;
        this.endpoint=endpoint;
        this.code=code;
        this.label=label;
    }

    static String normalizeEndpoint(String value) {
        try {
            URI uri=new URI(value.trim());
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost()==null ||
                    uri.getRawUserInfo()!=null || uri.getRawQuery()!=null || uri.getRawFragment()!=null ||
                    uri.getPort()>65535 || uri.getPort()==0)
                throw new URISyntaxException(value, "endpoint");
            String port=uri.getPort()==-1||uri.getPort()==443?"":":"+uri.getPort();
            String path=uri.getRawPath();
            return "https://"+uri.getHost().toLowerCase(Locale.ROOT)+port+(path.isEmpty()?"/":path);
        } catch (URISyntaxException e) {
            throw new IllegalArgumentException("请填写完整的 HTTPS 接口地址，不含账号、查询参数或片段");
        }
    }
    static String scope(String selection){ return Arrays.asList("qq","wy","kw","jx").contains(selection)?selection:"all"; }
    static String providerLabel(String provider){switch(provider){case "qq":return "QQ 音乐";case "wy":return "网易云";case "kw":return "酷我音乐";case "jx":return "JOOX";default:return "统一曲库";}}
    static String builtinLabel(String value) {
        switch(value) {
            case "netease":return "网易云音乐";
            case "joox":return "JOOX";
            case "bilibili":return "哔哩哔哩";
            default:throw new IllegalArgumentException("无法识别搜索曲库");
        }
    }
    static MusicSource from(SharedPreferences prefs,String selection) {
        if (selection.equals("central") || !scope(selection).equals("all")) {
            String base=CentralCatalog.base(prefs);
            if(base.isEmpty())throw new IllegalArgumentException("统一后台尚未连接");
            String provider=selection.equals("central")?"":selection;
            return new MusicSource(CentralCatalog.endpoint(base),"central",providerLabel(provider),true,provider);
        }
        return new MusicSource(GD,selection,builtinLabel(selection));
    }
    static List<String> selections(SharedPreferences prefs,String selected) {
        if (!scope(selected).equals("all")) return Collections.singletonList(selected);
        if (!CentralCatalog.base(prefs).isEmpty()) return Collections.singletonList("central");
        List<String> publicSources=Arrays.asList("netease","joox","bilibili");
        return publicSources.contains(selected) ? Collections.singletonList(selected) : publicSources;
    }
    boolean isDefaultNetEase(){return GD.equals(endpoint)&&"netease".equals(code);}
    static String endpointOf(JSONObject track) {
        String saved=text(track,"apiEndpoint");
        return saved.isEmpty()?GD:normalizeEndpoint(saved);
    }
    static boolean defaultNetEase(JSONObject track){
        return "netease".equals(text(track,"source"))&&GD.equals(endpointOf(track));
    }
    static String referer(String endpoint){
        if (GD.equals(endpoint))return "https://music.gdstudio.xyz/";
        URI uri=URI.create(endpoint);
        return "https://"+uri.getRawAuthority()+"/";
    }
    static String mediaReferer(String address,String fallback){
        try{
            URI uri=URI.create(address);String host=uri.getHost();
            if("https".equalsIgnoreCase(uri.getScheme())&&host!=null&&host.toLowerCase(Locale.ROOT).matches("kw-[a-z0-9-]+\\.kuwo\\.cn"))
                return "https://www.kuwo.cn/";
        }catch(IllegalArgumentException ignored){}
        return fallback;
    }
}
