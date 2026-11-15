# Domain Docs

engineering skills 探索程式碼時，如何使用本 repo 的領域文件。

## 探索前先讀

- 根目錄的 **`GLOSSARY.md`**(本 repo 是單一 context,沒有 `GLOSSARY-MAP.md`)。
- **`docs/adr/`**:讀跟你要動的範圍有關的 ADR。

這些檔案不存在時，**直接繼續，不要提**。不要指出它們缺少，也不要建議先建立。`/domain-modeling`(由 `/grill-with-docs` 與 `/improve-codebase-architecture` 觸發)會在術語或決策真正定案時才建立它們。

## 檔案結構

```
/
├── GLOSSARY.md
├── docs/adr/
│   ├── 0001-clean-room-from-herdrchat.md
│   └── ...
└── src/
```

## 用術語表的詞

輸出裡提到領域概念時(issue 標題、重構提案、假設、測試名稱),一律用 `GLOSSARY.md` 定義的詞，不要換成術語表明列「避免」的同義詞。

需要的概念還不在術語表裡，代表兩種可能：你在發明專案沒在用的說法(請重新考慮),或術語表真的有缺口(記下來交給 `/domain-modeling`)。

## 標出跟 ADR 衝突的地方

輸出跟現有 ADR 矛盾時，要明確指出，不要悄悄推翻:

> _跟 ADR-0003(swift-nio-ssh,不支援 RSA)矛盾，但值得重新討論，因為……_
