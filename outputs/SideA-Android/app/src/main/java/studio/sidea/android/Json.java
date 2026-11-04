package studio.sidea.android;

import org.json.*;
import java.util.*;

final class Json {
    static JSONObject object(Object... pairs) {
        JSONObject result = new JSONObject();
        for (int i = 0; i < pairs.length; i += 2) put(result, (String)pairs[i], pairs[i+1]);
        return result;
    }
    static void put(JSONObject object, String key, Object value) {
        try { object.put(key, value == null ? JSONObject.NULL : value); }
        catch (JSONException e) { throw new IllegalArgumentException("无效的资料库数据", e); }
    }
    static JSONArray array(JSONObject object, String key) {
        JSONArray result = object.optJSONArray(key);
        return result == null ? new JSONArray() : result;
    }
    static List<JSONObject> rows(JSONArray a) {
        List<JSONObject> result = new ArrayList<>();
        if (a != null) for (int i=0; i<a.length(); i++) if (a.optJSONObject(i)!=null) result.add(a.optJSONObject(i));
        return result;
    }
    static String id(JSONObject t) {
        String legacy=t.optString("source","netease")+":"+t.optString("trackID");
        String endpoint=text(t,"apiEndpoint");
        // Length-prefixing keeps arbitrary endpoint paths and track IDs unambiguous.
        return endpoint.isEmpty() || endpoint.equals(MusicSource.GD) ? legacy : "custom@"+endpoint.length()+":"+endpoint+"|"+legacy;
    }
    static String text(JSONObject object, String key) {
        return object==null || object.isNull(key) ? "" : object.optString(key,"");
    }
    static void addUnique(List<JSONObject> target, List<JSONObject> songs) {
        Set<String> ids = new HashSet<>();
        for (JSONObject t:target) ids.add(id(t));
        for (JSONObject t:songs) if (t!=null && !text(t,"trackID").isEmpty() && ids.add(id(t))) target.add(t);
    }
}
