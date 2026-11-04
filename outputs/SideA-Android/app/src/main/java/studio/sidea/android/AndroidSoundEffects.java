package studio.sidea.android;

import android.media.audiofx.AudioEffect;
import android.media.audiofx.Equalizer;
import android.media.audiofx.Virtualizer;
import android.media.audiofx.EnvironmentalReverb;
import android.media.audiofx.PresetReverb;
import org.json.JSONArray;
import org.json.JSONObject;
import static studio.sidea.android.Json.*;

/** Public system APIs only. Insert effects use our player session; reverb uses an explicit auxiliary send. */
final class AndroidSoundEffects {
    private static final int PRIORITY=Integer.MIN_VALUE;
    static SoundEffects create(){return new SoundEffects(new SoundEffects.Factory(){
        public SoundEffects.EqualizerHandle open(int session){
            if(session<=0)throw new IllegalArgumentException("A player session is required");
            Equalizer effect=new Equalizer(0,session);
            return new SoundEffects.EqualizerHandle(){
                public int bands(){return effect.getNumberOfBands();}
                public int minimum(){return effect.getBandLevelRange()[0];}
                public int maximum(){return effect.getBandLevelRange()[1];}
                public double frequency(int i){return effect.getCenterFreq((short)i)/1000d;}
                public void level(int i,int value){effect.setBandLevel((short)i,(short)value);}
                public int level(int i){return effect.getBandLevel((short)i);}
                public boolean hasControl(){return effect.hasControl();}
                public boolean enabled(){return effect.getEnabled();}
                public boolean enable(){return effect.setEnabled(true)==AudioEffect.SUCCESS;}
                public void close(){effect.release();}
            };
        }
        public SoundEffects.SpatialHandle spatial(int session,String preset,SoundEffects.Aux aux){
            if(session<=0)throw new IllegalArgumentException("A player session is required");
            if("surround".equals(preset))return virtualizer(session);
            if(aux==null)throw new UnsupportedOperationException("Player has no auxiliary send");
            try{return room(preset,aux);}catch(RuntimeException unavailable){return presetRoom(preset,aux);}
        }
    });}
    private static void own(AudioEffect effect){
        if(!effect.hasControl())throw new UnsupportedOperationException("Effect owned by another client");
    }
    private static void enable(AudioEffect effect){
        own(effect);
        if(effect.setEnabled(true)!=AudioEffect.SUCCESS||!effect.getEnabled())throw new UnsupportedOperationException("Effect unavailable");
    }
    @SuppressWarnings("deprecation")
    private static SoundEffects.SpatialHandle virtualizer(int session){
        Virtualizer effect=new Virtualizer(PRIORITY,session);
        try{
            own(effect);
            if(!AudioEffect.EFFECT_INSERT.equals(effect.getDescriptor().connectMode))throw new UnsupportedOperationException("Not an insert virtualizer");
            if(effect.getStrengthSupported()){
                own(effect);effect.setStrength((short)450);
                if(effect.getRoundedStrength()<=0)throw new UnsupportedOperationException("Virtualization ignored");
            }
            enable(effect);
            return new SoundEffects.SpatialHandle(){
                public boolean hasControl(){return effect.hasControl();}
                public boolean enabled(){return effect.getEnabled();}
                public boolean processing(){return effect.getVirtualizationMode()!=Virtualizer.VIRTUALIZATION_MODE_OFF;}
                public String engine(){return "virtualizer";}
                public void close(){effect.release();}
            };
        }catch(RuntimeException error){effect.release();throw error;}
    }
    /** Auxiliary engines may be shared. Never take ownership from a normal-priority app or reconfigure an enabled engine. */
    private static void auxiliary(AudioEffect effect){
        if(!AudioEffect.EFFECT_AUXILIARY.equals(effect.getDescriptor().connectMode))throw new UnsupportedOperationException("Not auxiliary reverb");
        own(effect);
        if(effect.getEnabled())throw new UnsupportedOperationException("Reverb already in use");
    }
    private static SoundEffects.SpatialHandle room(String preset,SoundEffects.Aux aux){
        EnvironmentalReverb effect=new EnvironmentalReverb(PRIORITY,0);
        try{
            auxiliary(effect);
            boolean hall="hall".equals(preset);
            EnvironmentalReverb.Settings settings=new EnvironmentalReverb.Settings();
            settings.roomLevel=(short)(hall?-1800:-2500);settings.roomHFLevel=(short)(hall?-600:-300);
            settings.decayTime=hall?1500:350;settings.decayHFRatio=(short)(hall?650:800);
            settings.reflectionsLevel=(short)(hall?-1800:-1500);settings.reflectionsDelay=hall?15:5;
            settings.reverbLevel=(short)(hall?-900:-1800);settings.reverbDelay=hall?24:8;
            settings.diffusion=(short)(hall?900:800);settings.density=(short)(hall?850:700);
            own(effect);effect.setProperties(settings);own(effect);
            EnvironmentalReverb.Settings read=effect.getProperties();
            if(read.decayTime!=settings.decayTime||read.roomLevel!=settings.roomLevel||read.reverbLevel!=settings.reverbLevel)
                throw new UnsupportedOperationException("Room parameters ignored");
            enable(effect);return new AuxiliaryHandle(effect,aux,hall?.22f:.12f,"environmentalReverb");
        }catch(RuntimeException error){effect.release();throw error;}
    }
    private static SoundEffects.SpatialHandle presetRoom(String preset,SoundEffects.Aux aux){
        PresetReverb effect=new PresetReverb(PRIORITY,0);
        try{
            auxiliary(effect);
            boolean hall="hall".equals(preset);short value=hall?PresetReverb.PRESET_LARGEHALL:PresetReverb.PRESET_SMALLROOM;
            own(effect);effect.setPreset(value);own(effect);
            if(effect.getPreset()!=value)throw new UnsupportedOperationException("Room preset ignored");
            enable(effect);return new AuxiliaryHandle(effect,aux,hall?.18f:.10f,"presetReverb");
        }catch(RuntimeException error){effect.release();throw error;}
    }
    private static final class AuxiliaryHandle implements SoundEffects.SpatialHandle {
        private final AudioEffect effect;private final SoundEffects.Aux aux;private final String name;
        private boolean bound,closed;
        AuxiliaryHandle(AudioEffect effect,SoundEffects.Aux aux,float wet,String name){
            this.effect=effect;this.aux=aux;this.name=name;
            // AudioEffect dispatches on the creating playback-owner looper.
            try{
                own(effect);aux.attach(effect.getId());bound=true;aux.send(wet);
                effect.setControlStatusListener((e,control)->{if(!control)disconnect();});
                effect.setEnableStatusListener((e,on)->{if(!on)disconnect();});
            }catch(RuntimeException error){disconnect();throw error;}
        }
        private void disconnect(){
            if(!bound)return;bound=false;
            try{aux.send(0);}catch(RuntimeException ignored){}
            try{aux.attach(0);}catch(RuntimeException ignored){}
        }
        public boolean hasControl(){return !closed&&effect.hasControl();}
        public boolean enabled(){return !closed&&effect.getEnabled();}
        public boolean processing(){return !closed&&bound;}
        public String engine(){return name;}
        public void close(){
            if(closed)return;closed=true;disconnect();
            effect.setControlStatusListener(null);effect.setEnableStatusListener(null);
            // Do not disable a shared engine which another client may now own.
            effect.release();
        }
    }
    static JSONObject state(SoundEffects effects){return state(effects.preset(),effects.status(),effects.engine());}
    static JSONObject pending(String preset){String safe=SoundPreset.normalize(preset);return state(safe,SoundPreset.ORIGINAL.equals(safe)?"off":"pending","");}
    private static JSONObject state(String preset,String status,String engine){
        String message="active".equals(status)?"已应用":"unavailable".equals(status)?"当前设备或输出暂不支持此音效，已使用原声":"pending".equals(status)?"播放时应用":"原声播放";
        return object("preset",preset,"status",status,"engine",engine,"message",message);
    }
    static JSONArray presets(){
        JSONArray rows=new JSONArray();
        for(int i=0;i<SoundPreset.IDS.length;i++)rows.put(object("id",SoundPreset.IDS[i],"name",SoundPreset.NAMES[i],"detail",SoundPreset.DETAILS[i]));
        return rows;
    }
    private AndroidSoundEffects(){}
}
