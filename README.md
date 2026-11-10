# Syllume

Syllume 是 iPhone 上的音樂播放器，支援 iOS 17 以上，介面使用臺灣繁體中文。可播放本機和 Navidrome 音訊、匯入同步歌詞，並將 YouTube 歌單和喜歡的影片同步至曲庫。

## 原版電腦 Folia

Syllume 是由 Fringetw 維護的非官方 iOS 移植。商籟（Sonnet）和繪光（Lumiere）歌詞動畫移植自 **chthollyphile 的 Folia Major**。如果要在 Windows、macOS 或 Linux 使用原版，請到原作者的發布頁下載。

- [電腦版 Folia 原始專案](https://github.com/chthollyphile/folia-major)
- [電腦版 Folia 下載與版本紀錄](https://github.com/chthollyphile/folia-major/releases)

## Syllume for iPhone

- 在 YouTube 歌單、迷你播放器和播放頁查看歌曲封面。曾載入的封面會在本機暫存，網路中斷時仍可使用快取。
- 用本機或有權使用的來源播放配對歌曲。找不到可用音源時，可在 Syllume 開啟可見的 YouTube 官方播放器，或在 YouTube Music 開啟原曲。
- 播放本機與 Navidrome 音訊，支援鎖定畫面控制與背景播放。
- 使用商籟、繪光、歌詞清單或封面視圖。可匯入 LRC、Enhanced LRC 和原版 Folia 的 `.fia`。
- 內建 [OpenCC 繁體字幕](https://github.com/Fringetw/folia-traditional-chinese)。可離線簡轉繁、尋找同步歌詞或附加字幕。
- 從「設定 → 開發者診斷」檢查音源、字幕、動畫與裝置，匯出 JSON 或文字報告。

[安裝、建置與測試](ios/README.zh-TW.md) · [GitHub Actions](https://github.com/Fringetw/Syllume/actions/workflows/syllume-ios.yml) · [Google／YouTube 維護者設定](ios/docs/Google-YouTube-maintainer.zh-TW.md)

## 原始碼與授權

本專案依 [GNU AGPL v3](LICENSE) 提供。原作者署名、動畫移植來源與各元件授權見 [動畫引擎](ios/Visualizer/README.md) 和 [繁體字幕引擎](ios/SubtitleEngine/README.md)。
