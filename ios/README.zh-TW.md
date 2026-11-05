# Folia iOS 0.2.0

以 [Folia Major](https://github.com/chthollyphile/folia-major/tree/3125d376557182e25a12c915e39099db13ba63c8) 為基礎的非官方 iPhone 移植。介面使用 SwiftUI，播放使用 AVFoundation，鎖定畫面與控制中心使用 MediaPlayer。iPhone 最低系統版本為 iOS 17。Xcode 專案沒有外部套件依賴。這版介面提供臺灣繁體中文。

## 第一版功能

- 從「檔案」匯入 iOS 可播放的音檔，例如 MP3、AAC、M4A、WAV，儲存於 App 的本機曲庫。
- 使用播放佇列、上一首、下一首、循環和拖曳進度。音訊工作階段配置背景播放，並接上鎖定畫面和控制中心的播放指令。
- 顯示 LRC、逐字 Enhanced LRC、Folia 匯出的 `.fia`。也會讀取系統能辨識的內嵌 LRC。從「檔案」選取同名音檔和歌詞可一起匯入，也可長按曲庫中的歌曲附加歌詞。點選歌詞可跳到對應時間。
- 以自己的 HTTPS Navidrome 伺服器搜尋與串流，讀取封面和伺服器提供的同步歌詞。伺服器使用有效且受信任的 TLS 憑證。帳號資訊與密碼存於 iPhone 的鑰匙圈。
- 內建 30 秒「潮汐之間」示範音軌與歌詞，可離線試用。

此版保留 Folia 以全螢幕歌詞為主的體驗，採用一套新的原生歌詞畫面。桌面版的動畫樣式、第三方線上音源及 Folium 插件留待後續移植。

## 0.2.0 更新

- 歌詞換句時使用彈性捲動、位移與縮放，依距離調整模糊和透明度；目前歌詞帶有流動掃光。普通逐句 LRC 也能看到動畫，逐字著色仍依歌詞提供的時間資料。
- 播放背景使用持續移動的柔光。暫停、離開播放畫面或 App 進入背景後停止逐幀動畫，並遵循 iOS「減少動態效果」。
- 首頁增加 Spotify、YouTube 來源頁。使用系統瀏覽器登入，讀取歌單、收藏及分頁，點選歌曲會在原平台開啟。平台授權憑證存於鑰匙圈，可在帳號設定中移除。

### Spotify 首次設定

1. 在 [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) 建立自己的應用程式，選擇 iOS / Web API，Redirect URI 登記 `folia-spotify://callback`。
2. 開發模式的應用程式擁有者需有 Spotify Premium。將實際登入的 Spotify 帳號加入應用程式的測試使用者名單。
3. 在 Folia 的 Spotify 頁按「設定並登入」，填入 **Client ID**，按「登入並讀取曲庫」，在 Spotify 官方驗證視窗授權。
4. 可瀏覽帳號歌單、喜歡的歌曲，或開啟原平台。依 2026 年開發模式規則，只有自己擁有或協作歌單能讀取內容，其他歌單可能回覆 403。

### YouTube Music 首次設定

1. 在 [Google Cloud Console](https://console.cloud.google.com/apis/credentials) 建立專案，啟用 **YouTube Data API v3**。
2. 設定 OAuth 同意畫面，加入自己的 Google 帳號作為測試使用者，建立 **iOS 類型的 OAuth Client ID**。Bundle ID 請使用 Folia 帳號設定頁顯示的實際值，側載工具可能變更它。
3. 在 Folia 的 YouTube 頁填入此 Client ID，按「登入並讀取曲庫」，授權 `youtube.readonly`。
4. 系統驗證工作階段使用 Client ID 的反向網域作為回呼 scheme，搭配 PKCE 與隨機 state 驗證。應用程式內不需要 Client Secret。
5. 這裡讀取的是 YouTube Data API 提供的帳號歌單與喜歡的影片（含音樂）。YouTube Music 專屬的收藏、專輯、動態混音等，可能不在這個 API 範圍內。點選項目會開啟對應的 YouTube Music 網址。

平台帳號讀取與本機音樂播放各自運作。Spotify / YouTube Music 的音訊由原平台播放；Folia 內的歌詞動畫目前用於本機與 Navidrome 播放。首次連接需自行建立平台 Client ID，GitHub 建置不會帶入帳號或登入憑證。

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

從解壓後的根目錄執行 `bash ios/Checks/run.sh`，需 Swift 6。這會驗證歌詞時間軸、範例歌詞、Xcode 專案引用和背景音訊宣告。交付前已在 Linux 執行這些檢查、Swift 語法解析及上游 TypeScript 型別檢查。Apple SDK 編譯與實機測試待在 Mac、GitHub Actions 或 iPhone 上執行。

經過兩輪獨立程式碼審查。第一輪修正 LRC 記憶體膨脹、佇列歌詞更新、檔案讀取阻塞、Navidrome 歌詞時間、播放重試與殘留匯入檔案。第二輪修正本機歌詞重新解析、舊匯入結果覆蓋狀態和伺服器回應大小上限。第二輪修正後已重跑本機檢查。

在實機上可依序確認以下操作。

1. 播放示範音軌，拖曳進度，點選歌詞，確認畫面跟上。
2. 播放時鎖定螢幕，在鎖定畫面按暫停、播放，並測試用多首歌組成的佇列切歌。
3. 從「檔案」匯入同名的音檔和歌詞，重啟 App 後確認歌曲與歌詞仍可使用。
4. 連線自己的 Navidrome，搜尋並播放一首有同步歌詞的歌曲，確認封面、時間軸和進度拖曳。

## 授權

原專案與圖示來自 [chthollyphile/folia-major](https://github.com/chthollyphile/folia-major)。此移植依 GNU AGPL v3 提供原始碼與授權全文，見 [LICENSE](LICENSE)。內建示範音軌為本專案合成的音訊。
