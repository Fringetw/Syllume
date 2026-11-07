# Folia for iPhone

非官方 Folia iOS 移植，最低 iOS 17，介面使用臺灣繁體中文。

0.3.6 將選取的 YouTube 歌單保存為可編輯的 Folia 清單，點歌時比對可播放音訊、下載須先確認。包含整頁繪光、依音訊時鐘同步的歌詞、翻譯影片字幕讀取與畫面辨識，以及可讀的字幕診斷。詳細用法見 [繁體中文說明](ios/README.zh-TW.md)。

音檔使用 AVPlayer 播放，支援背景、鎖定畫面、真正暫停與商籟／繪光歌詞動畫。下載的檔案可在「檔案 → 我的 iPhone → Folia → YouTube Music」找到。自動下載無法保證涵蓋所有歌曲或全球最高音質；無可靠配對、只有試聽／會員限制、地區或網路限制時顯示缺檔，可手動附加完整音檔。

隨 App 內建 [OpenCC 繁體字幕 1.1.6](https://github.com/Fringetw/folia-traditional-chinese)，保留離線簡轉繁、網易雲／QQ／YouTube 字幕搜尋、自動補譯與備援、還原及完整診斷。從「設定 → 繁體字幕」調整，從播放頁「尋找歌詞」搜尋；可停用，不能刪除。Spotify 目前仍為曲庫與外部播放入口。

- [功能、建置與驗證](ios/README.zh-TW.md)
- [Google／YouTube 維護者設定](ios/docs/Google-YouTube-maintainer.zh-TW.md)
- [動畫原始碼與重建方式](ios/Visualizer/README.md)
- [內建繁體字幕功能與來源對照](ios/SubtitleEngine/README.md)

動畫引擎與原始專案來自 [chthollyphile/folia-major](https://github.com/chthollyphile/folia-major)。原始碼依 [GNU AGPL v3](LICENSE) 提供。
