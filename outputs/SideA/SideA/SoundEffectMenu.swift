import SwiftUI

/// Native menu content shared by the player and settings, matching the quality selector.
struct SoundEffectChoices: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        Picker("音效", selection: $player.soundPreset) {
            ForEach(SoundPreset.allCases) { preset in
                Text(preset.title)
                    .tag(preset)
                    .accessibilityIdentifier("sound." + preset.rawValue)
            }
        }.pickerStyle(.inline)
        if player.soundStatus.contains("不支持") || player.soundStatus.contains("原声播放") && player.soundPreset != .original {
            Text(player.soundStatus)
        }
    }
}
