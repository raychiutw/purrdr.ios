# Issue tracker:GitHub

本 repo 的 issue 與 spec 都是 GitHub issue(`raychiutw/drover-chat.ios`),一律用 `gh` CLI 操作。

## 慣例

- **建立 issue**:`gh issue create --title "..." --body "..."`。多行內容用 heredoc。
- **讀取 issue**:`gh issue view <number> --json number,title,body,labels,comments`。
- **列出 issue**:`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`,再視需要加 `--label`、`--state` 篩選。
- **把 issue 設成某個 parent 的 sub-issue**:`gh issue create --parent <parent> ...`,或事後 `gh issue edit <parent> --add-sub-issue <child>`(`gh` 2.94+)。較舊的 `gh`:`gh api --method POST repos/<owner>/<repo>/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>`(用 database id,見下方「Blocking」)。不支援 sub-issue 時，在 child 內文最上面寫 `Part of #<parent>`。
- **Blocking**:用 GitHub 原生的 **issue dependencies**,這是標準做法，UI 上看得到。建立時加 `gh issue create --blocked-by <n>,<n> ...`,或事後 `gh issue edit <child> --add-blocked-by <blocker>`(`gh` 2.94+)。較舊的 `gh`:`gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`,其中 `<blocker-db-id>` 是 blocker 的數字 **database id**(`gh api repos/<owner>/<repo>/issues/<n> --jq .id`,_不是_ `#number` 也不是 `node_id`)。不支援 dependencies 時，在 child 內文最上面寫 `Blocked by: #<n>, #<n>`。所有 blocker 都關閉後,ticket 才算解除阻擋。
- **計算未關閉的 blocker**:`gh api repos/<owner>/<repo>/issues/<n> --jq .issue_dependencies_summary.blocked_by`(只算未關閉的;0 代表可以開工)。`gh issue view <n> --json blockedBy` 也會列出已關閉的 blocker,所以要過濾:`--jq '[.blockedBy.nodes[] | select(.state == "OPEN")] | length'`。
- **留言**:`gh issue comment <number> --body "..."`
- **加上／移除 label**:`gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **關閉**:先用 `gh issue comment <number> --body "..."` 說明原因，再 `gh issue close <number>`。對已經關閉的 issue 執行 `gh issue close --comment` 會丟掉留言，但仍然回傳 exit 0。

repo 由 `git remote -v` 推斷;在 clone 裡執行時 `gh` 會自動判斷。

issue 只開在使用者自己的 repo。除非使用者擁有 `mattpocock/skills`(這些 skill 的來源 repo),否則絕不在那裡開 issue。在 fork 裡,`gh` 可能預設指向上游 parent,所以每個 session 第一次 `gh issue create` 之前，先用 `gh repo view --json nameWithOwner` 確認目標;如果不是使用者自己的 repo,先跟使用者確認。

## Pull request 作為 triage 來源

**PRs as a request surface: no.** _(如果本 repo 把外部 PR 當成功能需求處理，改成 `yes`;`/triage` 會讀這個旗標。)_

設成 `yes` 時,PR 走跟 issue 一樣的 label 與狀態，改用對應的 `gh pr` 指令:

- **讀取 PR**:`gh pr view <number>`,再 `gh pr view <number> --comments`(不在 TTY 時 `--comments` 只印留言，不印內文),以及 `gh pr diff <number>` 看 diff。
- **列出要 triage 的外部 PR**:`gh api --paginate 'repos/{owner}/{repo}/pulls?state=open' --jq '.[] | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR") | not) | {number, title, author: .user.login, author_association, labels: [.labels[].name]}'`。
- **留言／label／關閉**:`gh pr comment`、`gh pr edit --add-label`/`--remove-label`、`gh pr close`。

GitHub 的 issue 和 PR 共用同一組編號，所以單獨一個 `#42` 可能是兩者之一：先試 `gh pr view 42`,不是的話再 `gh issue view 42`。

## skill 說「發佈到 issue tracker」時

建立一個 GitHub issue。

## skill 說「取得相關 ticket」時

照上面「讀取 issue」的方式讀。

## Wayfinding 操作

給 `/wayfinder` 用。**map** 是單一一個 issue,底下的 **child** issue 就是各張 ticket。

- **Map**:一個標上 `wayfinder:map` 的 issue,內文包含 Notes / Decisions-so-far / Fog。`gh issue create --label wayfinder:map`。
- **Child ticket**:以 GitHub sub-issue 連到 map 的 issue(見「把 issue 設成某個 parent 的 sub-issue」)。不支援 sub-issue 時，把 child 加進 map 內文的 task list,並在 child 內文最上面寫 `Part of #<map>`。Label:`wayfinder:<type>`(`research`/`prototype`/`grilling`/`task`)。有人認領後,ticket 指派給負責的開發者。
- **Blocking**:見「慣例」裡的 Blocking。
- **Frontier 查詢**:列出 map 底下未關閉的 child(`gh issue list --state open`,限定在 map 的 sub-issue 或 task list),排除還有未關閉 blocker 的(見「計算未關閉的 blocker」,或 `Blocked by` 那行列的 issue 還開著)以及已有 assignee 的;依 map 裡的順序取第一張。
- **認領**:`gh issue edit <n> --add-assignee @me`,這是該 session 的第一個寫入動作。
- **完成**:`gh issue comment <n> --body "<答案>"`,再 `gh issue close <n>`,最後在 map 的 Decisions-so-far 補一行指向它的摘要與連結。
