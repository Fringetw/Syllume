# 播放驗證紀錄

獨立分支 `codex/syllume-player-experience`。側載候選為 0.4.0 build 54（`a449159`），可在 Windows 用 Sideloadly 重簽。iPhone 尚待使用者側載與驗證。 [未簽署 IPA](https://github.com/Fringetw/Syllume/actions/runs/45045168886/artifacts/14762779645)

## build 54 的逾時續播與重新定位

原生播放逾時會保留 AVPlayer 最後確認的位置。重試時，本機音檔須是相同檔案且屬性相符。已下載音檔仍走原有完整性檢查。直接選取的 Navidrome 曲目保留同一帳號及曲目 ID，重新取得串流網址。新播放項目須完成定位後才開始輸出音訊。若使用者在逾時後先定位，則採用同一播放項目確認的新位置。YouTube 官方播放器和跨音源切換保留各自的播放流程。 [播放修正](https://github.com/Fringetw/Syllume/commit/b1778abafb5a431308fde5d14bda6848624416c6) · [手動定位修正](https://github.com/Fringetw/Syllume/commit/a449159f1b7549454707adbb674de23a51b67f17)

| 驗證層級 | 結果 |
| --- | --- |
| iOS 26 模擬器 | 12/12。使用 AVPlayer 真正播放內建音檔並注入時鐘停滯。確認逾時後仍維持暫停、手動重試的首筆定位在原位置 ±0.35 秒內，以及第二次逾時後手動定位會清除舊錯誤並從新位置續播。其餘測試包括暫停拖曳、切歌與循環、霧盞樣式記憶、字幕同步備援及 HTTP 停傳。 [測試、截圖與 HTTP 紀錄](https://github.com/Fringetw/Syllume/actions/runs/45045168886/artifacts/14764371164) |
| iOS 18.6 模擬器 | Intel 25/26，Apple Silicon 24/26。兩者的主要播放套件皆為 19/19。Intel 的《JANE DOE》商籟未就緒。Apple Silicon 的《JANE DOE》商籟收到首幀，《Lemon》繪光在導航後 18.199 秒逾時。另外一項 Apple Silicon 離線快取測試遇到 XCTest 終止 App 失敗。 [Intel](https://github.com/Fringetw/Syllume/actions/runs/45045168886/artifacts/14765950524) · [Apple Silicon](https://github.com/Fringetw/Syllume/actions/runs/45045169059/artifacts/14764399812) |
| 核心測試 | macOS Swift 核心、40 項 JavaScript、14 項 Python、5 項商籟與繪光渲染交接測試皆通過。 [核心測試](https://github.com/Fringetw/Syllume/actions/runs/45045168886/artifacts/14763600903) · [編譯日誌](https://github.com/Fringetw/Syllume/actions/runs/45045168886/job/137278085415) |
| 真實 Navidrome HTTPS | build 53 的正式 Swift 客戶端通過驗證、搜尋、錄音比對、下載解碼及錯誤帳密分類。串流與下載內容相符，380,160 bytes、29.975 秒。build 54 新增 iOS 模擬器直接用該伺服器播放的逾時續播測試，結果待確認。 [API 紀錄](https://github.com/Fringetw/Syllume/actions/runs/45044889213/artifacts/14762744592) · [模擬器測試](https://github.com/Fringetw/Syllume/actions/runs/45080683460) |
| 公開 HTTPS | build 53 通過。build 54 首輪確認 AVPlayer 已由 HTTPS 起播，但 XCTest 暫停未達預期。取樣在按鈕操作前看見 18.300 秒、操作後看見 1.401 秒，與測試操作跨過該 30 秒音檔片尾的情形一致。重跑結果待確認。 [build 53](https://github.com/Fringetw/Syllume/actions/runs/45044843532/artifacts/14763227909) · [build 54 初測](https://github.com/Fringetw/Syllume/actions/runs/45045171460/artifacts/14765085621) |
| 模擬器資源 | iOS 26 的霧盞各取樣 4 秒，共 3 次。平均 App CPU 時間 0.563 秒，平均實體記憶體峰值 75,450 kB。iPhone 的 FPS、GPU、耗電與行動網路流量待驗。 [取樣日誌](https://github.com/Fringetw/Syllume/actions/runs/45045168886/job/137278085180) |

IPA 已核對 ZIP、ARM64、最低 iOS 17、iPhoneOS 26.2 SDK、內建歌詞資源和未簽署狀態。SHA-256 為 `881378C5E8569E49D18C297C632E82F005BBFFC024C95D7BA02524D8D4879BB5`。實機續播、私人 OAuth、官方 YouTube 播放及日常用量待驗。 [build 54 IPA](https://github.com/Fringetw/Syllume/actions/runs/45045168886/artifacts/14762779645)

## build 52 的原生時鐘與串流等待

原生媒體在已經起播後，若引擎持續回報播放中但時鐘三秒未前進，會直接重讀時鐘並進入緩衝。暫停、定位或換曲會取消舊的檢查。串流仍可因新資料獲得寬限，單次緩衝最多 34 秒。Swift 核心測試涵蓋無效時鐘樣本、遲到但有前進的樣本、重新開始檢查，以及起播前與起播後持續收資料的絕對期限。 [macOS 核心輸出](https://github.com/Fringetw/Syllume/actions/runs/45035888866/artifacts/14760121237)

iOS 26 的 12 項常規回歸全數通過。在停滯案例中，先驗證內建音檔的 AVPlayer 時間前進，再注入「播放中但時鐘停止」回報，確認逾時後可手動重試並再次起播。套件另通過限速串流、停傳時的定位恢復、本機冷啟動、片尾切換及霧盞樣式記憶。這個停滯案例由測試注入，iPhone 的自然停滯待實機驗證。 [iOS 26 工作日誌](https://github.com/Fringetw/Syllume/actions/runs/45035888866/job/137249441753) · [常規回歸產物](https://github.com/Fringetw/Syllume/actions/runs/45035888866/artifacts/14760233849)

Apple Silicon 的 iOS 18.6 完整回歸 26/26，含歌單 5 項、錄影曲目 1 項、主套件 19 項及 iPhone SE 1 項。iOS 26 獨立起播回歸 7/7，所用 App 原始碼與 IPA 相同。該次工作補匯出了停滯測試摘要與截圖。 [iOS 18.6 ARM 回歸](https://github.com/Fringetw/Syllume/actions/runs/45035913389/artifacts/14761976042) · [iOS 26 停滯及重試證據](https://github.com/Fringetw/Syllume/actions/runs/45038646129/artifacts/14761896478)

Intel 的 iOS 18.6 完整回歸 25/26，原生時鐘停滯與重試通過。唯一失敗仍是《JANE DOE》同時呈現影片和商籟。第 23.741 秒交回 Pixi，第 28.148 秒仍無首幀回報。 [Intel 回歸](https://github.com/Fringetw/Syllume/actions/runs/45035888866/artifacts/14762597649) · [Intel 首幀紀錄](https://github.com/Fringetw/Syllume/actions/runs/45035888866/artifacts/14761500019)

使用公開 HTTPS 的同一段音檔，iOS 26 的 AVPlayer 確認暫停定位到 11.983 秒並續播至 14.006 秒，通過 1/1。最近一次官方 YouTube 實播仍是 build 50，當時兩支測試影片都回傳 150。 [build 52 公開 HTTPS](https://github.com/Fringetw/Syllume/actions/runs/45035946231/artifacts/14760851755) · [build 50 官方 YouTube 測試](https://github.com/Fringetw/Syllume/actions/runs/45020718228/artifacts/14753768828)

iOS 26 的霧盞三次四秒取樣平均 App CPU 時間為 1.164 秒，三次分別為 1.726、1.167 和 0.597 秒，平均實體記憶體峰值約 75.0 MB。取樣跨 Runner 且有波動，實機 GPU、FPS、耗電及流量待驗。 [XCTest 效能輸出](https://github.com/Fringetw/Syllume/actions/runs/45035888866/job/137249441753)

iPhone Release 為 0.4.0 build 52（`9a8b038`），使用 iPhoneOS 26.2 SDK，最低 iOS 17。已核對 ARM64、封裝、未簽署狀態與內建歌詞資源，SHA-256 為 `BB97FEE4FD94622A3EB9079BB241B08EF705B841AB1DCD614E65166D132DECA0`。 [build 52 IPA](https://github.com/Fringetw/Syllume/actions/runs/45035888866/artifacts/14759912358)

## build 50 的首幀與跨架構驗證

`78010c2` 將選用的平行著色器預熱限制在 1.5 秒。逾時及取消會回收未完成的圖形資源，已連結的程式保留，剩餘程式交給 Pixi 在首幀連結。四項模擬 WebGL 回歸均通過，含逾時、取消、已完成的快取及未支援延伸的環境。macOS 核心與五項實際渲染程式的暫停交接測試也通過。 [核心檢查](https://github.com/Fringetw/Syllume/actions/runs/45015475372/artifacts/14750844179) · [常規 CI](https://github.com/Fringetw/Syllume/actions/runs/45015475372)

iOS 26 常規回歸 11/11。WebKit 在預熱用滿 1,500 毫秒後交回 Pixi，第 6.059 秒畫出商籟首幀，第 6.072 秒就緒。霧盞三次四秒取樣的平均 App CPU 時間為 0.293 秒，平均實體記憶體峰值為 75,335.339 kB。iPhone 的 GPU、耗電、FPS 與行動網路流量待實機量測。 [iOS 26 原始測試、日誌與畫面](https://github.com/Fringetw/Syllume/actions/runs/45015475372/artifacts/14752451742) · [效能工作日誌](https://github.com/Fringetw/Syllume/actions/runs/45015475372/job/137186739997)

Intel iOS 18.6 的錄影曲目在 2.302 秒完成橋接，7.603 秒開始輪詢預熱結果，8.034 秒交回 Pixi。第 22.302 秒仍無首幀回報，該案例未通過。Apple Silicon 的 iOS 18.6 使用同一份 App 原始碼，錄影曲目通過。商籟第一次在 7.472 秒就緒，繪光在 3.863 秒就緒，並驗證播放和暫停時鐘同步。 [Intel 首幀紀錄](https://github.com/Fringetw/Syllume/actions/runs/45015475372/artifacts/14752383286) · [Apple Silicon 首幀紀錄](https://github.com/Fringetw/Syllume/actions/runs/45017940297/artifacts/14752624622)

Apple Silicon iOS 18.6 完整回歸 25/25，包含歌單 5/5、錄影曲目 1/1、主套件 18/18 和 iPhone SE 1/1。Intel iOS 18.6 為 24/25，只有可見影片同時搭配《JANE DOE》商籟的案例未通過，本機音訊搭配商籟冷啟仍通過。霧盞三次四秒平均 App CPU 時間和記憶體峰值分別為 Apple Silicon 的 0.655 秒和 63,583.232 kB，以及 Intel 的 1.024 秒和 53,522.432 kB。這些是不同 Runner 的取樣。 [Apple Silicon 測試與畫面](https://github.com/Fringetw/Syllume/actions/runs/45017940297/artifacts/14753745830) · [Intel 測試與畫面](https://github.com/Fringetw/Syllume/actions/runs/45015475372/artifacts/14753606834)

同一份 App 原始碼在真實 Navidrome v0.64.2 服務通過 HTTPS、演出者與錄音版本配對。串流與完整下載均為 380,160 bytes，逐位元與正確錄音相符，完整解碼為 29.975 秒。錯誤帳密在搜尋與下載均回傳 Subsonic 40。公開 HTTPS 音源由 AVPlayer 暫停定位到 11.983 秒、續播到 13.934 秒，通過 1/1。《HELP!!》與 YouTube 示範影片在官方 IFrame 都回傳 150、停在 0:00，實際 YouTube 起播為 0/2。 [Navidrome 原始結果](https://github.com/Fringetw/Syllume/actions/runs/45020718228/artifacts/14753587518) · [公開 HTTPS 與 YouTube 原始結果](https://github.com/Fringetw/Syllume/actions/runs/45020718228/artifacts/14753768828)

公開字幕端點取得 LRCLIB《JANE DOE》21 行、《Lemon》37 行同步歌詞，網易雲 42 行和 QQ 57 行翻譯。YouTube 譯製上傳與 YouTube Music 的字幕仍要求驗證。 [字幕端點原始結果](https://github.com/Fringetw/Syllume/actions/runs/45017940297/artifacts/14752254359)

iPhone Release 使用 iPhoneOS 26.2 SDK 並支援 iOS 17 起的裝置。核對封裝完整性、未簽署狀態、Release 執行檔，以及內建歌詞資源與該提交相符。SHA-256 為 `B593F46A587E7FC9BCCDA1F6525AB2CC32E8BAFE3948E6F4208740A5BB858F13`。 [build 50 IPA](https://github.com/Fringetw/Syllume/actions/runs/45015475372/artifacts/14752195515)

## build 49 的橋接與著色器分段測量

離線頁面主動回報橋接就緒，切換與重建時依導航識別碼比對訊息和命令。iOS 26 常規回歸 11/11，診斷成功量到頁面在 1.148 秒通知橋接就緒、5.416 秒達到商籟首幀。霧盞三次四秒平均 App CPU 時間為 0.403 秒，平均實體記憶體峰值為 75,176.896 kB。 [iOS 26 原始測試與畫面](https://github.com/Fringetw/Syllume/actions/runs/45012566953/artifacts/14750793072)

iOS 18 的《JANE DOE》第 4.128 秒完成橋接，WebGL、字型、資產和場景準備也完成。第 8.930 秒進入著色器預熱，第 21.964 秒仍無預熱完成訊號。這次回歸未通過。 [原始首幀紀錄](https://github.com/Fringetw/Syllume/actions/runs/45012566953/artifacts/14750894926)

`69a5ec1` 已產出未簽署的 0.4.0 build 49，最低 iOS 17。包內離線歌詞資源與該提交逐位元相符。IPA SHA-256 為 `16FC45A10190568A117755FCD48BA3DAD112B3EF4FF279EA716245368B217DBA`。 [build 49 IPA](https://github.com/Fringetw/Syllume/actions/runs/45012566953/artifacts/14750139726)

## build 48 的動畫交接與 WebKit 追查

新增首幀分段紀錄後，iOS 18 的《JANE DOE》案例在第 13.682 秒完成導航，第 18.105 秒仍未收到 Swift 另行送出的橋接探測回覆。這次尚未進入渲染器。build 47 另有已載入字型後逾時的案例，當時未量到渲染器內部階段。 [iOS 18 原始紀錄](https://github.com/Fringetw/Syllume/actions/runs/45010063984/artifacts/14750166763)

商籟與繪光在暫停時完成尚未結束的換歌交接，並在目前媒體時間畫出新歌詞。以實際渲染程式方法重現三個失敗，修正後五項通過。這組測試以替身取代 GPU 和資產操作。`39002ea` 的 iOS 26 獨立回歸六項通過，含本機起播、冷啟動畫、逾時備援、最大字級，以及錄影曲目的兩種動畫時鐘。 [iOS 26 回歸](https://github.com/Fringetw/Syllume/actions/runs/45010640226/artifacts/14750435197)

## build 47 的動畫就緒與同步文字

`b556329` 在 WebKit 確認橋接和載入字型後，分階段計算後續等待時間。整次初始化以單調時鐘限制在 36 秒，失敗重試沿用同一期限。初始化及失敗後顯示跟著媒體進度的 SwiftUI 文字；就緒時立即送最新媒體時鐘。開發者診斷沿用同一初始化上限。 [常規回歸](https://github.com/Fringetw/Syllume/actions/runs/44990301596)

同提交在 macOS 的真實 Navidrome v0.64.2 通過 HTTPS、演出者及錄音版本配對、串流與完整下載。串流和下載同為 380,160 bytes，與正確來源相符。音檔完整解碼為 29.975 秒，錯誤憑證回傳 Subsonic 40。 [API 工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44990337355/job/137109790035) · [原始測試結果](https://github.com/Fringetw/Syllume/actions/runs/44990337355/artifacts/14741760872)

在 iOS 26 模擬器使用公開 HTTPS 音源以 AVPlayer 起播、暫停定位至 11.983 秒，續播至 14.121 秒，通過 1/1。官方 YouTube IFrame 的真實播放為 0/2。《HELP!!》與官方示範影片均回傳 150，媒體時鐘維持 0:00，播放器顯示登入驗證。私人帳號及 iPhone 待驗。 [公開媒體日誌](https://github.com/Fringetw/Syllume/actions/runs/44990337355/job/137109790253) · [原始測試與畫面](https://github.com/Fringetw/Syllume/actions/runs/44990337355/artifacts/14741263388)

iOS 26 的 11 項常規回歸全數通過，含暫停拖曳、霧盞記憶、片尾切歌、防停頓、限速與停傳、本機起播重開、商籟同頁重試及動畫無回應時的同步文字。無回應夾具於 24.277 秒結束等待，實際音訊持續前進。霧盞三次四秒取樣的平均 App CPU 時間為 0.548 秒，平均實體記憶體峰值 74,805.589 kB。iPhone 的 FPS、GPU、耗電與流量待驗。 [iOS 26 測試與截圖](https://github.com/Fringetw/Syllume/actions/runs/44990301596/artifacts/14742182268) · [iOS 26 資源日誌](https://github.com/Fringetw/Syllume/actions/runs/44990301596/job/137109673524)

iOS 18.6 的歌單 5/5、主套件 17/18、iPhone SE 大字級 1/1，錄影曲目 0/1。錄影曲目的商籟在 15.449 秒載入字型，31.476 秒逾時，仍未收到首幀就緒；主套件的商籟冷啟也回報逾時。霧盞三次四秒平均 App CPU 時間為 0.795 秒，平均實體記憶體峰值 53,764.096 kB。 [iOS 18 測試、錄影與初始化日誌](https://github.com/Fringetw/Syllume/actions/runs/44990301596/artifacts/14743547050) · [iOS 18 工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44990301596/job/137109673362)

iPhone Release 使用 iPhoneOS 26.2 SDK，最低 iOS 17。已核對 IPA 解壓及 Release 無 Debug 測試參數。這份 IPA 尚未簽署。SHA-256 為 `24F3C491709277721369021A5BABC5513E02E29AA0DE145BA132553F4EAA8796`。 [build 47 IPA](https://github.com/Fringetw/Syllume/actions/runs/44990301596/artifacts/14741971459)

## build 46 的本機起播與動畫逾時

本機檔案未回報播放進度時，現在有起播期限，僅自動重開一次。下載檔重開前再次核對先前驗證過的檔案狀態。動畫載入失敗時，維持媒體原本的播放狀態。同一個 WebKit 頁面若拒絕第一次歌曲命令，會重送一次給已確認的橋接程式。

iOS 26 獨立回歸 6/6 通過，涵蓋本機冷啟、檔案自動重開、歌曲命令重送、動畫永久無回應時音訊繼續、最大字級及錄影曲目搭配商籟與繪光。常規 iOS 26 回歸為 10/11；最大字級案例的第一次啟動曾回報 Runner 找不到 LLDB，獨立回歸有執行到操作並通過。 [獨立回歸與畫面](https://github.com/Fringetw/Syllume/actions/runs/44986744181/artifacts/14740706618) · [常規 CI](https://github.com/Fringetw/Syllume/actions/runs/44984607738)

iOS 18 的《JANE DOE》商籟重現失敗。影片的受控媒體時鐘仍前進，動畫頁面在 5.188 秒完成導航、11.144 秒確認橋接、13.414 秒載入內建字型，約 16 秒逾時。字型載入後只剩約 2.6 秒完成渲染器與首幀。獨立回歸的歌單套件為 5/5，錄影曲目 0/1。 [iOS 18 原始測試、錄影及 Sonnet-recorded.log](https://github.com/Fringetw/Syllume/actions/runs/44987982245/artifacts/14741650691)

`aead1f6` 已產出未簽署的 0.4.0 build 46。該版 iOS 18 回歸仍有失敗。解出的 IPA SHA-256 為 `7411DF758BAC13DFFB49A3A69413EC5F323FBD908D392A9188AF59620CF927B8`。 [build 46 IPA](https://github.com/Fringetw/Syllume/actions/runs/44984607738/artifacts/14738903245)

## build 45 的正式 Navidrome 與冷啟動

隔離的 Navidrome v0.64.2 以 HTTPS 提供專案示範音軌。正式 Swift 客戶端從三筆結果選中正確錄音，排除不同演出者和現場版。串流及完整下載均與正確檔案逐位元相同，下載總計 380,160 bytes，完整解碼為 29.975 秒。搜尋及下載拒絕錯誤憑證，保留 Subsonic 40 與重新驗證分類。公開示範站另獨立確認 `ping`、`search3` 回傳 HTTP 200。實際 iPhone 和個人伺服器仍待驗證。 [隔離伺服器測試](https://github.com/Fringetw/Syllume/actions/runs/44945525721) · [原始整合紀錄](https://github.com/Fringetw/Syllume/actions/runs/44945525721/artifacts/14723526708)

build 45 的 iPhone Release、核心檢查與 iOS 26 常規 8/8 通過。iOS 18.6 為 21/22；商籟冷啟動案例的錄影中，本機《潮汐之間》停在 0:00 等待緩衝，商籟持續顯示準備中。同期的錄影曲目、逐行動畫和 iPhone SE 大字級通過。 [常規 CI](https://github.com/Fringetw/Syllume/actions/runs/44943106824) · [iOS 18 原始畫面與錄影](https://github.com/Fringetw/Syllume/actions/runs/44943106824/artifacts/14723599390)

iOS 26 Runner 的霧盞四秒取樣中，平均記憶體峰值從 build 44 的約 75 MB 增至 build 45 的約 172 MB；兩輪工作位於不同 Runner。iOS 18 的 build 45 取樣約 53 MB。尚未確認此次差異是否可重現，實機資源仍待量測。 [build 45 iOS 26 工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44943106824/job/136964420824) · [build 45 iOS 18 工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44943106824/job/136964421196)

## build 44 的交付證據

| 範圍 | 結果 | 證據 |
| --- | --- | --- |
| macOS 核心 | Swift、33 項 JavaScript、14 項 Python 通過，涵蓋封面共用下載、最後請求取消與重試快取。 | [核心與公開字幕端點](https://github.com/Fringetw/Syllume/actions/runs/44935718039/artifacts/14719442952) |
| iOS 18.6 | iPhone 16 Pro 21/21、iPhone SE（第 3 代）1/1。SE 首次在 XCTest 無障礙初始化逾時，尚未開始案例，按既有規則重跑一次後通過。涵蓋歌單、封面與頭像、歌詞同步、播放切換及最大字級。 | [iOS 18 原始畫面與測試摘要](https://github.com/Fringetw/Syllume/actions/runs/44935718039/artifacts/14722017180) |
| iOS 26 | iPhone 17 Pro 8/8。另有同一提交的公開 HTTPS 獨立測試 1/1。 | [iOS 26 測試與畫面](https://github.com/Fringetw/Syllume/actions/runs/44935718039/artifacts/14720036557) · [公開 HTTPS 測試](https://github.com/Fringetw/Syllume/actions/runs/44935730804) |
| 動畫資源 | 霧盞各三次四秒取樣。iOS 18 平均 App CPU 時間 0.968 秒、平均實體記憶體峰值約 53 MB。iOS 26 為 0.337 秒及約 75 MB。 | [iOS 18 工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44935718039/job/136941769428) · [iOS 26 工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44935718039/job/136941769693) |
| 公開字幕 API | LRCLIB《JANE DOE》21 行、《Lemon》37 行，NetEase 42 行、QQ 57 行譯文。YouTube 上傳與 YouTube Music 字幕仍要求驗證。 | [端點紀錄](https://github.com/Fringetw/Syllume/actions/runs/44935718039/artifacts/14719442952) |

裝置版使用 iPhoneOS 26.2 SDK，最低 iOS 17。已核對 IPA 可解壓，Release 執行檔無公開播放測試的 Debug 啟動參數。解出內部 IPA 的 SHA-256 為 `1BADD746942C0295447310C28FE2B59B7BD77B5813347F612264DCED96B3144D`。 [build 44 IPA 產物](https://github.com/Fringetw/Syllume/actions/runs/44935718039/artifacts/14719598309)

build 44 第一輪因封面工作呼叫 actor 缺少 `await` 而無法編譯。`3caaeaa` 修正後通過上列測試。 [第一輪失敗紀錄](https://github.com/Fringetw/Syllume/actions/runs/44935523514)

## build 44 的公開 HTTPS 與封面流量

在 iOS 26 模擬器以 `public_native_only` 讀取固定提交的《潮汐之間》M4A。伺服器回傳 `206 Partial Content`，完整回應的 380,123 bytes 與內建音檔相符。AVPlayer 實際起播，在暫停時定位到 11.983 秒，續播後前進到 13.676 秒，媒體來源維持 HTTPS。公開測試 1/1 通過。歌單及音源選擇由測試提供，音檔經由公開伺服器傳入。 [Actions 工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44935730804/job/136941811739) · [定位與續播畫面、Range 與雜湊](https://github.com/Fringetw/Syllume/actions/runs/44935730804/artifacts/14719384292)

封面與歌手頭像共用 URL 傳輸。Swift 回歸驗證兩個請求者共用一次下載，取消其中一個會保留傳輸，取消最後一個會停止傳輸。後續請求可重新下載並經由磁碟快取重開。實測手法使用可控的圖片傳輸，尚未測量 iPhone 行動網路的實際節省量。 [核心測試紀錄](https://github.com/Fringetw/Syllume/actions/runs/44935718039/artifacts/14719442952)

同批 iOS 26 的本機受控 HTTP 用真正的 AVPlayer 搭配 Range 伺服器。正常傳輸為 3 次 GET／629,176 bytes，限速 4 次／406,386 bytes，起播停傳 1 次／0 bytes，停傳定位後恢復 6 次／671,218 bytes。數字為各案例的伺服器回應量。不同案例的試播、定位與停傳位置不同，iPhone 流量仍待實測。 [本機 HTTP 測試與原始傳輸紀錄](https://github.com/Fringetw/Syllume/actions/runs/44935718039/artifacts/14720036557)

## build 43 的交付證據

| 範圍 | 結果 | 證據 |
| --- | --- | --- |
| macOS 核心 | Swift、33 項 JavaScript、14 項 Python 通過。含 IFrame 101／150、保留原始錯誤碼、停止緩衝及手動重試。 | [核心檢查與公開端點](https://github.com/Fringetw/Syllume/actions/runs/44920735689/artifacts/14713339353) |
| iOS 18.6 | iPhone 16 Pro 21/21、iPhone SE（第 3 代）1/1。含播放、拖曳、兩種歌詞時鐘、切歌、歌單與最大字級。 | [測試摘要、畫面與紀錄](https://github.com/Fringetw/Syllume/actions/runs/44920735689/artifacts/14714429422) |
| iOS 26 | iPhone 17 Pro 8/8。含定位、霧盞記憶、HTTP 限速、停傳逾時及恢復。 | [測試摘要與 HTTP 紀錄](https://github.com/Fringetw/Syllume/actions/runs/44920735689/artifacts/14714102840) |
| 公開字幕 API | LRCLIB《JANE DOE》21 行、《Lemon》37 行，NetEase 42 行、QQ 57 行譯文。YouTube 上傳與 YouTube Music 字幕回報需驗證。 | [端點紀錄](https://github.com/Fringetw/Syllume/actions/runs/44920735689/artifacts/14713339353) |
| 霧盞資源 | 各三次四秒取樣。iOS 18 平均 App CPU 時間 0.810 秒、平均實體記憶體峰值約 54 MB。iOS 26 為 1.395 秒與約 76 MB。 | [iOS 18 日誌](https://github.com/Fringetw/Syllume/actions/runs/44920735689/job/136895986055) · [iOS 26 日誌](https://github.com/Fringetw/Syllume/actions/runs/44920735689/job/136895986306) |

裝置版使用 iPhoneOS 26.2 SDK，最低 iOS 17。IPA 解壓可讀，Release 執行檔未含公開測試的 Debug 啟動參數。解開 Actions 產物後，內部 IPA 的 SHA-256 為 `9B5EC2D59A68D27EAD54D521159813906A85154143CB4F0F2E628B03D4324F0F`。 [build 43 IPA 產物](https://github.com/Fringetw/Syllume/actions/runs/44920735689/artifacts/14714075284)

## build 42 的交付證據

| 範圍 | 結果 | 證據 |
| --- | --- | --- |
| macOS 核心 | Swift、33 項 JavaScript、14 項 Python 通過 | [核心檢查與公開端點](https://github.com/Fringetw/Syllume/actions/runs/44912653550/artifacts/14710088023) · [完整工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44912653550/job/136871541684) |
| iOS 18.6 | iPhone 16 Pro 21/21、iPhone SE（第 3 代）1/1。含《HELP!!》暫停定位後單次操作續播、兩種動畫時鐘暫停、離線封面、下載確認及 SE 最大字級 | [iOS 18 測試摘要、畫面與證據](https://github.com/Fringetw/Syllume/actions/runs/44912653550/artifacts/14713015595) |
| iOS 26 | iPhone 17 Pro 8/8。含起播、暫停拖曳、霧盞記憶、HTTP 限速、停傳逾時與恢復 | [iOS 26 測試紀錄及畫面](https://github.com/Fringetw/Syllume/actions/runs/44912653550/artifacts/14711156717) |
| 真實公開字幕 API | LRCLIB 回傳《JANE DOE》21 行、《Lemon》37 行，NetEase 42 行及 QQ 57 行譯文。YouTube 上傳與 YouTube Music 字幕需要站方驗證 | [本輪端點紀錄](https://github.com/Fringetw/Syllume/actions/runs/44912653550/artifacts/14710088023) |
| 霧盞資源 | 三次四秒取樣的平均 App CPU 時間，iOS 18 為 0.932 秒、iOS 26 為 0.625 秒。平均實體記憶體峰值約 53 MB 與 74 MB | [iOS 18 工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44912653550/job/136871541684) · [iOS 26 工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44912653550/job/136871541339) |

《HELP!!》回歸使用 WebKit 與受控本機媒體，刻意讓第一次續播指令失敗，並驗證重送後的播放時鐘前進。HTTP 回歸使用 AVPlayer 與受控 Range 伺服器。真實帳號、YouTube 原片、行動網路流量與耗電需用安裝後的 iPhone 驗證。

Actions 產物解壓後，`Syllume-iOS-0.4.0-unsigned.ipa` 的 SHA-256 為 `6BB868822B7E612394157FAFE121A545B400A9E6F8B989547F8DFE33B671DFAF`。 [build 42 IPA 產物](https://github.com/Fringetw/Syllume/actions/runs/44912653550/artifacts/14710682446)

## 公開 YouTube IFrame 媒體

獨立啟動 `public_youtube_only` 後，iOS 26 模擬器透過官方 IFrame 連線，以 Google 文件的示範影片及錄影中的《HELP!!》測試實際起播。歌單資料由測試提供。兩支影片在 `9fa26a9` 均停在 0:00 並回傳 `permission:150`，官方播放器畫面要求登入以驗證使用者。此次測試為 0/2 通過。 [Actions 日誌](https://github.com/Fringetw/Syllume/actions/runs/44919608518/job/136892563850) · [原始畫面和測試摘要](https://github.com/Fringetw/Syllume/actions/runs/44919608518/artifacts/14713825322)

build 43 對 101／150 顯示 YouTube 目前無法在 App 內播放，並保留原始代碼與 YouTube Music 開啟入口。若 YouTube Data API 明確標記該影片禁止嵌入，播放畫面仍顯示該影片的限制。重驗時兩支影片仍回傳 150 並顯示登入驗證，播放測試 0/2 通過。兩個案例均確認新提示、開啟連結及取消緩衝後，才在媒體時間斷言失敗。實機播放需要單獨驗證。 [build 43 日誌](https://github.com/Fringetw/Syllume/actions/runs/44920747445/job/136896025650) · [build 43 畫面與摘要](https://github.com/Fringetw/Syllume/actions/runs/44920747445/artifacts/14713343838) · [YouTube IFrame API 錯誤碼](https://developers.google.com/youtube/iframe_api_reference#onError)

## build 34 的 macOS 與模擬器

`ed9940d` 的整體工作流程失敗，紀錄日期為 2026-11-18 UTC。 [Actions 原始紀錄](https://github.com/Fringetw/Syllume/actions/runs/44320598586)

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

`d28b2a1` 的 iOS 26 為 7/8。霧盞定位案例在播放按鈕出現後立即讀取標籤，當時還沒進入可暫停狀態。CI 記錄沒有點按暫停便進入等待，原生時鐘繼續前進。測試改成先驗證播放已開始，再點按暫停並檢查實際 AVPlayer 時鐘。iPhone 裝置程式維持 build 40。[iOS 26 日誌](https://github.com/Fringetw/Syllume/actions/runs/44893690096/job/136814714550)

同一版的 iOS 18 iPhone 16 Pro 通過 21/21，包含兩種播放器的 Spotify 交接。SE 工作包含首次開機、資料移轉及該裝置的資產編譯，準備自動化時到達 12 分鐘上限，尚未執行版面斷言。`df51d74` 的 iOS 26 通過 8/8。CI 保留原有測試，並提高 Intel 歌單與 SE 步驟上限。[iOS 18 日誌](https://github.com/Fringetw/Syllume/actions/runs/44893690096/job/136814714251) · [iOS 26 重驗](https://github.com/Fringetw/Syllume/actions/runs/44895554905/artifacts/14704516679)

## build 41 的 HTTP 定位

`fe0f6cf` 的受控測試在 112.572 秒出現新的假就緒狀態。停傳後，目標 Range 收到 0 bytes，AVPlayer 的 preroll 卻回報就緒。當時的緩衝區起迄都顯示為 112.572 秒，原本的判斷將定位標成成功。build 41 要求實際落點之後至少有 0.01 秒的已載入媒體才確認 HTTP 定位，並將診斷區段精度提高到小數點後六位。單元測試包含次毫秒的暫時區段，整合測試仍要求停傳逾時並能在恢復後重新定位。[失敗工作日誌](https://github.com/Fringetw/Syllume/actions/runs/44899264181/job/136831521290) · [HTTP 原始附件](https://github.com/Fringetw/Syllume/actions/runs/44899264181/artifacts/14705793357)

`bf2f21b` 的 iPhone Release、Swift 核心、33 項 JavaScript、14 項 Python、iPhone 16 Pro iOS 18.6 21/21、iPhone SE 1/1 及 iOS 26 8/8 全部通過。停傳重驗確實出現 112.571667–112.571687 秒的約 20 微秒區段。App 保持定位等待直到逾時，恢復傳輸後成功在暫停中移至 7.513333 秒。[完整 CI](https://github.com/Fringetw/Syllume/actions/runs/44902543774) · [iOS 18](https://github.com/Fringetw/Syllume/actions/runs/44902543774/artifacts/14707881704) · [iOS 26](https://github.com/Fringetw/Syllume/actions/runs/44902543774/artifacts/14707585559)

## build 42 的 YouTube 續播

若 WebKit 在已可見的文件拒絕後續播放指令，舊版會將版本標記為已送出。JavaScript 保留舊版本，App 忽略舊時間快照，造成等待後逾時。新版會在同一工作階段及指令版本重送一次。受控案例在暫停定位後讓 WebKit 拒絕第一個續播指令，驗證只點一次就能重送並讓媒體時鐘前進。外部 YouTube 播放與實機條件仍待驗證。

`88ef7e8` 的《HELP!!》續播重送、歌單 5/5、一般 iOS 18 回歸 15/15 與 iOS 26 8/8 通過。錄影曲目案例中，《Lemon》的進度停在約 1:46，但 XCTest 在繪光的暫停狀態讀取逾時。新版測試先確認媒體時鐘暫停，再給渲染器觀測充分時間確認停止和同步。SE 環境在 XCTest 初始化即出現 AX 通知逾時，未執行版面斷言。CI 僅在案例尚未開始且遇到該初始化錯誤時重試一次。[iOS 18 日誌](https://github.com/Fringetw/Syllume/actions/runs/44906288873/job/136852462364) · [iOS 18 原始證據](https://github.com/Fringetw/Syllume/actions/runs/44906288873/artifacts/14710471529)
