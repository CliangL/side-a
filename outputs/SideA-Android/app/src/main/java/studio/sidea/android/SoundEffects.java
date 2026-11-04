package studio.sidea.android;

/** Session-owned controller. All calls run on the playback owner thread. */
final class SoundEffects {
    interface EqualizerHandle {
        int bands(); int minimum(); int maximum(); double frequency(int band);
        void level(int band,int millibels); int level(int band);
        boolean hasControl(); boolean enabled(); boolean enable(); void close();
    }
    interface Factory { EqualizerHandle open(int session); }
    interface Volume { void set(float gain); }
    private final Factory factory;
    private EqualizerHandle equalizer;
    private Volume output;
    private int session;
    private float volume=1;
    private String preset=SoundPreset.ORIGINAL,status="off";
    SoundEffects(Factory factory){this.factory=factory;}
    String preset(){return preset;}
    String status(){return status;}
    String engine(){return "active".equals(status)?"equalizer":"";}
    void select(String id){preset=SoundPreset.normalize(id);apply();}
    void attach(int id,Volume target){
        detach();session=id;output=target;apply();
    }
    void detach(){
        closeEqualizer();try{setVolume(1);}catch(RuntimeException ignored){}output=null;session=0;
        status=SoundPreset.ORIGINAL.equals(preset)?"off":"pending";
    }
    private void closeEqualizer(){
        EqualizerHandle old=equalizer;equalizer=null;
        if(old!=null)try{old.close();}catch(RuntimeException ignored){}
    }
    private void setVolume(float gain){
        if(output!=null)output.set(gain);volume=gain;
    }
    private void unavailable(){
        closeEqualizer();
        try{setVolume(1);}catch(RuntimeException ignored){}
        status="unavailable";
    }
    private void apply(){
        if(SoundPreset.ORIGINAL.equals(preset)){
            closeEqualizer();try{setVolume(1);}catch(RuntimeException ignored){}
            status="off";return;
        }
        if(output==null||session<=0){status="pending";return;}
        try{
            float target=SoundPreset.volume(preset);
            setVolume(Math.min(volume,target));
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
            setVolume(target);status="active";
        }catch(RuntimeException error){unavailable();}
    }
    /** Hardware can remove control when the output route or system effects change. */
    boolean check(){
        if(!"active".equals(status))return false;
        try{if(equalizer!=null&&equalizer.hasControl()&&equalizer.enabled())return false;}catch(RuntimeException ignored){}
        unavailable();return true;
    }
}
