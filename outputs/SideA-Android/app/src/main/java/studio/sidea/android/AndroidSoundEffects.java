package studio.sidea.android;

import android.media.audiofx.AudioEffect;
import android.media.audiofx.Equalizer;
import org.json.JSONArray;
import org.json.JSONObject;
import static studio.sidea.android.Json.*;

/** No global output mix, root permission, capture, or external effect app. */
final class AndroidSoundEffects {
    static SoundEffects create(){return new SoundEffects(session->{
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
    });}
    static JSONObject state(SoundEffects effects){return state(effects.preset(),effects.status(),effects.engine());}
    static JSONObject pending(String preset){String safe=SoundPreset.normalize(preset);return state(safe,SoundPreset.ORIGINAL.equals(safe)?"off":"pending","");}
    private static JSONObject state(String preset,String status,String engine){
        String message="active".equals(status)?"已应用":"unavailable".equals(status)?"此设备暂未启用音效，使用原声播放":"pending".equals(status)?"播放时应用":"原声播放";
        return object("preset",preset,"status",status,"engine",engine,"message",message);
    }
    static JSONArray presets(){
        JSONArray rows=new JSONArray();
        for(int i=0;i<SoundPreset.IDS.length;i++)rows.put(object("id",SoundPreset.IDS[i],"name",SoundPreset.NAMES[i],"detail",SoundPreset.DETAILS[i]));
        return rows;
    }
    private AndroidSoundEffects(){}
}
