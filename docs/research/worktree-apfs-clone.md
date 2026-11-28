# 新 worktree 用 APFS clone 複製 warm 建置(實驗 #721)

結論:**不可行**(只就 SwiftPM `.build` 驗證;沒有提供腳本)。複製後第一次 `swift build --build-tests` 仍把 1120 個建置步驟全部重跑,沒有省時間,clone 的空間還會被重編譯的寫入吃掉。

## 環境

- macOS 27.2.1(Darwin 27.2.0)、Xcode 27.0(27A266a)、APFS(`/dev/disk3s1s1`,約 228 GiB,實驗時可用 37 GiB)
- 兩個 detached worktree(`git worktree add`),放在暫時目錄,同一個 commit(整合分支 release-0.55)
- 實驗期間機器上另有其他 session 在建置,CPU 被分掉,秒數只能當量級參考,不能精確比較

## 量測

| 步驟 | 命令 | 結果 |
|---|---|---|
| 冷建置(A) | `swift build --build-tests` | 189 秒(user 614 秒),`.build` 2.1 GB,1120 步 |
| clone | `cp -c -R A/.build B/.build` | 9.8 秒;可用空間差約 0.46 GB |
| clone 後第一次建置(B) | `swift build --build-tests` | **467 秒(user 704 秒),仍跑到 `[1118 / 1120]`**,等於整個重建 |
| B 無改動再建一次 | 同上 | 5 秒 |
| B 改 `src/PurrdrCore` 一個檔後建置 | 同上 | 15 秒 |
| A 在 B 改檔後建置 | 同上 | 15 秒(只重驗,沒有重編譯 PurrdrCore;B 的改動沒有影響 A) |

## 原因

clone 出來的 `.build` 裡有 164 個檔案(build plan、`.d`、swiftdeps、module cache 路徑等)寫死 A 的絕對路徑。SwiftPM 以路徑與指令簽章判斷是否過期,路徑不同就整個重編;重編譯會對 clone 過的檔案寫入,寫時複製的共用區塊隨之分開,空間優勢消失。

## 未驗證

- `xcodebuild build` 的 DerivedData 沒有量(SwiftPM 部分已證明路徑問題,DerivedData 同樣含絕對路徑與 index,預期相同,未實測)。
- 沒有跑模擬器與 UI 測試(模擬器不存在)。

## 清理

實驗的兩個 worktree 與 `.build` 已用 `git worktree remove` 與 `rm -rf` 移除。
