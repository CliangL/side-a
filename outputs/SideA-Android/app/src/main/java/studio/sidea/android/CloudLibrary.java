package studio.sidea.android;

import android.content.Context;
import java.io.IOException;
import java.util.concurrent.*;
import org.json.*;
import static studio.sidea.android.Json.*;

/** Quiet per-device backup. Local edits are always available before the network responds. */
final class CloudLibrary {
    private static final ScheduledExecutorService worker=Executors.newSingleThreadScheduledExecutor();
    private static ScheduledFuture<?> pending;
    private static Context context;
    private static boolean running,requested,bound;
    private static int failures;
    static void start(Context ctx){schedule(ctx,0);}
    static void changed(Context ctx){schedule(ctx,1200);}
    private static synchronized void schedule(Context ctx,long delay){
        context=ctx.getApplicationContext();
        if(running){requested=true;return;}
        if(pending!=null)pending.cancel(false);
        pending=worker.schedule(CloudLibrary::run,delay,TimeUnit.MILLISECONDS);
    }
    private static void run(){
        Context ctx;synchronized(CloudLibrary.class){running=true;requested=false;pending=null;ctx=context;}
        boolean ok=false,more=false;
        try{sync(ctx);ok=true;more=Library.cloudDirty(ctx);}catch(Exception unavailable){/* Keep the durable pending difference for a later connection. */}
        synchronized(CloudLibrary.class){
            running=false;failures=ok?0:Math.min(5,failures+1);
            long delay=ok?(requested||more?1500:90000):Math.min(90000,5000L*(1L<<failures));
            pending=worker.schedule(CloudLibrary::run,delay,TimeUnit.MILLISECONDS);
        }
    }
    private static JSONObject snapshot(CentralCatalog.LibraryReply reply)throws Exception{
        JSONObject result=reply.body;
        if(!result.has("revision")||!result.has("data")||result.optLong("revision",-1)<0)throw new IOException("资料库响应暂不可用");
        Object raw=result.opt("data");
        if(raw==JSONObject.NULL){if(result.getLong("revision")!=0)throw new IOException("备份内容不完整");return new JSONObject();}
        if(!(raw instanceof JSONObject))throw new IOException("备份内容不完整");
        JSONObject data=(JSONObject)raw;
        if(data.optInt("schema")!=1||!"android".equals(data.optString("platform"))||data.optJSONObject("library")==null||data.optJSONObject("settings")==null)
            throw new IOException("备份版本暂不兼容");
        return data;
    }
    private static void sync(Context ctx)throws Exception{
        CentralCatalog.enrollIfNeeded(ctx);
        CentralCatalog.LibraryReply remote;
        if(!bound){
            String recovery=CentralCatalog.recovery(ctx);if(recovery==null)throw new IOException("此安装未启用设备恢复");
            remote=CentralCatalog.library(ctx,"POST","/v1/library/bind",object("recovery",recovery,"platform","android"));
            if(remote.status!=200)throw new IOException("设备资料库暂未绑定");
            snapshot(remote);bound=true;
        }else{
            remote=CentralCatalog.library(ctx,"GET","/v1/library",null);
            if(remote.status!=200){bound=false;throw new IOException("设备资料库暂不可用");}
        }
        for(int attempt=0;attempt<4;attempt++){
            JSONObject data=snapshot(remote);long revision=remote.body.getLong("revision");
            JSONObject next=Library.mergeCloud(ctx,data,revision);
            if(LibraryMerge.same(next,data))return;
            CentralCatalog.LibraryReply reply=CentralCatalog.library(ctx,"PUT","/v1/library",object("revision",revision,"data",next));
            JSONObject acknowledged=snapshot(reply);
            if(reply.status==200){
                if(!LibraryMerge.same(next,acknowledged)||reply.body.getLong("revision")<revision)throw new IOException("备份确认暂不可用");
                Library.acknowledgeCloud(ctx,next,reply.body.getLong("revision"));return;
            }
            remote=reply;
        }
        throw new IOException("资料库正在同步其他改动");
    }
    private CloudLibrary(){}
}
