package android.content;
import java.util.*;
public class Context {
 public static final int MODE_PRIVATE=0;
 private final Map<String,SharedPreferences> stores=new HashMap<>();
 public Context getApplicationContext(){return this;}
 public synchronized SharedPreferences getSharedPreferences(String key,int mode){return stores.computeIfAbsent(key,k->new Memory());}
 private static class Memory implements SharedPreferences {
  final Map<String,Object> values=new HashMap<>();
  public synchronized String getString(String k,String fallback){return (String)values.getOrDefault(k,fallback);}
  public synchronized long getLong(String k,long fallback){return (Long)values.getOrDefault(k,fallback);}
  public Editor edit(){return new Editor(){
   final Map<String,Object> next=new HashMap<>();final Set<String> removed=new HashSet<>();boolean clear;
   public Editor putString(String k,String v){next.put(k,v);return this;}
   public Editor putLong(String k,long v){next.put(k,v);return this;}
   public Editor clear(){clear=true;return this;}
   public Editor remove(String key){removed.add(key);return this;}
   public boolean commit(){synchronized(Memory.this){if(clear)values.clear();for(String key:removed)values.remove(key);values.putAll(next);}return true;}
   public void apply(){commit();}
  };}
 }
}
