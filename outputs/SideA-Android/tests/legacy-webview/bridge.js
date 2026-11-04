(function () {
  var song = {
    source: "netease",
    trackID: "1320101152",
    title: "海浪",
    artist: "deca joins",
    album: "Go Slow",
  };
  var song2 = {
    source: "netease",
    trackID: "438462713",
    title: "My Jinji",
    artist: "落日飞车",
    album: "Jinji Kikko",
  };
  var library = {
    favorites: [song],
    recent: [song],
    playlists: [{ id: "qa", name: "在路上", tracks: [song, song2] }],
    trackingEnabled: true,
    revision: 1,
  };
  var settings = {
    centralBase: "https://qa.invalid",
    searchSource: "all",
    allSources: ["qq", "wy", "kw", "jx"],
    cacheBytes: 1024,
    soundPreset: "original",
    soundPresets: [
      { id: "original", name: "原声" },
      { id: "surround", name: "立体环绕" },
      { id: "hall", name: "音乐厅" },
      { id: "vocal", name: "清澈人声" },
      { id: "studio", name: "录音棚" },
      { id: "bass", name: "低音增强" },
      { id: "soft", name: "柔和聆听" },
    ],
  };
  var player = {
    queue: [song, song2],
    index: 0,
    track: song,
    playing: false,
    loading: false,
    elapsed: 43,
    duration: 234,
    mode: "sequence",
    quality: "无损 · FLAC",
    sound: { preset: "original", status: "off" },
  };
  var calls = [];
  window.__qa = { calls: calls, player: player };
  window.SideA = {
    uiReady: function () {
      window.__qa.ready = true;
    },
    uiFailed: function (kind) {
      window.__qa.failed = kind;
    },
    request: function (id, action, json) {
      var p = JSON.parse(json || "{}");
      calls.push({ action: action, payload: p });
      setTimeout(function () {
        try {
          var value;
          switch (action) {
            case "init":
              value = {
                uiMode: location.pathname.indexOf("/phone/") === 0 ? "phone" : "car",
                library: library,
                settings: settings,
                starter: [song, song2],
                player: player,
              };
              break;
            case "player":
              value = player;
              break;
            case "library":
              value = library;
              break;
            case "recommend":
            case "related":
              value = [song, song2];
              break;
            case "discover":
              value = { hot: [song2, song], newReleases: [song, song2] };
              break;
            case "sysBars":
            case "ready":
            case "uiReady":
            case "bootReady":
            case "uiError":
            case "bootError":
              value = {};
              break;
            case "settings":
              if (p.op === "set") Object.assign(settings, p);
              value = settings;
              break;
            case "prepareSearch":
              value = settings;
              break;
            case "searchPage":
              value = { items: [song, song2].map(function(t){return Object.assign({},t,{source:"central",centralCatalog:true,trackID:p.searchSource+"."+t.trackID,apiEndpoint:"https://qa.invalid/v1/music"});}), bySource: [{ ok: true }] };
              break;
            case "searchRank":
            case "searchEvidence":
              value = p.tracks;
              break;
            case "lyrics":
              value = Array.from({ length: 12 }, function (_, i) {
                return { time: i * 10, text: "测试歌词 " + (i + 1) };
              });
              break;
            case "sound":
              settings.soundPreset = p.preset;
              player.sound = { preset: p.preset, status: "active" };
              value = player;
              break;
            case "playAction":
              if (p.op === "toggle") player.playing = !player.playing;
              if (p.op === "next") {
                player.index = 1 - player.index;
                player.track = player.queue[player.index];
              }
              if (p.op === "seek") player.elapsed = p.seconds;
              if (p.op === "mode") player.mode = p.mode;
              value = player;
              break;
            case "libraryAction":
              if (p.op === "favorite") {
                library.favorites = library.favorites.length ? [] : [p.track];
                library.revision++;
              }
              value = library;
              break;
            case "cover":
              value = "";
              break;
            default:
              value = {};
          }
          window.sideAReply(id, true, value);
        } catch (e) {
          window.sideAReply(id, false, e.message);
        }
      }, 0);
    },
  };
})();
