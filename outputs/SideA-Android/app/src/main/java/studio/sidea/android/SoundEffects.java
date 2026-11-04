package studio.sidea.android;

/** Session-owned controller. All calls run on the playback owner thread. */
final class SoundEffects {
    interface EqualizerHandle {
        int bands(); int minimum(); int maximum(); double frequency(int band);
        void level(int band,int millibels); int level(int band);
        boolean hasControl(); boolean enabled(); boolean enable(); void close();
    }
    interface SpatialHandle {
        boolean hasControl(); boolean enabled(); boolean processing(); String engine(); void close();
    }
    interface Aux { void attach(int effect); void send(float level); }
    interface Factory {
        EqualizerHandle open(int session);
        default SpatialHandle spatial(int session,String preset,Aux aux){throw new UnsupportedOperationException();}
    }
    interface Volume { void set(float gain); }
    private final Factory factory;
    private EqualizerHandle equalizer;
    private SpatialHandle spatial;
    private Volume output;
    private Aux aux;
    private int session,settling;
    private float volume=1;
    private String preset=SoundPreset.ORIGINAL,status="off";
    SoundEffects(Factory factory){this.factory=factory;}
    String preset(){return preset;}
    String status(){return status;}
    String engine(){return !"active".equals(status)?"":spatial==null?"equalizer":spatial.engine();}
    void select(String id){
        String next=SoundPreset.normalize(id);
        if(!next.equals(preset)){closeSpatial();preset=next;}
        apply();
    }
    void attach(int id,Volume target){attach(id,target,null);}
    void attach(int id,Volume target,Aux auxiliary){
        detach();session=id;output=target;aux=auxiliary;apply();
    }
    void detach(){
        closeSpatial();closeEqualizer();try{setVolume(1);}catch(RuntimeException ignored){}
        output=null;aux=null;session=0;settling=0;
        status=SoundPreset.ORIGINAL.equals(preset)?"off":"pending";
    }
    /** Seeking discards the old room tail; the dry player continues unchanged. */
    void reset(){if(spatial!=null){closeSpatial();apply();}}
    private void closeSpatial(){
        SpatialHandle old=spatial;spatial=null;settling=0;
        if(old!=null)try{old.close();}catch(RuntimeException ignored){}
    }
    private void closeEqualizer(){
        EqualizerHandle old=equalizer;equalizer=null;
        if(old!=null)try{old.close();}catch(RuntimeException ignored){}
    }
    private void setVolume(float gain){if(output!=null)output.set(gain);volume=gain;}
    private void unavailable(){
        closeSpatial();closeEqualizer();try{setVolume(1);}catch(RuntimeException ignored){}
        status="unavailable";
    }
    private void apply(){
        if(SoundPreset.ORIGINAL.equals(preset)){
            closeSpatial();closeEqualizer();try{setVolume(1);}catch(RuntimeException ignored){}
            status="off";return;
        }
        if(output==null||session<=0){status="pending";return;}
        try{
            float target=SoundPreset.volume(preset);setVolume(Math.min(volume,target));
            if(SoundPreset.spatial(preset)){
                closeEqualizer();
                if(spatial==null){spatial=factory.spatial(session,preset,aux);settling=3;}
                if(!spatial.hasControl()||!spatial.enabled())throw new IllegalStateException("Spatial effect not enabled");
                status=spatial.processing()?"active":"pending";
            }else{
                closeSpatial();
                if(equalizer==null)equalizer=factory.open(session);
                if(!equalizer.hasControl())throw new IllegalStateException("No audio effect control");
                int count=equalizer.bands(),low=equalizer.minimum(),high=equalizer.maximum();
                if(count<2||count>128||low>=high||low>0||high<0)throw new IllegalStateException("Unsupported equalizer");
                for(int i=0;i<count;i++){
                    int value=SoundPreset.level(preset,equalizer.frequency(i),low,high);
                    equalizer.level(i,value);
                    if(Math.abs(equalizer.level(i)-value)>50)throw new IllegalStateException("Equalizer did not accept curve");
                }
                if(!equalizer.enable()||!equalizer.enabled())throw new IllegalStateException("Equalizer could not start");
                status="active";
            }
            setVolume(target);
        }catch(RuntimeException error){unavailable();}
    }
    /** Recheck actual virtualization route as well as ownership; enabled alone is insufficient. */
    boolean check(){
        if(!"active".equals(status)&&!("pending".equals(status)&&spatial!=null))return false;
        String before=status;
        try{
            if(spatial!=null&&spatial.hasControl()&&spatial.enabled()){
                if(spatial.processing()){status="active";settling=0;return !status.equals(before);}
                if("pending".equals(status)&&--settling>0)return false;
            }else if(spatial==null&&equalizer!=null&&equalizer.hasControl()&&equalizer.enabled())return false;
        }catch(RuntimeException ignored){}
        unavailable();return true;
    }
}
