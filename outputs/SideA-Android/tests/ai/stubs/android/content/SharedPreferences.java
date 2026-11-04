package android.content;
public interface SharedPreferences {
 String getString(String key,String fallback);long getLong(String key,long fallback);Editor edit();
 interface Editor { Editor putString(String key,String value);Editor putLong(String key,long value);Editor clear();Editor remove(String key);boolean commit();void apply(); }
}
