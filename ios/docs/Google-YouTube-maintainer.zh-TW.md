# Google／YouTube：維護者設定與發布教學

適用 Folia iOS 0.2.1。目標是由維護者設定一次 Google 應用程式，安裝者只需按「連接 Google 帳號」、登入及授權，不建立 Google Cloud 專案，也不填 Client ID。

## 你的專案目前到哪裡

2026-11-05 查看 `folia-ios` 控制台時，已建立專案並啟用 YouTube Data API v3；品牌頁已有應用程式名稱、支援信箱與開發人員聯絡信箱。發布狀態為「測試」、使用者類型為「外部」。測試使用者為 0 人，尚未宣告資料存取範圍，也尚未建立 OAuth 用戶端。這些是當時的畫面狀態，之後以你控制台顯示的內容為準。

先完成下面的測試階段，再處理公開發布。Google Cloud 的「發布應用程式」、Google OAuth 驗證，以及 Apple 的 App 分發，是不同的程序。

## 1. 確認 App 的 Bundle ID

Google 的 iOS OAuth 用戶端必須登記實際安裝的 App 識別碼。原始專案預設為：

```text
org.folia.community.ios
```

若目前用 Sideloadly 安裝 0.2.0，請在手機開啟 Folia → YouTube →「設定並登入」，抄下頁面顯示的 Bundle ID。0.2.1 若顯示設定不相符，可在「連線說明 → 提供給 App 提供者的版本資訊」取得實際識別碼。

如果看到的值與上面不同，先使用實際值規劃測試版本，不要把專案預設值當成手機的值。Google Cloud 登記的值、GitHub 建置的值及簽署安裝後的值，必須一致。更改 Bundle ID 也可能讓 iPhone 將它視為另一個 App，原本的本機曲庫不會自動移過去。

你自行側載測試可先固定自己的識別碼；若每名使用者各用自己的 Apple 帳號重簽，側載工具可能分別改寫識別碼，一組 iOS Client ID 不保證能直接通用。正式對外分發應規劃由維護者統一簽署的 TestFlight／App Store 版本，保留一致的 Bundle ID。

## 2. 檢查品牌與 API

