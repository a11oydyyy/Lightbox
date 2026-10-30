<p align="center">
  <img src=".github/media/icon.png" width="128" height="128" alt="Lightbox App 圖示">
</p>

<h1 align="center">Lightbox</h1>

<p align="center">
  <b>輕巧、快速的 Mac 看圖與相片瀏覽軟體。</b><br>
  直接在原本的資料夾裡瀏覽、選片、整理照片，不必匯入、不建圖庫。<br>
  給用 Camera Raw 修圖的攝影師，一個免費的 Adobe Bridge 替代方案。
</p>

<p align="center">
  <a href="https://github.com/a11oydyyy/Lightbox/releases/latest"><img src="https://img.shields.io/github/v/release/a11oydyyy/Lightbox?label=%E4%B8%8B%E8%BC%89&color=2f2f2f" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-2f2f2f" alt="macOS 13 以上">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-%E5%8E%9F%E7%94%9F-2f2f2f" alt="支援 Apple Silicon 與 Intel">
</p>

<p align="center">
  <a href="README.md">English</a> · <b>繁體中文</b> · <a href="README.ja.md">日本語</a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/media/hero-dark.jpg">
  <img src=".github/media/hero-light.jpg" alt="Lightbox 以瀑布流顯示資料夾及其子資料夾的照片，按資料夾分組，側邊欄有分頁與常用位置">
</picture>

## 為什麼是 Lightbox

- **資料夾就是你的圖庫。** 打開 Mac、外接硬碟或 NAS 上的任何資料夾就能瀏覽。不匯入、不複製、不鎖進目錄檔，Finder、Photoshop 和其他 App 看到的始終是同一批檔案。
- **為 Camera Raw 工作流程而做。** 一眼看出哪些照片已在 Adobe Camera Raw 或 Lightroom 調整過，單鍵選片，再透過 Photoshop 批次轉存 JPEG——正是多數攝影師在 Bridge 裡真正會用到的那些功能，卻沒有它的笨重。
- **就像 macOS 的一部分。** 原生、開啟迅速，支援淺色與深色、鍵盤操作，分頁、Quick Look、顏色標籤和復原都在你預期的地方。

## 功能

### 瀏覽資料夾，而不是圖庫

<img src=".github/media/browse.gif" alt="按資料夾分組顯示所有子資料夾的照片、收起分組、放大縮圖">

- 分頁、固定資料夾、上一頁／下一頁，側邊欄列出常用位置與磁碟
- 保留每張照片比例的瀑布流，或可依欄位排序的列表檢視
- **包含子資料夾**：一次看完整次拍攝，依資料夾分組；不需要的分組可以收起，Lightbox 會記住
- 縮圖大小滑桿，點兩端圓點即可每行增減一張（⌘= / ⌘−）

### 一眼看出哪些照片修過


- 已有 Camera Raw 或 Lightroom 調整設定的照片會帶一個小標記：RAW 讀取 `.xmp` 旁檔，JPEG、TIFF、DNG 讀取內嵌 XMP，判斷方式與 Bridge 相同
- 篩選「已調整」或「未調整」，馬上知道還剩哪些沒修
- 在 Lightbox 裡改名、拷貝、搬移或丟到廢紙簍時，RAW 的 XMP 旁檔會一起跟著走

### 預覽、放大到 100%、單鍵選片

<img src=".github/media/preview-cull.gif" alt="打開預覽、放大到 100% 檢查細節、單鍵標記保留">

- 點一下縮圖就是大圖預覽，方向鍵切換上一張／下一張
- 按 **Z** 以 100% 檢查對焦，拖曳查看各處；連拍時切換照片也停在同一位置
- **P** 保留、**X** 淘汰、**U** 取消——以 Finder 標準顏色標籤儲存，在哪裡都看得到
- 相機、鏡頭與曝光資訊，以及挑選相似照片用的比較列

### 排序與篩選，不添雜亂

<img src=".github/media/sort-filter.gif" alt="排序與篩選面板，以及生效中的篩選在底部工具欄旁以小標籤顯示">

- 依名稱、加入日期、大小、種類、尺寸或標籤排序
- 依種類（照片、RAW、影片、文件）、方向、長邊、加入日期、檔案大小、Camera Raw 狀態及 Finder 顏色標籤篩選
- 生效中的篩選以小標籤顯示，一鍵清除；檔名搜尋可涵蓋子資料夾

### 像 Finder 一樣整理檔案，而且能復原

