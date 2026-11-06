# Folia for iPhone

非官方 Folia iOS 移植，最低 iOS 17，介面使用臺灣繁體中文。

0.4.0 首次進入 YouTube 時選擇播放清單（包含喜歡的影片），之後記住最後選擇並自動同步。清單歌曲先從網易雲／QQ 音樂尋找相符的完整版，優先下載最高可取得的音質至「檔案 → 我的 iPhone → Folia → Music」，交給 Folia 原生播放器與商籟／繪光動畫。新流程不建立 YouTube 影片視窗。

平台沒有提供可下載音檔、歌曲版本無法確認或只有試聽片段時，會保留清單項目並顯示原因，不保證每首都能取得。預設只在 Wi-Fi 下載；切換清單保留既有音樂檔。同步發生於啟動、回到前景及使用期間每 5 分鐘；下載在 App 前景執行。Spotify 目前仍為曲庫與外部播放入口。

隨 App 內建 [OpenCC 繁體字幕 1.1.6](https://github.com/Fringetw/folia-traditional-chinese)，包含離線簡轉繁、自動尋找與補齊中文字幕、字幕備援、原字幕還原，以及完整診斷。預設搜尋網易雲、QQ 音樂的原詞／中文翻譯，以及 YouTube 已有的人工中文字幕軌；使用者不必填字幕 API 網址。從「設定 → 繁體字幕」調整；可停用，不提供刪除。

- [功能、建置與驗證](ios/README.zh-TW.md)
- [Google／YouTube 維護者設定](ios/docs/Google-YouTube-maintainer.zh-TW.md)
- [Sonnet 原始碼與重建方式](ios/Visualizer/README.md)
- [內建繁體字幕功能與來源對照](ios/SubtitleEngine/README.md)

動畫引擎與原始專案來自 [chthollyphile/folia-major](https://github.com/chthollyphile/folia-major)。原始碼依 [GNU AGPL v3](LICENSE) 提供。

0.3.4 修正網易雲表單搜尋、YouTube 字幕篩選及雙語藝名漏配，並讓診斷顯示實際 App 版本與不含敏感內容的回覆結構。平台限制與完整功能對照見 iOS 使用說明。

0.3.4 加入桌面繪光（Lumiere）、合併尋找歌詞／中文字幕入口、原生暫停媒體確認、動畫資源重用與省電模式、主要按鈕回饋。0.4.0 將 YouTube 入口改為清單同步與本機音樂播放；詳見 [iOS 使用說明](ios/README.zh-TW.md)。
