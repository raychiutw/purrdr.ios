# 跨聊天「需要你」通知原型(#526)

拋棄式設計稿，不合併。線上畫布：https://claude.ai/artifact/K3cFxXs9Kro4auK7Fvrk9J

- 問題：拿掉返回鈕旁的數字徽章(兩行標題被擠窄)後，在聊天裡怎麼知道別的聊天需要你。
- 方案：N1 返回鈕小點、N2「⋯」小點＋選單、N3 輸入框上方提示列、N4 頂部橫幅、N5 長按返回鈕。
- **使用者 2026-11-24 選定 N4**:頂部玻璃橫幅(點了直接跳到那個聊天，不計時自動消失，✕ 或上滑收起，不放「›」)＋返回鈕小點＋聊天列表「需要你」置頂與「剛剛」。
- HIG 依據:Accessibility「Minimize use of time-boxed interface elements」;Notifications「Handle notifications gracefully when your app is in the foreground … subtly inserting new data into the current view」(見 docs/research/apple-hig-drover-chat.md)。

`Main.dc.html` 是 Design canvas 的 artboard(需要畫布的 support.js 才能跑),`canvas.json` 是畫布索引與筆記。