1. 開啟 [Google Auth Platform](https://console.cloud.google.com/auth/overview?project=folia-ios)，確認上方專案為 `Folia-ios`。
2. 左側點「品牌」，核對下面三項。你目前已填的值不用重新輸入。

| 欄位 | 要填的內容 |
|---|---|
| 應用程式名稱 | `Folia-ios`，或你打算正式顯示的名稱 |
| 使用者支援電子郵件 | 你實際會收信、能提供支援的信箱 |
| 開發人員聯絡資訊 | 你會接收 Google 通知的信箱 |

3. 有修改才按「儲存」。標誌、公開首頁、隱私權政策與授權網域，在正式發布階段再完整處理；若控制台此刻要求必填，請填真實、可存取的資料。
4. 開啟 [YouTube Data API v3](https://console.cloud.google.com/apis/library/youtube.googleapis.com?project=folia-ios)。你目前已顯示「API 已啟用」和「管理」，這一步已完成；若其他專案顯示「啟用」，才需要按它。

## 3. 宣告唯讀存取範圍

1. 回到 Google Auth Platform，左側點「資料存取權」。
2. 按「新增或移除範圍」。
3. 在面板下方「手動新增範圍」的「手動貼上範圍」欄位貼上完整值：

```text
https://www.googleapis.com/auth/youtube.readonly
```

4. 按「新增至資料表」，確認表格中這個範圍已勾選，再按面板的「更新」，回主頁按「儲存／Save」。
5. 確認已儲存的清單中出現這個完整範圍；Google 將它列在哪一類，就以控制台分類為準。

Google 同意畫面的說明可能是「查看你的 YouTube 帳戶」。此版只要求唯讀權限，功能使用它讀取歌單與喜歡的影片；不需要新增可上傳、修改或刪除影片的權限。

## 4. 加入測試使用者

1. 左側點「目標對象」。
2. 保留「外部」與「測試」狀態。
3. 在「測試使用者」按「新增使用者／Add users」。
4. 填入你將在 iPhone 的 Google 登入視窗中使用的帳號，按「儲存」。專案擁有者也要把實際測試登入的帳號列入。
5. 朋友要參加測試時，在同一處加入朋友實際使用的 Google 帳號。朋友不需要建立開發者專案。

測試模式最多 100 名指定測試者。這版要求 YouTube 權限，測試狀態的授權／refresh token 可能在 7 天後失效，到時重新連接帳號即可。這與免費 Apple 簽署的到期是兩件事。

## 5. 建立 iOS OAuth 用戶端

1. 左側點「用戶端」→「建立用戶端／建立 OAuth 用戶端」。
2. 「應用程式類型」選 **iOS**。
3. 依下表填寫：

| 欄位 | 測試階段要填的內容 |
|---|---|
| 名稱 | `Folia iOS testing`，便於你辨識用途 |
| Bundle ID／套件 ID | 第 1 步確認的實際 App 識別碼，大小寫及每個字元均須一致 |
| App Store ID | 尚未上架就先留空；若日後上架再依實際資料處理 |
| Team ID | 依你的 Apple 分發設定填寫；沒有就不要編造 |
| App Check | 此版尚未整合 App Check；先使用未要求 App Check 的測試用戶端。若你的正式用戶端已要求它，需另外整合，不能直接沿用本測試流程 |

4. 檢查欄位後按「建立」。這一步由你在自己的 Google Cloud 帳號中完成。
5. 複製 **Client ID／用戶端 ID**，外觀類似：

```text
1234567890-一串識別字.apps.googleusercontent.com
```

6. 保留這個 ID 與它登記的 Bundle ID。這兩項可用於 App 的建置設定；不要把密碼、驗證碼、access token 或 refresh token 貼進 GitHub。iOS 公開用戶端不需要在 App 中放 Client Secret。

請勿改選「網頁應用程式」、API 金鑰或服務帳戶。它們不能直接代替這裡的 iOS OAuth 用戶端。

## 6. 由維護者在 GitHub 設定一次

1. 開啟 [Fringetw/folia-ios](https://github.com/Fringetw/folia-ios)。
2. 點「Settings」→ 左側「Secrets and variables」→「Actions」。
3. 選 **Variables** 分頁，按 **New repository variable**。
4. 新增以下兩個變數，名稱必須完全一致：

| Name | Value |
|---|---|
| `GOOGLE_IOS_CLIENT_ID` | 第 5 步取得的完整 iOS Client ID |
| `GOOGLE_IOS_BUNDLE_ID` | 此 Client ID 在 Google Cloud 登記的 Bundle ID |

5. 每一項輸入後按「Add variable」。Client ID 是 App 識別碼，這裡使用 Variables；不要填入 Client Secret 或登入憑證。

設定變數本身不會重新編譯已下載的 IPA。必須執行下一步產生新版安裝檔，使用者才會拿到內建設定。

## 7. 建置與安裝測試

1. 確認這份 0.2.1 工作流程已在你要建置的分支。
2. 開啟 GitHub「Actions」→「Folia native iOS」→「Run workflow」。
3. 選取包含 0.2.1 更新的分支。更新尚在 PR 時，不要選仍是舊版本的 `main`。
4. 勾選 **Require the maintainer Google login configuration**，再按「Run workflow」。如果缺少兩個變數或值不合法，這次工作會直接失敗，避免把未設定的版本當成可登入版本。
5. 建置摘要應顯示 `Google login configured: true`，並列出你登記的 Bundle ID。
6. 等歌詞／曲庫檢查、iPhone 與模擬器編譯、介面測試全部成功。
7. 從 Artifacts 下載 `Folia-iOS-unsigned`，解壓後保留 `.ipa`。同包的 `google-login-build-info.json` 中，`google_configured` 應為 `true`。
8. 沿用你的簽署方式安裝。若想覆蓋舊 App 並沿用本機曲庫，必須保留相同 App 識別碼與簽署身分；不要先刪除舊 App。
9. 手機開 Folia → YouTube →「連接 Google 帳號」→ 選第 4 步的測試帳號 → 核對應用程式名稱與要求的唯讀權限 → 授權。
10. 確認能讀到自己的歌單與喜歡的影片，結束 App 後重開，再確認登入狀態可恢復。最後測試「帳號設定 → 中斷連線」。

未設定變數的程式碼檢查仍可以成功，並產出明確標示尚未啟用 Google 登入的測試版本；這種結果不代表真實帳號登入已驗證。

## 8. 正式公開前由你完成的工作

先通過真實帳號與實機測試，再處理以下項目：

1. 依 Google 的正式環境要求規劃正式專案與 OAuth 用戶端，與開發測試環境分開。正式用戶端登記正式分發的固定 Bundle ID。
2. 準備可公開存取的應用程式首頁與隱私權政策。說明讀取什麼資料、用途、資料儲存位置、聯絡方式，以及如何撤回授權／刪除資料；內容必須符合實際程式。私人的 GitHub 儲存庫網址不能當公開隱私政策。
3. 在「品牌」填入正式名稱、支援信箱、首頁與隱私權政策網址；使用你能證明擁有的網域，依要求透過 Search Console 完成網域驗證。
4. 在「資料存取權」只保留實際需要的範圍。對每個需驗證範圍，準備「為什麼功能必須用它」的具體說明。
5. 準備示範影片，清楚展示 App、Google 登入／授權畫面、使用該權限的歌單功能，以及與申請內容一致的應用程式名稱。
6. 到「驗證中心」依控制台要求提交品牌與範圍驗證；依審核要求補件。申請通過與否由 Google 決定，按「發布應用程式」不等於已完成驗證。
7. 依控制台要求完成正式發布狀態，使用正式 Client ID 與固定 Bundle ID 重新建置並簽署。用未列入舊測試名單的獨立帳號驗證正式流程。
8. Apple TestFlight／App Store 的分發設定與審查另行完成。Google OAuth 驗證不會替 IPA 簽署或讓 iPhone 直接安裝。

## 出錯時先看哪裡

| 現象 | 維護者要檢查的內容 |
|---|---|
| 「這個版本尚未啟用 Google 登入」 | 是否已設定兩個 Repository Variables、是否已重新建置、拿到的是否為該次新 IPA |
| 「這個安裝版本的 Google 登入設定不相符」 | Google 登記、建置摘要及手機實際 Bundle ID 是否一致；側載是否改寫了 ID |
| `access_denied`／測試帳號無權使用 | 實際登入帳號是否已列入同一專案的測試使用者 |
| `redirect_uri_mismatch` | 是否建立 iOS 類型用戶端、是否用到正確 Client ID、是否安裝剛重新建置的版本 |
| `invalid_client` | 是否誤貼 API key、Web Client ID 或不完整的 Client ID |
| 授權成功但讀曲庫失敗 | 同一專案的 YouTube Data API v3 是否已啟用、`youtube.readonly` 是否已授權、API 配額或帳號限制 |
| 大約 7 天後需重新連接 | 檢查 Google 測試模式授權到期；也另外檢查 Apple 側載簽署是否到期 |
| 歌單或收藏比 YouTube Music 少 | 官方 YouTube Data API 提供的是帳號歌單與喜歡影片，並非完整 YouTube Music 專用曲庫 |

## 官方參考

- [Google iOS API 存取與用戶端設定](https://developers.google.com/identity/sign-in/ios/api-access)
- [Google iOS Client ID 與回呼 scheme](https://developers.google.com/identity/sign-in/ios/start-integrating)
- [Google OAuth 應用程式狀態與測試使用者](https://developers.google.com/identity/protocols/oauth2/production-readiness/overview)
- [OAuth refresh token 到期條件](https://developers.google.com/identity/protocols/oauth2#expiration)
- [正式發布政策要求](https://developers.google.com/identity/protocols/oauth2/production-readiness/policy-compliance)
- [機密範圍驗證](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification)
- [GitHub Repository Variables 設定](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables)
