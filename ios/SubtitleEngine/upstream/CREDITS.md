# 來源、致謝與授權

## 維護與開發協助

- 維護與發布：[Fringetw](https://github.com/Fringetw)。
- 初版程式碼、測試與文件由 ChatGPT／Codex 協助製作。

## 使用的開源專案

| 專案 | 用途 | 使用版本／基準 | 上游授權 |
| --- | --- | --- | --- |
| [chthollyphile/folia-major](https://github.com/chthollyphile/folia-major) | 宿主播放器、公開 Folium API、測試時使用的宿主資料驗證與 ZIP 安裝流程 | 自動測試 v0.7.22、v0.7.23；首版另驗證開發提交 99f8468785cce03d4760d5cc80aa4eec6ec5c965 | [AGPL-3.0](https://github.com/chthollyphile/folia-major/blob/v0.7.22/LICENSE) |
| [BYVoid/OpenCC](https://github.com/BYVoid/OpenCC) | 開放中文轉換的上游專案與字典體系 | 透過 opencc-js／opencc-data 使用；沒有另外內附 OpenCC C++ 執行檔 | [Apache-2.0](https://github.com/BYVoid/OpenCC/blob/master/LICENSE) |
| [nk2028/opencc-js](https://github.com/nk2028/opencc-js) | 瀏覽器可執行的 JavaScript 轉換引擎 | npm opencc-js@1.4.2 | 引擎 MIT；所含字典另採 Apache-2.0 |
| [nk2028/opencc-data](https://github.com/nk2028/opencc-data) | opencc-js 建置時產生內附字典的來源 | 1.4.2，隨上述 opencc-js 發布檔內附 | [Apache-2.0](https://github.com/nk2028/opencc-data/blob/main/LICENSE) |

感謝上述專案的作者、維護者與所有貢獻者。

## 隨附的第三方內容

`mods/opencc-traditional-lyrics/vendor/opencc-cn2t-1.4.2.mjs` 原樣取自 npm `opencc-js@1.4.2` 的 `dist/esm/cn2t.js`，僅更改檔名與副檔名。

該版本的原始授權檔完整保留於：

- [LICENSE.opencc-js](mods/opencc-traditional-lyrics/vendor/LICENSE.opencc-js)：MIT，原始著作權聲明為 The nk2028 Project。
- [LICENSE.OpenCC](mods/opencc-traditional-lyrics/vendor/LICENSE.OpenCC)：Apache License 2.0。
- [THIRD_PARTY_LICENSES.md](mods/opencc-traditional-lyrics/vendor/THIRD_PARTY_LICENSES.md)：字典資料的第三方來源與授權說明。

此儲存庫的根目錄 [LICENSE](LICENSE) 適用於本專案自行撰寫的內容，沒有替換或重新授權上述第三方內容。

## 關於上游貢獻

這是獨立的 Folia 第三方插件。此處的致謝清單不等於維護者的上游貢獻紀錄。

若未來向上游提出 Bug 修正、文件更新或其他改動，可在此新增實際 PR、issue 或 commit 的連結，並標明處理狀態。只有已合併的 PR 才標示為「已合併」。
