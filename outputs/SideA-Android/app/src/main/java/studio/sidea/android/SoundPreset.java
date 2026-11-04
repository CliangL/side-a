package studio.sidea.android;

/** Original tuning curves, in dB at logarithmically spaced frequency anchors. */
final class SoundPreset {
    static final String ORIGINAL="original";
    static final String[] IDS={ORIGINAL,"vocal","bass","soft","commute","night"};
    static final String[] NAMES={"原声","人声","低音","舒缓","通勤","夜间"};
    static final String[] DETAILS={"保持原有音色","突出歌声与对白","低频更有厚度","柔和高频，轻松听歌","减轻低频轰鸣，突出旋律","收敛低频与高频，柔和聆听"};
    private static final double[] HZ={63,250,1000,4000,16000};
    private static final double[][] DB={
        {0,0,0,0,0},{-2,-1,2,3,0},{4,2,0,-1,-1},
        {1,0,0,-1,-3},{-2,0,2,2,0},{-4,-2,0,-1,-4}
    };
    static String normalize(String id){for(String value:IDS)if(value.equals(id))return value;return ORIGINAL;}
    static int index(String id){String safe=normalize(id);for(int i=0;i<IDS.length;i++)if(IDS[i].equals(safe))return i;return 0;}
    static int level(String id,double frequencyHz,int minimum,int maximum){
        if(minimum>maximum||!Double.isFinite(frequencyHz)||frequencyHz<=0)throw new IllegalArgumentException("Invalid equalizer band");
        double[] db=DB[index(id)];double gain=db[0];
        if(frequencyHz>=HZ[HZ.length-1])gain=db[db.length-1];
        else for(int i=1;i<HZ.length;i++)if(frequencyHz<=HZ[i]){
            double mix=Math.max(0,Math.log(frequencyHz/HZ[i-1])/Math.log(HZ[i]/HZ[i-1]));
            gain=db[i-1]+mix*(db[i]-db[i-1]);break;
        }
        // Android Equalizer uses millibels: 100 mB = 1 dB.
        return Math.max(minimum,Math.min(maximum,(int)Math.round(gain*100)));
    }
    static float volume(String id){
        if(ORIGINAL.equals(normalize(id)))return 1f;
        double peak=0;for(double db:DB[index(id)])peak=Math.max(peak,db);
        // Leave two extra dB of headroom; this is not a loudness boost or a compressor.
        return (float)Math.pow(10,-(peak+2)/20);
    }
    private SoundPreset(){}
}
