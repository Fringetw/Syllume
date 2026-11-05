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

原插件呼叫桌面 Folia 的 Omni 來源；iOS 以原生橋接提供相同介面，不會取得桌面帳號。預設公開來源為 LRCLIB，本機及已連接的 Navidrome 也可捐出原詞／中文。Navidrome 沿用鑰匙圈帳號；引擎與報告都收不到憑證。可選填管理者部署、與桌面版相容的網易雲 API HTTPS 位址，使用 `/search?keywords=...&type=1&limit=8` 與 `/lyric?id=...`；未設定時不連線。iOS 尚未具備桌面所有平台的登入／來源，因此不能保證兩端得到相同搜尋結果。

網路請求在原生程式執行，限制回應大小並遵守取消與 HTTP 限流。顯示引擎的 WKWebView 採用離線資源、非持久儲存及禁止網路的 CSP，不載入遠端程式碼。搜尋只變更畫面字幕，不改音訊來源或寫回歌詞檔。品質檢查不評判翻譯語意，也不進行 AI 翻譯。

## 重建與測試

原生 Xcode 建置使用已提交的 `Folia/Resources/FoliaSubtitles/subtitles.js`，不必安裝 Node 套件。要修改／重建引擎，使用 Node 24 與 npm：

```sh
cd ios/SubtitleEngine
npm ci
npm run build
npm test
```

`build.mjs` 僅在打包時將原插件的快取破除動態匯入轉為靜態匯入，讓 WKWebView 可離線載入；固定的上游檔案不變。原生檢查：`bash ios/Checks/run.sh`（Mac、Swift 6 與 Node 22 以上）。內含 bundle 啟動、離線轉換、資料保留、補譯與還原、切歌取消和診斷不發請求測試。Xcode UI 測試另檢查真實 WKWebView 顯示、設定即時生效／保存與內建設定入口；測試字幕資料僅在 Debug 啟動參數下使用。

完整原插件測試可設定 `FOLIA_SOURCE_ROOT` 指向桌面 Folia 原始碼，於 `upstream/` 安裝該目錄 `package.json` 的開發依賴，再用 `vitest run --config dev/folium/openccTests.config.mjs`。本次固定宿主測試使用桌面提交 `3125d376557182e25a12c915e39099db13ba63c8`；線上來源回覆另需實機驗證。

## 授權

插件為 MIT；OpenCC 與 opencc-js 各自授權隨 App 的 `FoliaSubtitles` 資源附帶。詳見 `upstream/LICENSE`、`upstream/CREDITS.md` 及 `upstream/mods/opencc-traditional-lyrics/vendor/`。本次移植保留原來源及作者資訊。
