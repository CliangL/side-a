package studio.sidea.bootqa;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebView;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.widget.Button;
import java.io.FileNotFoundException;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Emulator-only, credential-free native startup tests. No catalog or playback requests. */
public final class StartupProbe extends Instrumentation {
    private Activity activity;
    private Throwable setupFailure;
    private final Bundle result=new Bundle();
    private interface Work {void run()throws Exception;}
    @Override public void onCreate(Bundle options){super.onCreate(options);start();}
    private Object field(String name)throws Exception{
        Field field=activity.getClass().getDeclaredField(name);field.setAccessible(true);return field.get(activity);
    }
    private Object invoke(String name,Class<?>[] types,Object... values)throws Exception{
        Method method=activity.getClass().getDeclaredMethod(name,types);method.setAccessible(true);return method.invoke(activity,values);
    }
    private void check(boolean condition,String message){if(!condition)throw new AssertionError(message);}
    private void ui(Work work)throws Exception{
        AtomicReference<Throwable> error=new AtomicReference<>();
        runOnMainSync(()->{try{work.run();}catch(Throwable failure){error.set(failure);}});
        if(error.get()!=null)throw new Exception("UI assertion failed",error.get());
    }
    private void verifyCleanEmulator()throws Exception{
        check("ranchu".equals(Build.HARDWARE)||"goldfish".equals(Build.HARDWARE),"Only an Android SDK emulator may run this test");
        Context context=getTargetContext();
        check(context.getSharedPreferences("sidea.settings",0).getAll().isEmpty(),"Use a fresh credential-free QA installation");
        check(context.getSharedPreferences("sidea.library",0).getAll().isEmpty(),"Use a fresh installation without a personal library");
        for(String name:new String[]{"SideASetup.txt","SideARecoverySeed.txt"}){
            try(InputStream unused=context.getAssets().open(name)){throw new AssertionError("Do not use a private distribution APK");}
            catch(FileNotFoundException expected){}
        }
        context.getSharedPreferences("sidea.settings",0).edit().putBoolean("centralAutoDisabled",true).commit();
    }
    // Stop packaged JS before the first UI event turn; only this local test fixture can execute.
    @Override public void callActivityOnCreate(Activity target,Bundle state){
        super.callActivityOnCreate(target,state);
        if(!target.getClass().getName().equals("studio.sidea.android.MainActivity"))return;
        activity=target;
        try{holdPage();}catch(Throwable failure){setupFailure=failure;}
    }
    private void holdPage()throws Exception{
        WebView view=(WebView)field("web");check(view!=null,"WebView creation failed");
        view.stopLoading();view.getSettings().setBlockNetworkLoads(true);
        view.loadDataWithBaseURL("https://sidea.local/index.html","<!doctype html><html><body>Local startup fixture</body></html>","text/html","UTF-8",null);
    }
    private String script(String code)throws Exception{
        CountDownLatch evaluated=new CountDownLatch(1);AtomicReference<String> value=new AtomicReference<>();
        ui(()->((WebView)field("web")).evaluateJavascript(code,result->{value.set(result);evaluated.countDown();}));
        check(evaluated.await(3,TimeUnit.SECONDS),"Fixture JS evaluation timed out");waitForIdleSync();return value.get();
    }
    private void waitFixture()throws Exception{
        long end=SystemClock.elapsedRealtime()+3000;
        while(SystemClock.elapsedRealtime()<end){
            if("true".equals(script("Boolean(document.body && document.body.textContent === 'Local startup fixture')")))return;
            SystemClock.sleep(25);
        }
        throw new AssertionError("Local fixture did not finish loading");
    }
    private void awaitReady(boolean desired)throws Exception{
        long end=SystemClock.elapsedRealtime()+3000;
        while(SystemClock.elapsedRealtime()<end){
            AtomicReference<Boolean> ready=new AtomicReference<>();ui(()->ready.set((Boolean)field("ready")));
            if(ready.get()==desired)return;SystemClock.sleep(25);
        }
        throw new AssertionError("Readiness did not become "+desired);
    }
    private Button button(View view,String label){
        if(view instanceof Button && label.contentEquals(((Button)view).getText()))return (Button)view;
        if(view instanceof ViewGroup){ViewGroup group=(ViewGroup)view;for(int i=0;i<group.getChildCount();i++){Button found=button(group.getChildAt(i),label);if(found!=null)return found;}}
        return null;
    }
    private void retry()throws Exception{
        ui(()->{Button retry=button((View)field("startup"),"重新打开");check(retry!=null,"Retry button missing");retry.performClick();holdPage();});
        waitFixture();
    }
    private Object bridge(WebView view,int generation)throws Exception{
        Class<?> type=activity.getClass().getClassLoader().loadClass("studio.sidea.android.MainActivity$Bridge");
        Constructor<?> constructor=type.getDeclaredConstructor(activity.getClass(),WebView.class,int.class);constructor.setAccessible(true);
        return constructor.newInstance(activity,view,generation);
    }
    private void bridgeCall(Object bridge,String name,Class<?>[] types,Object... values)throws Exception{
        Method method=bridge.getClass().getDeclaredMethod(name,types);method.setAccessible(true);method.invoke(bridge,values);
    }
    private static WebResourceRequest request(String address){return new WebResourceRequest(){
        public Uri getUrl(){return Uri.parse(address);}public boolean isForMainFrame(){return false;}
        public boolean isRedirect(){return false;}public boolean hasGesture(){return false;}public String getMethod(){return "GET";}
        public Map<String,String> getRequestHeaders(){return Collections.emptyMap();}
    };}
    private void tests()throws Exception{
        waitFixture();SystemClock.sleep(750);
        ui(()->{
            check(!(Boolean)field("ready"),"Page completion must not imply JS readiness");
            check(((View)field("startup")).getVisibility()==View.VISIBLE,"Native loading layer absent");
            check("".equals(field("lastPlayer")),"Player updates ran before UI readiness");
            WebView view=(WebView)field("web");
            for(String address:new String[]{"https://example.invalid/index.html","https://sidea.local/SideASetup.txt","https://sidea.local/../index.html","file:///android_asset/index.html"}){
                WebResourceResponse blocked=view.getWebViewClient().shouldInterceptRequest(view,request(address));
                check(blocked!=null&&blocked.getStatusCode()==403,"Local resource allowlist failed");
            }
            WebResourceResponse bootstrap=view.getWebViewClient().shouldInterceptRequest(view,request("https://sidea.local/bootstrap.js"));
            check(bootstrap.getStatusCode()==200,"Local bootstrap missing from allowlist");bootstrap.getData().close();
        });
        script("SideA.uiReady()");awaitReady(true);
        ui(()->check(((View)field("startup")).getVisibility()==View.GONE,"Successful handshake did not dismiss loading"));
        script("SideA.uiFailed('runtime')");awaitReady(true);
        ui(()->check("".equals(field("startupFailure")),"Post-ready runtime error should not hide the app"));
        AtomicReference<Object> oldBridge=new AtomicReference<>();AtomicReference<WebView> oldView=new AtomicReference<>();AtomicReference<Integer> oldGeneration=new AtomicReference<>();
        ui(()->{
            oldView.set((WebView)field("web"));oldGeneration.set((Integer)field("pageGeneration"));
            oldBridge.set(bridge(oldView.get(),oldGeneration.get()));
            boolean handled=oldView.get().getWebViewClient().onRenderProcessGone(oldView.get(),new RenderProcessGoneDetail(){
                public boolean didCrash(){return true;}public int rendererPriorityAtExit(){return WebView.RENDERER_PRIORITY_BOUND;}
            });
            check(handled&&field("web")==null&&"renderer".equals(field("startupFailure")),"Renderer failure was not isolated");
        });
        retry();
        ui(()->{
            check(field("web")!=oldView.get(),"Retry reused a failed WebView");
            check((Integer)field("pageGeneration")>oldGeneration.get(),"Retry did not advance generation");
        });
        bridgeCall(oldBridge.get(),"uiReady",new Class<?>[]{});
        bridgeCall(oldBridge.get(),"uiFailed",new Class<?>[]{String.class},"runtime");waitForIdleSync();
        ui(()->{check(!(Boolean)field("ready"),"Stale ready signal reached replacement view");check("".equals(field("startupFailure")),"Stale failure reached replacement view");});
        script("SideA.uiFailed('https://invalid.example/?token=QA_DO_NOT_EXPOSE')");
        ui(()->{
            check("script".equals(field("startupFailure")),"Untrusted JS failure was not normalized");
            String info=(String)invoke("compatibilityInfo",new Class<?>[]{});
            check(info.contains("Android ")&&info.contains("WebView "),"Compatibility versions missing");
            check(!info.contains("QA_DO_NOT_EXPOSE")&&!info.contains("https://"),"Diagnostics exposed JS input");
        });
        retry();
        ui(()->{
            ((Runnable)field("startupTimeout")).run();
            check("timeout".equals(field("startupFailure")),"Silent bootstrap failure has no recovery");
            check(button((View)field("startup"),"重新打开")!=null,"Timeout retry missing");
        });
        retry();script("SideA.uiReady()");awaitReady(true);
        ui(()->{((Runnable)field("startupTimeout")).run();check((Boolean)field("ready"),"Expired timeout hid a ready interface");});
        result.putString("startup","handshake, allowlist, renderer failure, timeout, retry, stale callbacks and sanitized diagnostics passed");
    }
    @Override public void onStart(){
        try{
            verifyCleanEmulator();
            Intent launch=new Intent().setClassName(getTargetContext().getPackageName(),"studio.sidea.android.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivitySync(launch);
            if(setupFailure!=null)throw new Exception("Local fixture setup failed",setupFailure);
            tests();result.putString("result","PASS");finish(Activity.RESULT_OK,result);
        }catch(Throwable failure){result.putString("result","FAIL: "+failure.getClass().getSimpleName()+": "+failure.getMessage());finish(Activity.RESULT_CANCELED,result);}
        finally{if(activity!=null)runOnMainSync(()->activity.finish());}
    }
}
