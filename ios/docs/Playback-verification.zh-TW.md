# 播放驗證紀錄

分支 `codex/syllume-player-experience`，未合併 main。以下結果對應 `ed9940d`，日期為 2026-11-18 UTC。後續測試修改須重新執行，不能沿用這份結果宣稱通過。

## macOS 與模擬器

[Actions 原始紀錄](https://github.com/Fringetw/Syllume/actions/runs/44320598586) 整體失敗。

| 範圍 | 已觀察結果 | 證據及限制 |
| --- | --- | --- |
| 核心回歸 | 通過 | Swift 核心、29 項 JavaScript、14 項 Python。包含音源配對、完整解碼、下載替換、請求共用、過期回覆、定位期限及繁體轉換。使用本機媒體與模擬回應。 |
| iOS 18 UI | 17/18 通過 | 歌單 5/5、錄影曲目 1/1、主套件 11/12。Spotify 返回後的第二次續播測試失敗；錄影可見媒體時間持續前進及單曲循環，但 XCTest 讀到舊的狀態元素。待以每次呈現新查詢的回歸確認。 |
| iOS 26 UI | 6/7 通過 | 大字級、霧盞定位及記憶、資源取樣、一般 HTTP、限速 HTTP、起播停傳備援通過。暫停定位停傳案例在起播的 20 秒測試期限到期，尚未進入定位。失敗取樣隨後可見 HTTP 時間 2.501 秒、速率 1。 |
| HTTP 測試來源 | 受控 localhost 伺服器 | 真實 AVPlayer、HTTP Range 與內建測試媒體。限速為每秒 65,536 位元組。一般／限速案例確認定位後仍為 HTTP；尚需加強驗證音訊預備完成及恢復後時間前進。此結果不證明外部平台可用。 |
| 霧盞資源 | 已取樣 | iOS 26 ARM 模擬器，每次 4 秒，3 次平均 App CPU 時間 0.937 秒、實體記憶體峰值 75,881.536 kB。尚無 iPhone FPS、GPU 或耗電數據。 |
| iPhone Release | 編譯通過 | iPhoneOS 26.2 SDK、0.4.0 build 34、最低 iOS 17，未簽署 IPA。未包含 Debug localhost 網路例外。 |

遠端音訊有資料但仍在 AVPlayer 的防停頓等待期間，先前會被 7 秒無資料期限提早切換。現在使用明確的等待原因及最長 34 秒起播上限。暫停定位的完成回覆也可能早於音訊備妥；現在保留定位狀態及 12 秒期限，等待 `preroll` 結果。

## 真實 API

同次 Runner 的公開端點探查取得 LRCLIB《JANE DOE》21 行、《Lemon》37 行同步歌詞，網易雲及 QQ 各 42 行與 57 行譯文。YouTube 譯製上傳與 YouTube Music 遇到驗證限制。這些是字幕或搜尋回應，沒有驗證私人帳號、外部音源可聞播放或下載配對。

## Windows／Sideloadly 與 iPhone

IPA 需由使用者在 Sideloadly 重簽。沿用先前安裝的 Apple ID 與最終 Bundle ID，才能驗證覆蓋升級及既有資料。Google 登記值需與安裝後識別碼相符；請依 [維護者設定](Google-YouTube-maintainer.zh-TW.md) 核對，避免重複添加簽署後綴。

以下尚未實機驗證。

1. 同一支 iPhone 在 Wi-Fi 與 4G 點播原先失敗的《HELP!!》，記錄首次可聞聲音、實際來源及診斷結果。官方 YouTube 播放器須可見。
2. 本機及有權存取的網路音源，測試冷啟、暫停、點按／拖曳定位、斷網與恢復、切歌、單曲循環及鎖定畫面。
3. 對照原文與繁體譯文，確認暫停停止、定位立即更新、五種樣式可切換並保存。無逐字時間戳的歌詞只驗逐行效果。
4. 比較相同曲目的媒體請求與傳輸位元組，驗證重播減少重複查詢；外部 YouTube 與 API 流量另記。
5. 測試下載重開、封面與歌手頭像、私人歌單登入、最大字級、VoiceOver、減少動態效果、降低透明度及低耗電。量測實機 FPS、CPU、GPU、記憶體與耗電。

匯出新版本的診斷 JSON 時，保留歌曲、操作、網路、裝置與時間，才能與 0.3.17 的故障紀錄比較。完整目標仍在開發與驗證中。

## build 35 播放基準

新增兩秒一次的 YouTube 時間回報回歸，涵蓋起播與播放中延遲、真正凍結後的 18 秒期限及未起播的 25 秒期限。原生片尾事件新增純核心順序模擬，以及使用真實 AVPlayer 的 UI 案例。後者注入延遲片尾通知後確認已定位的音訊仍繼續前進，再驗證播放中定位至實際片尾會循環、暫停定位至片尾維持暫停。

`eeca302` 的核心回歸及 iOS 26 整合 8/8 通過。涵蓋一般及限速 HTTP 起播、暫停定位後恢復、停傳備援、停傳定位逾時與恢復、大字級、霧盞定位／記憶及片尾事件。事件通知注入屬於模擬，HTTP 使用受控 localhost 音源，均不代表已在 iPhone 驗證外部平台播放。[iOS 26 證據](https://github.com/Fringetw/Syllume/actions/runs/44469052806/artifacts/14504615822)

取樣證實 AVPlayer 在目標 112.572 秒尚未載入時，`preroll` 已回報完成，可用範圍仍只有 0–24.163 秒。新檢查繼續等待，沿用 12 秒期限並正確逾時。恢復傳輸後，7.513 秒定位在範圍 7.513–24.572 秒到達時才完成，維持暫停。原始取樣及伺服器紀錄保存在上方產物。

同版嚴格 Swift 核心、29 項 JavaScript、14 項 Python 通過。公開字幕探查與模擬器測試分開記錄；仍沒有外部平台可聞播放或私人帳號結果。[核心證據](https://github.com/Fringetw/Syllume/actions/runs/44469052806/artifacts/14503816079)

`eeca302` 的 iOS 18 完整回歸 19/19 通過，包含歌單 5 項、錄影曲目的播放與同步 1 項，以及主套件 13 項。Spotify 返回後兩種播放器的續播均通過。該次 macOS 工作流程兩個工作全部通過。[本版 CI](https://github.com/Fringetw/Syllume/actions/runs/44469052806) · [iOS 18 證據](https://github.com/Fringetw/Syllume/actions/runs/44469052806/artifacts/14506041427)

`eeca302` 的 iPhone Release 已編譯，0.4.0 build 35、iPhoneOS 26.2 SDK、最低 iOS 17。IPA 未簽署，未包含 Debug localhost 網路例外。SHA-256 `AFBC7ECCC0C32038DB6FB21A8ECE28CD24FA1FB758976B66FF1553DEEA65EBC2`。[IPA 產物](https://github.com/Fringetw/Syllume/actions/runs/44469052806/artifacts/14504156133)

霧盞每次 4 秒、3 次平均 App CPU 時間 1.358 秒，平均實體記憶體峰值 75,635.712 kB。這是 ARM 模擬器取樣，未量測實機 FPS、GPU 或耗電。使用者選擇稍後自行用 Sideloadly 側載，簽署、安裝與實機播放仍未驗證。

## build 36 歌詞回歸

以本機單元案例重現商籟與繪光平分逐行時間的問題。修正後保留全部字形、組合 emoji 及標點，共用實際整行的時間窗。真實逐字與音節時序各有回歸。霧盞淡入淡出直接使用原文、譯文共用的媒體時間包絡。加入逐行測試夾具，會分別在暫停定位後檢驗兩種動畫舞台與繁體譯文，並保存畫面。Xcode 模擬器與裝置編譯結果仍待本輪 CI。

`d6ea4e3` 新增 iPhone SE（第 3 代）與大字級的獨立模擬器測試。以 WebKit 測試媒體核對可見區域、控制觸控大小、暫停定位及在影片下方捲動到同步歌詞。 [小螢幕 CI](https://github.com/Fringetw/Syllume/actions/runs/44553346583)

## build 37 歌手頭像回歸

原本取得歌曲封面後不再查詢頭像，兩張圖也共用同一個顯示狀態。現在在媒體時間開始前進後，對目前歌曲核對頻道與演出者，獨立顯示及快取符合條件的頭像。保留每首歌有權存取的官方媒體路徑，舊歌單若缺少可核對的演出者資訊，可能需先連線補資料。

新增受控測試，涵蓋封面與頭像同時顯示、錯誤頻道不套用上一首頭像、離線重開後沿用已存頭像。真實頻道照片、私人歌單和 iPhone 仍待驗證。

`00fa881` 在 iPhone 16 Pro 模擬器通過 21/21，包含商籟、繪光逐行、頭像和封面同時顯示及離線快取。iPhone SE 的大字級測試在曲庫首頁找不到分段控制，當時尚未進入播放頁。iOS 26 8/8、Swift、33 項 JavaScript、14 項 Python 與 iPhone Release 編譯通過。[iOS 18 證據](https://github.com/Fringetw/Syllume/actions/runs/44553844534/artifacts/14550048247) · [iOS 26 證據](https://github.com/Fringetw/Syllume/actions/runs/44553844534/artifacts/14548860037) · [未簽署 IPA](https://github.com/Fringetw/Syllume/actions/runs/44553844534/artifacts/14545920254)

## build 38 歌曲選項

`1833d25` 的下載測試錄影顯示長按歌曲後直接進入播放，而下載確認未出現。新增可點選的「歌曲選項」，讓操作不必依賴長按。測試會確認選項不會觸發播放、下載前仍須確認，並驗證取消及最後的儲存。

`414b751` 的 iPhone 16 Pro 模擬器通過 19/21，iPhone SE（第 3 代）通過 1/1，iOS 26 通過 8/8。下載案例的錄影顯示歌單選擇器已收起，畫面也有獨立的歌曲選項。XCTest 仍回報按鈕沒有有效的點擊位置。封面案例通過無法播放時的封面及系統播放資訊斷言，截圖請求逾時後未執行離線重開。SE 案例的影片尺寸與控制、暫停定位及歌詞時間都通過，但截圖顯示大字歌詞仍被可捲動區裁切。[iOS 18 證據](https://github.com/Fringetw/Syllume/actions/runs/44755571812/artifacts/14644905607) · [iOS 26 證據](https://github.com/Fringetw/Syllume/actions/runs/44755571812/artifacts/14640736237)

build 39 改用標準按鈕開啟歌曲動作對話框。回歸先確認歌單選擇器已收起以及按鈕在畫面內。封面測試直接驗證兩次離線重開。小螢幕的霧盞依內容高度排版，和曲目資訊放在同一個可捲動區。測試要求整個歌詞框在可見區，並確認影片與進度條位置維持固定。

`cc6a35f` 通過 iPhone 16 Pro iOS 18.6 的歌單 5/5、錄影曲目 1/1，以及一般回歸 14/15。iPhone SE 通過 1/1，截圖可讀到暫停定位後的「風聲」。iOS 26 通過 8/8，iPhone Release 編譯通過。唯一失敗的 Spotify 交接案例在小播放器恢復後沒有從無障礙測試讀到第二筆資料。錄影的同一段播放從 0:08 走到 0:23，該次介面沒有卡住。[iOS 18 證據](https://github.com/Fringetw/Syllume/actions/runs/44766901367/artifacts/14650546366) · [iOS 26 證據](https://github.com/Fringetw/Syllume/actions/runs/44766901367/artifacts/14646563413) · [未簽署 IPA](https://github.com/Fringetw/Syllume/actions/runs/44766901367/artifacts/14646493229)

build 40 的交接回歸從播放器取得每次交接後已前進至少 0.2 秒的原生時鐘狀態，分別驗證全螢幕與小播放器恢復播放。最大字級使用較短的播放頁標題，VoiceOver 仍會讀出完整標題。
