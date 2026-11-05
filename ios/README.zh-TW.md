# Folia iOS 0.3.0

以 [Folia Major](https://github.com/chthollyphile/folia-major/tree/3125d376557182e25a12c915e39099db13ba63c8) 為基礎的非官方 iPhone 移植。介面使用 SwiftUI，播放使用 AVFoundation，鎖定畫面與控制中心使用 MediaPlayer。iPhone 最低系統版本為 iOS 17。原生 Xcode 專案無須下載額外套件；Sonnet 的 JavaScript 與依賴已隨 App 離線打包。這版介面提供臺灣繁體中文。

## 第一版功能

- 從「檔案」匯入 iOS 可播放的音檔，例如 MP3、AAC、M4A、WAV，儲存於 App 的本機曲庫。
- 使用播放佇列、上一首、下一首、循環和拖曳進度。音訊工作階段配置背景播放，並接上鎖定畫面和控制中心的播放指令。
- 顯示 LRC、逐字 Enhanced LRC、Folia 匯出的 `.fia`。也會讀取系統能辨識的內嵌 LRC。從「檔案」選取同名音檔和歌詞可一起匯入，也可長按曲庫中的歌曲附加歌詞。點選歌詞可跳到對應時間。
- 以自己的 HTTPS Navidrome 伺服器搜尋與串流，讀取封面和伺服器提供的同步歌詞。伺服器使用有效且受信任的 TLS 憑證。帳號資訊與密碼存於 iPhone 的鑰匙圈。
- 內建 30 秒「潮汐之間」示範音軌與歌詞，可離線試用。

0.1.0 採用原生歌詞清單；0.3.0 開始直接使用桌面版 Sonnet 引擎。其他桌面動畫樣式與 Folium 插件尚未移植。

## 0.3.0：商籟與 App 內播放

- 播放頁預設使用真正的電腦版 Sonnet 引擎，包括文字拆分、構圖、鏡頭移動與轉場；不是原先只有捲動的歌詞清單。可切換「商籟／歌詞／封面」，按取景框進入沉浸模式。
- YouTube 歌單、喜歡影片的播放按鈕改為 Folia 內的官方播放器。也能在 YouTube 頁直接貼上單支 YouTube／YouTube Music 連結，無須先登入即可播放允許嵌入的公開影片。
- 播放器的實際時間驅動 Sonnet；處理暫停、緩衝、拖曳、舊頁面回應與切歌，切換本機播放時停止 YouTube，避免同時出聲。
- 依歌曲名稱、歌手與時長向 LRCLIB 自動匹配同步歌詞。不相符時不套用；可從播放選項手動搜尋版本或附加 LRC／FIA。手動附加的歌詞按影片 ID 保存在裝置上，來源標記為 LRCLIB 或手動附加。
- YouTube 官方影片區保持可見且至少 200 × 200；不提供分離音訊、隱藏影片或鎖定螢幕的 YouTube 背景播放。離開畫面、開啟歌詞選擇器或 App 切到背景時暫停。本機與 Navidrome 的背景音訊功能仍可使用。
- 部分影片、私人影片、年齡或區域限制內容無法嵌入；App 會顯示錯誤，不會自動跳去外部 App。
- 這不是 YouTube Music 完整客戶端；帳號曲庫範圍仍受官方 YouTube Data API 限制。移植的桌面原始碼、版本與建置方式見 [Visualizer](Visualizer/README.md)。

## 0.2.2 更新

- 修正側載 Bundle ID 後綴重複：編譯前的識別碼與 Google 登記的安裝後識別碼分開設定。`FOLIA_BUILD_BUNDLE_ID` 預設為原始的 `org.folia.community.ios`；`GOOGLE_IOS_BUNDLE_ID` 保留 Google 實際登記的值。
- 建置摘要與安裝包資訊會分別列出兩個識別碼；版本診斷頁也會同時顯示手機實際值與 Google 登記值。App 仍要求安裝後的識別碼與 Google 登記值完全相符。
- 原生簽署使用自訂識別碼時，維護者須把 `FOLIA_BUILD_BUNDLE_ID` 設為正式 App 的固定識別碼。

## 0.2.1 更新

- Google／YouTube 改由維護者在 GitHub Repository Variables 設定一次，使用者按「連接 Google 帳號」直接登入，無需填入 Client ID。
- 建置時自動帶入公開 Client ID、註冊回呼 scheme 與 Google 登記識別碼。App 會檢查簽署安裝後的識別碼，並避免沿用其他 Google 用戶端的舊授權。
- 設定尚未帶入的版本會停用 Google 登入並顯示說明；正式登入測試建置可要求設定必須存在。
- 維護者請依照 [Google／YouTube 完整設定教學](docs/Google-YouTube-maintainer.zh-TW.md) 完成 Cloud、測試使用者、用戶端與建置設定。Spotify 仍沿用原本的個別設定流程。

## 0.2.0 更新

- 歌詞換句時使用彈性捲動、位移與縮放，依距離調整模糊和透明度；目前歌詞帶有流動掃光。普通逐句 LRC 也能看到動畫，逐字著色仍依歌詞提供的時間資料。
- 播放背景使用持續移動的柔光。暫停、離開播放畫面或 App 進入背景後停止逐幀動畫，並遵循 iOS「減少動態效果」。
- 首頁增加 Spotify、YouTube 來源頁。使用系統瀏覽器登入，讀取歌單、收藏及分頁，點選歌曲會在原平台開啟。平台授權憑證存於鑰匙圈，可在帳號設定中移除。

### Spotify 首次設定

1. 在 [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) 建立自己的應用程式，選擇 iOS / Web API，Redirect URI 登記 `folia-spotify://callback`。
2. 開發模式的應用程式擁有者需有 Spotify Premium。將實際登入的 Spotify 帳號加入應用程式的測試使用者名單。
3. 在 Folia 的 Spotify 頁按「設定並登入」，填入 **Client ID**，按「登入並讀取曲庫」，在 Spotify 官方驗證視窗授權。
4. 可瀏覽帳號歌單、喜歡的歌曲，或開啟原平台。依 2026 年開發模式規則，只有自己擁有或協作歌單能讀取內容，其他歌單可能回覆 403。

### Google／YouTube 維護者統一設定

請閱讀 [Google／YouTube：維護者設定與發布教學](docs/Google-YouTube-maintainer.zh-TW.md)。維護者建立 iOS OAuth 用戶端後，在 GitHub 的 **Settings → Secrets and variables → Actions → Variables** 設定 `GOOGLE_IOS_CLIENT_ID` 與 `GOOGLE_IOS_BUNDLE_ID`，重新建置後發給使用者。兩者為公開應用程式識別資料，App 不內建 Client Secret 或任何使用者帳號憑證。

使用者在 Folia 的 YouTube 頁直接按「連接 Google 帳號」並授權即可。測試階段的登入帳號仍需由維護者加入 Google Cloud 測試使用者名單。

Google iOS 用戶端登記的 Bundle ID 必須與實際安裝版本一致；側載前的建置識別碼是獨立的 `FOLIA_BUILD_BUNDLE_ID`，預設保持專案原始值。側載工具若改寫它，Google 登入會顯示版本不相符；由每位安裝者各自重簽的 IPA 不保證能共用相同用戶端。正式分發需規劃維護者統一簽署與固定識別碼。

Spotify 仍使用原平台播放；YouTube 改為 App 內的官方影片播放器，搭配 Folia 歌詞動畫。Google 入口讀取官方 YouTube API 提供的帳號歌單與喜歡影片，可取得範圍與 YouTube Music 完整曲庫可能不同。

Spotify 標誌使用其[官方設計資源](https://developer.spotify.com/documentation/design)，僅用於平台內容歸屬標示。

## 在 Mac 建置並裝到 iPhone

1. 使用 Xcode 16 或更新版本開啟 `ios/Folia.xcodeproj`。
2. 選 `Folia` target → **Signing & Capabilities**，啟用 **Automatically manage signing** 並選擇自己的 Team。若 Bundle Identifier 已被使用，改為自己的唯一識別碼。
3. 連接 iPhone，在 Xcode 選該 iPhone 為執行目的地。若手機提示，前往「設定 → 隱私權與安全性 → 開發者模式」完成設定。
4. 按 **Run**，安裝後點「潮汐之間」驗證播放。也可先選擇 iPhone 模擬器確認 App 啟動。

## 在 Windows 觸發 GitHub 建置

將 ZIP 內的 `ios/` 與 `.github/workflows/folia-ios.yml` 一起放進自己有寫入權限的 GitHub 儲存庫根目錄。用 Git 推送變更後，在該儲存庫的 **Actions → Folia native iOS** 看結果。若工作流程已在預設分支，也可用 **Run workflow** 手動執行。

工作流程會檢查歌詞及曲庫邏輯、編譯模擬器與 iPhone 版本，並在 iPhone 模擬器執行播放與平台設定介面測試，最後上傳 `Folia-iOS-unsigned.ipa`。該 IPA 必須用適用於裝置的憑證及佈建描述檔簽署後才能安裝。若用自己的 Mac 和 iPhone，直接從 Xcode 按 **Run** 即可由 Xcode 處理開發簽署。

## 驗證

從專案根目錄執行 `bash ios/Checks/run.sh`，需 Swift 6。這會驗證歌詞時間軸、曲庫回應與分頁、重複歌曲、OAuth 回呼驗證、範例歌詞、Xcode 專案引用和背景音訊宣告。GitHub Actions 在 macOS 上執行這些檢查、Apple SDK 編譯和模擬器介面測試，畫面截圖會存入 `Folia-iOS-UI-checks` 建置產物。

0.1.0 曾經過兩輪獨立程式碼審查，修正歌詞記憶體使用、佇列更新、匯入與重試問題。Google 統一設定的帳號連接仍需用維護者的真實 iOS Client ID 與授權帳號驗證；自動化檢查涵蓋回應格式和介面，不代表已完成真實帳號登入。實機動畫、電量消耗和平台資料範圍仍需在 iPhone 驗證。

在實機上可依序確認以下操作。

1. 播放示範音軌，拖曳進度，點選歌詞，確認畫面跟上。
2. 播放時鎖定螢幕，在鎖定畫面按暫停、播放，並測試用多首歌組成的佇列切歌。
3. 從「檔案」匯入同名的音檔和歌詞，重啟 App 後確認歌曲與歌詞仍可使用。
4. 連線自己的 Navidrome，搜尋並播放一首有同步歌詞的歌曲，確認封面、時間軸和進度拖曳。

## 授權

原專案與圖示來自 [chthollyphile/folia-major](https://github.com/chthollyphile/folia-major)。此移植依 GNU AGPL v3 提供原始碼與授權全文，見 [LICENSE](../LICENSE)。內建示範音軌為本專案合成的音訊。
