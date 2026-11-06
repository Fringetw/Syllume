# Folia for iPhone

非官方 Folia iOS 移植，最低 iOS 17，介面使用臺灣繁體中文。

0.3.2 隨 App 內建 [OpenCC 繁體字幕 1.1.6](https://github.com/Fringetw/folia-traditional-chinese)，包含離線簡轉繁、自動尋找與補齊中文字幕、字幕備援、原字幕還原，以及完整診斷。預設直接搜尋網易雲、QQ 音樂的原詞／中文翻譯，以及 YouTube 已有的人工中文字幕軌；使用者不必填字幕 API 網址。從「設定 → 內建模組 → OpenCC 繁體字幕」調整；可停用，不提供刪除。

沿用 0.3.0 的電腦版商籟（Sonnet）文字動畫、沉浸模式，以及 Folia 內的 YouTube 播放與同步歌詞。YouTube 官方播放器保持可見，離開播放畫面或切到背景會暫停。Spotify 目前仍為曲庫與外部播放入口。

- [功能、建置與驗證](ios/README.zh-TW.md)
- [Google／YouTube 維護者設定](ios/docs/Google-YouTube-maintainer.zh-TW.md)
- [Sonnet 原始碼與重建方式](ios/Visualizer/README.md)
- [內建繁體字幕功能與來源對照](ios/SubtitleEngine/README.md)

動畫引擎與原始專案來自 [chthollyphile/folia-major](https://github.com/chthollyphile/folia-major)。原始碼依 [GNU AGPL v3](LICENSE) 提供。