- 單檔或批次重新命名（取代文字、加入文字、名稱加編號）、新增資料夾、移到廢紙簍，全部可以 ⌘Z 復原
- 把照片拖到其他分頁即可拷貝或搬移，也能拖到任何 App
- Quick Look、在 Finder 中顯示、打開方式，也可選擇顯示圖片以外的檔案

### 透過 Photoshop 批次轉存 JPEG


相當於 Bridge 的**影像處理器**：選好照片、選「轉存為 JPEG…」，Photoshop 會逐張套用 Camera Raw 設定後存成 JPEG，可設定品質、轉換為 sRGB 和限制長邊。原圖不會被改動，也不會覆蓋任何檔案。其他時候，「在 Photoshop 中開啟」也只要一下。

> Camera Raw 的調整只有 Adobe 的引擎能算出來，所以轉存需要安裝 Photoshop；瀏覽、選片和整理則不需要。

### 為 Mac 而生

- 跟隨系統的淺色與深色外觀，可調整玻璃質感
- 完整的鍵盤操作與 VoiceOver 標籤
- 介面支援英文、繁體中文、簡體中文和日文
- 自動檢查更新，安裝前會先詢問

## 快捷鍵

| 動作 | 按鍵 | 動作 | 按鍵 |
| --- | --- | --- | --- |
| 新增／關閉分頁 | ⌘T / ⌘W | 預覽／Quick Look | 空白鍵 / ⌘Y |
| 上一頁／下一頁 | ⌘[ / ⌘] | 預覽放大到 100% | Z |
| 上層資料夾 | ⌘↑ | 保留／淘汰／取消 | P / X / U |
| 前往資料夾 | ⇧⌘G | 重新命名 | ⇧⌘R |
| 搜尋 | ⌘F | 新增資料夾 | ⇧⌘N |
| 排序與篩選 | ⌥⌘F | 移到廢紙簍 | ⌘⌫ |
| 放大／縮小縮圖 | ⌘= / ⌘− | 在 Photoshop 中開啟 | ⌥⌘O |
| 圖庫／列表檢視 | ⌃⌘1 / ⌃⌘2 | 轉存為 JPEG | ⇧⌘E |

## 下載

到 **[Releases](https://github.com/a11oydyyy/Lightbox/releases/latest)** 下載最新版本。

| 安裝包 | 系統需求 |
| --- | --- |
| `Lightbox-v*.zip` | Apple Silicon，macOS 15 或更新版本 |
| `Lightbox-Intel-x86-v*.zip` | Intel 或 Apple Silicon，macOS 13 或更新版本 |

Intel 安裝包同時包含兩種架構，在 Apple Silicon 上也會原生執行。各版本的簽署狀態與已知限制請見發布說明。

## 常見問題

**Lightbox 可以取代 Adobe Bridge 嗎？**
如果你主要用 Bridge 瀏覽資料夾、確認哪些照片修過、選片和批次轉存 JPEG，可以。為了保持輕巧快速，它刻意不做關鍵字、收藏集和輸出範本。

**Lightbox 會匯入或修改我的照片嗎？**
不會。它直接讀取原本的資料夾，只有在你要求時才會動檔案（改名、搬移、加標籤、丟到廢紙簍）。改名、加標籤和丟到廢紙簍可以復原；跨分頁搬移目前不能復原，也會清除先前的復原記錄。

**支援 RAW 檔嗎？**
支援 CR3、CR2、NEF、ARW、RAF、ORF、RW2、DNG 等 macOS 能讀取的格式。預覽顯示的是原始 RAW；Camera Raw 的調整會在轉存時由 Photoshop 套用。

**可以拿來取代「預覽程式」或「照片」看圖嗎？**
可以。它直接打開資料夾，點一下就預覽，方向鍵切換，不會把任何東西匯入圖庫。

**外接硬碟和 NAS 可以用嗎？**
可以。網路和外接磁碟採用保守的載入方式，大型共享資料夾也能保持流暢。

## 回饋

遇到問題或有建議，歡迎到 [Issues](https://github.com/a11oydyyy/Lightbox/issues) 回報，並附上 Lightbox 版本、macOS 版本和 Mac 晶片類型。

<sub>示範照片由 <a href="https://unsplash.com">Unsplash</a> 攝影師提供。</sub>

<sub>關鍵字：Mac 看圖軟體 · Mac 相片瀏覽器 · Adobe Bridge 替代 · Camera Raw · XMP 旁檔 · 選片 · RAW 看圖 · 批次重新命名 · 批次轉 JPG · Mac 看图软件 · 图片浏览器 · Bridge 替代软件 · 批量导出 JPG</sub>
