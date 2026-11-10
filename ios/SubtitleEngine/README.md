# iOS 內建 OpenCC 繁體字幕

來源：[Fringetw/folia-traditional-chinese](https://github.com/Fringetw/folia-traditional-chinese/tree/2405504a1d93b5ce47d334bd1de5c4748927f8bf)，版本 **1.1.6**。`provenance.json` 記錄固定提交及 Git blob 雜湊；`upstream/` 的原始檔保留原位元組與授權。

| 原插件功能 | iOS 入口與行為 |
| --- | --- |
| 啟用／停用 | 設定中的「啟用內建模組」；停用還原原字幕、取消請求並清除搜尋暫存。內建模組無刪除入口。 |
| 離線簡轉繁 | 相同 OpenCC 1.4.2 引擎及字典，臺灣／標準繁體，原文與和聲、中文翻譯分開控制。 |
| 日韓文字保護 | 相同含假名／韓文整行保護；純漢字日文仍無法可靠辨識。 |
| 動畫時間與欄位 | 整句轉換再投影回逐字、音節及分詞；保留原文、和聲、注音及多語言欄位。商籟與清單使用同一顯示結果。 |
| 自動選字幕／空白備援 | 相同 `selectChinese`、`lyricQuality` 及 `songMatch`：核對名稱、歌手、時長、版本、原詞、分行及固定時間差，只接受可證明的補譯／備援。 |
| 搜尋上限 | 相同最多 6 來源、每查詢首頁 8 首、最多 3 查詢、標準 2／深入 4 候選、2 個並行工作、7 秒請求及 40 秒整輪上限、每分鐘 60 次讀取。來源本身限制另外生效。 |
| 暫存與取消 | 相同 8 首 LRU、10 分鐘冷卻；切歌、帳號切換與停用取消等待並捨棄晚回應。 |
| 命令 | 設定內提供切換繁體、重新尋找、還原這首原字幕、來源與中文覆蓋率；iOS 以按鈕取代桌面命令面板。 |
| 診斷 | 相同報告引擎與 600 事件上限；原生頁面提供顯示開關、捲動選字、複製及 JSON 檔案匯出。 |

## iOS 歌詞來源

原插件呼叫桌面 Folia 的 Omni 來源；iOS 以原生橋接提供相同介面，不會取得桌面帳號。0.3.3 預設來源順序為網易雲、QQ 音樂、YouTube、本機、Navidrome、LRCLIB，維持原插件最多 6 來源的預算。

- **網易雲**：以表單 POST 搜尋 `music.163.com/api/cloudsearch/pc`，並讀取 `/api/song/lyric` 的 `lrc`、`tlyric`、`romalrc`；可選用已有的維護者 HTTPS `/search`、`/lyric` 服務。
- **QQ 音樂**：匿名搜尋 `client_search_cp`；以 `music.musichallSong.PlayLyricInfo/GetPlayLyricInfo` 的 `crypt=0,qrc=0,trans=1` 讀取平台 Base64 LRC 與譯文。捐出逐行字幕，不製造不存在的逐字時間；原曲已有的逐字仍由插件保留。
- **YouTube**：搜尋公開影片頁，使用 YouTube 網站「字幕」篩選參數（從連接的 Chrome 篩選選單確認），並優先檢查播放中的影片；僅解析公開頁面 JSON 與人工中文 `captionTracks`／JSON3 時間軸。排除 ASR、`tlang` 機器翻譯及外站／非 HTTPS 字幕網址。同一人工中文軌內的中日／中英雙語行會保留原詞並分離中文譯文；無法辨識的全漢字多行不猜測。若有可判斷的原語字幕軌，僅按相同時間配對，再交原插件核對原詞；目前同一影片也可使用既有原詞，在相同時間點補中文。對不上的翻譯不硬塞。無軌、驗證、登入、空回覆、地區限制均保留原字幕。燒錄在畫面的文字沒有可讀取字幕軌，不做 OCR。Google 曲庫 OAuth 不提供任意影片的字幕下載權限，參閱 [YouTube 官方限制](https://developers.google.com/youtube/data/reference/rest/v3/captions/download)。
- 本機、已連接 Navidrome 與 LRCLIB 保持可用；Navidrome 憑證只在原生鑰匙圈與原生客戶端使用。

各平台開關、上次候選／讀取結果和失敗原因在字幕設定；相同安全摘要亦附加至完整 JSON 診斷。0.3.1 設定可直接遷移，新來源預設啟用。平台公開接口不是可用性保證，桌面登入帳號與其他桌面平台來源不會自動出現在 iOS。

網路請求在原生程式執行，限制回應大小並遵守取消與 HTTP 限流。顯示引擎的 WKWebView 採用離線資源、非持久儲存及禁止網路的 CSP，不載入遠端程式碼。搜尋只變更畫面字幕，不改音訊來源或寫回歌詞檔。品質檢查不評判翻譯語意，也不進行 AI 翻譯。

## 重建與測試

原生 Xcode 建置使用已提交的 `Syllume/Resources/SyllumeSubtitles/subtitles.js`，不必安裝 Node 套件。要修改／重建引擎，使用 Node 24 與 npm：

```sh
cd ios/SubtitleEngine
npm ci
npm run build
npm test
```

`build.mjs` 僅在打包時將原插件的快取破除動態匯入轉為靜態匯入，讓 WKWebView 可離線載入；固定的上游檔案不變。原生檢查：`bash ios/Checks/run.sh`（Mac、Swift 6 與 Node 22 以上）。原生檢查另涵蓋舊設定遷移、網易雲／QQ 翻譯解碼、YouTube 人工軌篩選、配對、錯誤與網址限制。設定 `FOLIA_PROBE_SUBTITLE_SOURCES=1` 可額外讀取少量公開資料，只印數量和安全錯誤碼；來源不可用不視為離線測試失敗。內含 bundle 啟動、離線轉換、資料保留、補譯與還原、切歌取消和診斷不發請求測試。Xcode UI 測試另檢查真實 WKWebView 顯示、設定即時生效／保存與內建設定入口；測試字幕資料僅在 Debug 啟動參數下使用。

完整原插件測試可設定 `FOLIA_SOURCE_ROOT` 指向桌面 Folia 原始碼，於 `upstream/` 安裝該目錄 `package.json` 的開發依賴，再用 `vitest run --config dev/folium/openccTests.config.mjs`。本次固定宿主測試使用桌面提交 `3125d376557182e25a12c915e39099db13ba63c8`；線上來源回覆另需實機驗證。

## 授權

插件為 MIT；OpenCC 與 opencc-js 各自授權隨 App 的 `SyllumeSubtitles` 資源附帶。詳見 `upstream/LICENSE`、`upstream/CREDITS.md` 及 `upstream/mods/opencc-traditional-lyrics/vendor/`。本次移植保留原來源及作者資訊。

0.3.3 的原生回覆結構摘要只含位元組數、JSON 是否為物件、數字狀態碼與 result／songs 的型別／陣列長度；不包含任意來源字串。完整診斷的宿主版本由 App 注入，不再固定為打包引擎時的版本。Actions 的 `Folia-subtitle-source-checks` 附件在 App 編譯前提供這次原生來源探測及離線檢查結果；來源不可用的安全錯誤碼不當作平台成功。
