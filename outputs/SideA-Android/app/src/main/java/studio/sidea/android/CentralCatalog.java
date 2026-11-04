package studio.sidea.android;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;
import android.util.AtomicFile;
import android.os.Build;
import android.provider.Settings;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import javax.net.ssl.HttpsURLConnection;
import org.json.*;
import static studio.sidea.android.Json.*;

/** Each installation holds only its own device credential. The QQ session stays on the server. */
final class CentralCatalog {
    private static final String KEY_ALIAS="studio.sidea.central.v1";
    private static final String BASE="centralBase", SEALED="centralSecret";
    private static final String PERSONAL_BASE="https://music.cliang.top";
    private static final String SKIP_AUTOMATIC="centralAutoDisabled";
    private static long retryAfter;
    static String base(SharedPreferences prefs) { return prefs.getString(BASE,""); }
    static String endpoint(String base) { return base+"/v1/music"; }

    private static synchronized SecretKey key() throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        SecretKey existing=(SecretKey)store.getKey(KEY_ALIAS,null);
        if(existing!=null)return existing;
        KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
    private static HttpsURLConnection connection(String address)throws Exception {
        HttpsURLConnection request=(HttpsURLConnection)new URL(address).openConnection();
        request.setInstanceFollowRedirects(false);
        request.setUseCaches(false);
        request.setConnectTimeout(8500);
        request.setReadTimeout(12000);
        request.setRequestProperty("Accept","application/json");
        return request;
    }
    private static byte[] response(HttpsURLConnection request,boolean pairing)throws Exception {
        int status=request.getResponseCode();
        if(status==401||status==403)throw new IOException(pairing?"暂时无法连接曲库。":"设备授权已失效。");
        if(status>=300 && status<400)throw new IOException("曲库地址暂不可用。");
        if(status<200||status>=300){
            String message=pairing?"暂时无法连接曲库。":"统一曲库请求失败（"+status+"）。";
            try(java.io.InputStream error=request.getErrorStream()){
                if(error!=null){
                    String reason=new JSONObject(new String(Catalog.read(error,8192),java.nio.charset.StandardCharsets.UTF_8)).optString("error","").trim();
                    if(!reason.isEmpty() && reason.length()<=180)message=reason;
                }
            }catch(JSONException|IOException ignored){}
            throw new IOException(message);
        }
        return Catalog.read(request.getInputStream(),pairing?65536:8*1024*1024);
    }
    private static String deviceName(Context ctx){
        String name=(Build.MANUFACTURER+" "+Build.MODEL).trim();
        return "studio.sidea.car".equals(ctx.getPackageName()) ? name+" · Side A 车机版" : name;
    }

