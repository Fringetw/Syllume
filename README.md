# Folia for iPhone

非官方 Folia iOS 移植，最低 iOS 17，介面使用臺灣繁體中文。

0.3.5 將 YouTube 改為歌單同步來源：首次連接後選擇一份歌單（含喜歡的影片），往後自動載入最後選擇，可用「更換歌單」修改。同步歌名、歌手與長度後，自動比對本機、已連接的 Navidrome 原始音檔，以及網易雲可提供的完整音源；新配對優先無損，再比較位元率。不擷取 YouTube 音訊，也不建立 YouTube 影片播放器。

音檔使用 AVPlayer 播放，支援背景、鎖定畫面、真正暫停與商籟／繪光歌詞動畫。下載的檔案可在「檔案 → 我的 iPhone → Folia → YouTube Music」找到。自動下載無法保證涵蓋所有歌曲或全球最高音質；無可靠配對、只有試聽／會員限制、地區或網路限制時顯示缺檔，可手動附加完整音檔。

隨 App 內建 [OpenCC 繁體字幕 1.1.6](https://github.com/Fringetw/folia-traditional-chinese)，保留離線簡轉繁、網易雲／QQ／YouTube 字幕搜尋、自動補譯與備援、還原及完整診斷。從「設定 → 繁體字幕」調整，從播放頁「尋找歌詞」搜尋；可停用，不能刪除。Spotify 目前仍為曲庫與外部播放入口。

- [功能、建置與驗證](ios/README.zh-TW.md)
- [Google／YouTube 維護者設定](ios/docs/Google-YouTube-maintainer.zh-TW.md)
- [動畫原始碼與重建方式](ios/Visualizer/README.md)
- [內建繁體字幕功能與來源對照](ios/SubtitleEngine/README.md)

動畫引擎與原始專案來自 [chthollyphile/folia-major](https://github.com/chthollyphile/folia-major)。原始碼依 [GNU AGPL v3](LICENSE) 提供。
