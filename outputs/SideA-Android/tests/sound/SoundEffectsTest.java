package studio.sidea.android;

/** Runs on the host JDK; all device effects are explicit fakes, no music or accounts. */
public final class SoundEffectsTest {
    static int checks;
    static void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
    static class Handle implements SoundEffects.EqualizerHandle {
        int[] values=new int[5];boolean control=true,on=false,closed,allowEnable=true,ignoreWrites;int count=5;
        public int bands(){return count;}public int minimum(){return -1500;}public int maximum(){return 1500;}
        public double frequency(int i){return new double[]{60,230,910,3600,14000}[i];}
        public void level(int i,int value){if(!ignoreWrites)values[i]=value;}public int level(int i){return values[i];}
        public boolean hasControl(){return control;}public boolean enabled(){return on;}
        public boolean enable(){on=allowEnable;return allowEnable;}public void close(){closed=true;on=false;}
    }
    static class Fake implements SoundEffects.Factory,SoundEffects.Volume {
        int opens,lastSession,spatialOpens;float volume=1;boolean fail;Handle handle=new Handle();Spatial spatial=new Spatial();
        public SoundEffects.SpatialHandle spatial(int session,String id,SoundEffects.Aux aux){spatialOpens++;lastSession=session;if(fail)throw new UnsupportedOperationException();return spatial;}
        public SoundEffects.EqualizerHandle open(int session){opens++;lastSession=session;if(fail)throw new UnsupportedOperationException();return handle;}
        public void set(float value){volume=value;}
    }
    static class Spatial implements SoundEffects.SpatialHandle {
        boolean control=true,on=true,processing=true,closed;
        public boolean hasControl(){return control;}public boolean enabled(){return on;}public boolean processing(){return processing;}
        public String engine(){return "test-spatial";}public void close(){closed=true;}
    }
    public static void main(String[] args){
        check(SoundPreset.normalize("unknown").equals("original"),"unknown preset must be original");
        check(SoundPreset.normalize(null).equals("original"),"null preset must be original");
        check(SoundPreset.level("bass",63,-1500,1500)==400,"dB/mB conversion");
        check(SoundPreset.level("bass",63,-100,100)==100,"device range clamp");
        check(SoundPreset.level("bass",Math.sqrt(63*250),-1500,1500)==300,"log-frequency interpolation");
        check(SoundPreset.volume("original")==1,"bypass gain must be unity");
        for(String id:SoundPreset.IDS)check(SoundPreset.volume(id)>0&&SoundPreset.volume(id)<=1,"gain must not amplify");
        Fake f=new Fake();SoundEffects effects=new SoundEffects(f);
        effects.attach(22,f);check(effects.status().equals("off")&&f.opens==0&&f.volume==1,"original must allocate no effect");
        effects.select("bass");check(effects.status().equals("active")&&f.opens==1&&f.lastSession==22&&f.volume<0.51f,"session EQ and headroom must apply");
        check(f.handle.values[0]>f.handle.values[4],"bass curve must reach effect bands");
        effects.select("vocal");check(f.opens==1&&f.handle.values[3]>f.handle.values[0],"switch must reuse owned session and change bands");
        effects.select("original");check(f.handle.closed&&f.volume==1&&effects.status().equals("off"),"bypass must release effect and restore volume");
        effects.detach();effects.select("night");check(effects.status().equals("pending"),"idle selection waits for player");
        f.handle=new Handle();effects.attach(23,f);check(effects.status().equals("active")&&f.lastSession==23,"new song session must receive preset");
        effects.detach();check(f.handle.closed&&effects.status().equals("pending")&&f.volume==1,"pause/release must close effect");
        f.handle=new Handle();effects.attach(0,f);check(effects.status().equals("pending")&&f.lastSession==23,"never attach global session zero");
        f.fail=true;effects.attach(24,f);check(effects.status().equals("unavailable")&&f.volume==1,"unsupported effect preserves original playback");
        f.fail=false;f.handle=new Handle();effects.attach(25,f);f.handle.control=false;
        check(effects.check()&&effects.status().equals("unavailable")&&f.handle.closed&&f.volume==1,"control loss must be honest and release");
        f.handle=new Handle();effects.select("commute");check(effects.status().equals("active"),"explicit selection can retry after hardware change");
        effects.detach();f.handle=new Handle();f.handle.allowEnable=false;effects.attach(26,f);
        check(effects.status().equals("unavailable")&&f.handle.closed&&f.volume==1,"failed enable is not success");
        effects.detach();f.handle=new Handle();f.handle.ignoreWrites=true;effects.attach(27,f);
        check(effects.status().equals("unavailable")&&f.handle.closed&&f.volume==1,"ignored parameters are not success");
        effects.detach();f.handle=new Handle();f.handle.count=0;effects.attach(28,f);
        check(effects.status().equals("unavailable")&&f.volume==1,"invalid bands must fall back");
        effects.attach(29,gain->{throw new IllegalStateException();});effects.detach();
        check(effects.status().equals("pending"),"failed volume access must not crash service cleanup");
        check(SoundPreset.normalize("commute").equals("vocal")&&SoundPreset.normalize("night").equals("soft"),"legacy preferences migrate");
        f=new Fake();effects=new SoundEffects(f);effects.select("hall");effects.attach(31,f);
        check(effects.status().equals("active")&&f.opens==0&&f.spatialOpens==1&&effects.engine().equals("test-spatial"),"hall requires real spatial processor, not EQ");
        Spatial old=f.spatial;f.spatial=new Spatial();effects.select("studio");
        check(old.closed&&f.spatialOpens==2&&effects.status().equals("active"),"switching rooms releases former tail");
        old=f.spatial;f.spatial=new Spatial();effects.reset();
        check(old.closed&&f.spatialOpens==3,"seek clears spatial tail");
        effects.select("original");check(f.spatial.closed&&f.volume==1&&effects.status().equals("off"),"original removes wet effect");
        f.spatial=new Spatial();f.spatial.processing=false;effects.select("surround");
        check(effects.status().equals("pending"),"enabled virtualizer alone is not active");
        effects.check();f.spatial.processing=true;
        check(effects.check()&&effects.status().equals("active"),"route activation confirms processing");
        f.spatial.processing=false;check(effects.check()&&effects.status().equals("unavailable")&&f.volume==1,"unsupported output route bypasses");
        f.spatial=new Spatial();f.spatial.processing=false;effects.select("surround");effects.check();effects.check();effects.check();
        check(effects.status().equals("unavailable")&&f.spatial.closed,"unsupported route cannot remain pending forever");
        f.spatial=new Spatial();effects.select("hall");f.spatial.control=false;effects.check();
        check(f.spatial.closed&&effects.status().equals("unavailable"),"shared effect control loss disconnects own player");
        f.spatial=new Spatial();effects.select("hall");effects.detach();
        check(f.spatial.closed&&effects.status().equals("pending"),"pause discards spatial handle");
        f.fail=true;effects.attach(32,f);check(effects.status().equals("unavailable")&&f.volume==1,"missing room processor does not claim success");
        System.out.println(checks+" sound assertions passed");
    }
}