    private static String installation(Context ctx) throws IOException {
        AtomicFile file=new AtomicFile(new File(ctx.getNoBackupFilesDir(),"central-installation"));
        if(file.getBaseFile().isFile()){
            String value=new String(file.readFully(),StandardCharsets.US_ASCII);
            if(!value.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"))
                throw new IOException("设备标识无法读取");
            return value;
        }
        String value=UUID.randomUUID().toString();
        FileOutputStream stream=file.startWrite();
        try{stream.write(value.getBytes(StandardCharsets.US_ASCII));file.finishWrite(stream);}
        catch(IOException failure){file.failWrite(stream);throw failure;}
        return value;
    }

    // Serialize activation and search when both try to register the same installation.
    static synchronized boolean enrollIfNeeded(Context ctx){
        SharedPreferences prefs=ctx.getSharedPreferences("sidea.settings",Context.MODE_PRIVATE);
        if(!base(prefs).isEmpty()||prefs.getBoolean(SKIP_AUTOMATIC,false)||SystemClock.elapsedRealtime()<retryAfter)
            return false;
        try(InputStream input=ctx.getAssets().open("SideASetup.txt")){
            String ticket=new String(Catalog.read(input,1024),StandardCharsets.US_ASCII).trim();
            if(!ticket.matches("[A-Za-z0-9._~-]{24,512}"))return false;
            String installation=installation(ctx);
            SecretKey secretKey=key();
            JSONObject enrollment=object("installation",installation,"name",deviceName(ctx));
            String recovery=recovery(ctx);
            if(recovery!=null){put(enrollment,"recovery",recovery);put(enrollment,"platform","android");}
            String token=requestToken(PERSONAL_BASE+"/v1/enroll",enrollment,ticket);
            save(prefs,PERSONAL_BASE,secretKey,token);
            return true;
        }catch(Exception unavailable){
            retryAfter=SystemClock.elapsedRealtime()+15000;
            return false;
        }
    }

    private static String requestToken(String address,JSONObject body,String ticket)throws Exception{
        byte[] payload=body.toString().getBytes(StandardCharsets.UTF_8);
        HttpsURLConnection request=connection(address);
        try {
            request.setRequestMethod("POST");
            request.setDoOutput(true);
            request.setFixedLengthStreamingMode(payload.length);
            request.setRequestProperty("Content-Type","application/json; charset=utf-8");
            if(ticket!=null){
                request.setRequestProperty("Authorization","SideA-Setup "+ticket);
                request.setConnectTimeout(4000);
                request.setReadTimeout(6000);
            }
            try(OutputStream out=request.getOutputStream()) { out.write(payload); }
            JSONObject result=new JSONObject(new String(response(request,true),StandardCharsets.UTF_8));
            return text(result,"token");
        } finally { request.disconnect(); }
    }

    private static void save(SharedPreferences prefs,String base,SecretKey secretKey,String token)throws Exception {
        if(!token.matches("[!-~]{1,2048}"))throw new IOException("后台未提供有效的设备凭据。");
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE,secretKey);
        cipher.updateAAD(base.getBytes(StandardCharsets.UTF_8));
        String sealed=Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP)+"."+
                Base64.encodeToString(cipher.doFinal(token.getBytes(StandardCharsets.UTF_8)),Base64.NO_WRAP);
        // Keep the old working pairing unless the replacement has been validated.
        SharedPreferences.Editor editor=prefs.edit().putString(BASE,base).putString(SEALED,sealed).remove(SKIP_AUTOMATIC);
        if(!editor.commit())
            throw new IOException("设备配对信息未能保存，请重试。");
    }
    private static String token(SharedPreferences prefs)throws IOException {
        try {
            String[] parts=prefs.getString(SEALED,"").split("\\.",2);
            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(parts[0],Base64.NO_WRAP)));
            cipher.updateAAD(base(prefs).getBytes(StandardCharsets.UTF_8));
            return new String(cipher.doFinal(Base64.decode(parts[1],Base64.NO_WRAP)),StandardCharsets.UTF_8);
        }catch(Exception invalid){throw new IOException("设备授权暂不可用。");}
    }
    static Object get(SharedPreferences prefs,String address)throws Exception {
        String base=base(prefs);
        int split=address.indexOf('?');
        if(base.isEmpty()||split<0||!address.substring(0,split).equals(endpoint(base)))
            throw new IOException("这首歌的来源暂不可用。");
        HttpsURLConnection request=connection(address);
        try {
            request.setRequestProperty("Authorization","Bearer "+token(prefs));
            Object result=new JSONTokener(new String(response(request,false),StandardCharsets.UTF_8)).nextValue();
            if(result instanceof JSONObject && ((JSONObject)result).has("error"))
                throw new IOException("统一曲库未能提供这条录音，请检查后台的音源状态。");
            return result;
        } finally { request.disconnect(); }
    }

    // Only this app-specific HMAC leaves the device. The private seed is independent of setup-ticket rotation.
    static String recovery(Context ctx)throws Exception {
        String seed;
        try(InputStream input=ctx.getAssets().open("SideARecoverySeed.txt")){
            seed=new String(Catalog.read(input,1024),StandardCharsets.US_ASCII).trim();
        }catch(java.io.FileNotFoundException noSeed){return null;}
        if(!seed.matches("[A-Za-z0-9._~-]{32,512}"))throw new IOException("恢复配置无效");
        String identity=Settings.Secure.getString(ctx.getContentResolver(),Settings.Secure.ANDROID_ID);
        if(identity==null||!identity.matches("[0-9a-fA-F]{1,16}")||identity.matches("0+")){
            // Unsupported device implementations get a random per-install key, never a shared fallback.
            identity="install:"+installation(ctx);
            android.util.Log.w("SideA","Stable device recovery unavailable; keeping an installation-only backup");
        }
        Mac hmac=Mac.getInstance("HmacSHA256");
        hmac.init(new SecretKeySpec(seed.getBytes(StandardCharsets.US_ASCII),"HmacSHA256"));
        // Keep existing phone recovery byte-for-byte compatible. A separate car app on the
        // same Android device must not take over the phone app's private backup/session.
        String namespace="studio.sidea.car".equals(ctx.getPackageName())?"SideA recovery v1|car|":"SideA recovery v1|";
        byte[] hash=hmac.doFinal((namespace+identity.toLowerCase(java.util.Locale.ROOT)).getBytes(StandardCharsets.UTF_8));
        StringBuilder out=new StringBuilder();for(byte b:hash)out.append(String.format(java.util.Locale.ROOT,"%02x",b&255));return out.toString();
    }
    static final class LibraryReply {
        final int status;final JSONObject body;
        LibraryReply(int status,JSONObject body){this.status=status;this.body=body;}
    }
    static LibraryReply library(Context ctx,String method,String path,JSONObject body)throws Exception {
        SharedPreferences prefs=ctx.getSharedPreferences("sidea.settings",Context.MODE_PRIVATE);
        String base=base(prefs);
        if(!PERSONAL_BASE.equals(base)||!path.matches("/v1/library(?:/bind)?"))throw new IOException("资料库暂未连接");
        HttpsURLConnection request=connection(base+path);
        try{
            request.setRequestMethod(method);request.setRequestProperty("Authorization","Bearer "+token(prefs));
            if(body!=null){
                byte[] bytes=body.toString().getBytes(StandardCharsets.UTF_8);
                request.setRequestProperty("Content-Type","application/json; charset=utf-8");request.setDoOutput(true);request.setFixedLengthStreamingMode(bytes.length);
                try(OutputStream stream=request.getOutputStream()){stream.write(bytes);}
            }
            int status=request.getResponseCode();
            if(status!=200&&status!=409)throw new IOException("资料库同步暂不可用（"+status+"）");
            try(InputStream stream=status==409?request.getErrorStream():request.getInputStream()){
                return new LibraryReply(status,new JSONObject(new String(Catalog.read(stream,16*1024*1024),StandardCharsets.UTF_8)));
            }
        }finally{request.disconnect();}
    }
    private CentralCatalog() {}
}
