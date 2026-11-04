package studio.sidea.android;

/** Original tuning targets; spatial presets require a real spatial/reverb processor. */
final class SoundPreset {
    static final String ORIGINAL="original";
    static final String[] IDS={ORIGINAL,"surround","hall","vocal","studio","bass","soft"};
    static final String[] NAMES={"原声","立体环绕","音乐厅","清澈人声","录音棚","低音增强","柔和聆听"};
    static final String[] DETAILS={"保持原有音色","立体声扩展","自然厅堂混响","清晰自然的歌声","短房间反射","饱满而克制的低频","柔和耐听"};
    private static final double[] HZ={63,250,1000,4000,16000};
    private static final double[][] DB={{0,0,0,0,0},{0,0,0,0,0},{0,0,0,0,0},{-2,-1,2,3,0},{0,0,0,0,0},{4,2,0,-1,-1},{1,0,0,-1,-3}};
    static String normalize(String id){
        if("commute".equals(id))return "vocal";
        if("night".equals(id))return "soft";
        for(String value:IDS)if(value.equals(id))return value;return ORIGINAL;
    }
    static boolean spatial(String id){return "surround".equals(id)||"hall".equals(id)||"studio".equals(id);}
    static int index(String id){String safe=normalize(id);for(int i=0;i<IDS.length;i++)if(IDS[i].equals(safe))return i;return 0;}
    static int level(String id,double frequencyHz,int minimum,int maximum){
        if(minimum>maximum||!Double.isFinite(frequencyHz)||frequencyHz<=0)throw new IllegalArgumentException("Invalid equalizer band");
        double[] db=DB[index(id)];double gain=db[0];
        if(frequencyHz>=HZ[HZ.length-1])gain=db[db.length-1];
        else for(int i=1;i<HZ.length;i++)if(frequencyHz<=HZ[i]){
            double mix=Math.max(0,Math.log(frequencyHz/HZ[i-1])/Math.log(HZ[i]/HZ[i-1]));
            gain=db[i-1]+mix*(db[i]-db[i-1]);break;
        }
        return Math.max(minimum,Math.min(maximum,(int)Math.round(gain*100)));
    }
    static float volume(String id){
        String safe=normalize(id);
        if(ORIGINAL.equals(safe))return 1f;
        if(spatial(safe))return "surround".equals(safe)?0.8f:0.7f;
        double peak=0;for(double db:DB[index(safe)])peak=Math.max(peak,db);
        return (float)Math.pow(10,-(peak+2)/20);
    }
    private SoundPreset(){}
}
