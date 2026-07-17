# Plan: Monitor lifecycle, thought bubble, and autonomous pet behavior

**Status:** Draft for phased implementation

**Created:** 2026-07-17

**Baseline:** The current working tree, including the in-progress monitor changes.

**Related:** `2026-07-14-001-feat-agent-session-monitor-plan.md`

## Mục tiêu

Thay monitor hiện tại bằng một flow dễ hiểu và đúng lifecycle hơn:

1. Mỗi lần chỉ monitor một provider do user chọn.
2. Main session và sub-agent là các entry riêng; sub-agent biến mất khi nhận
   lifecycle kết thúc.
3. Không cắt danh sách active session ở năm entry.
4. Bubble monitor là thought bubble 8-bit nằm trên hoặc dưới pet, có pixel
   shadow và chuỗi chấm nối từ pet tới bubble.
5. Bubble hiển thị provider, model, status, current job, session name và
   estimated session cost khi provider thực sự cung cấp dữ liệu.
6. Khi không có monitor activity hoặc user interaction, pet có thể tự đi lại
   và chạy animation ngắn như waving, jumping hoặc crying/failed.
7. Ghi nhận nhu cầu dashboard/history/pet editor để thiết kế riêng sau; chưa
   triển khai trong plan này.

## Trạng thái hiện tại

- `MonitorSetupWindowController` dùng checkbox và trả về `[AgentProvider]`, nên
  cho phép bật nhiều provider cùng lúc.
- `AgentSessionKey` chỉ gồm provider và `sessionID`. Claude sub-agent dùng chung
  root `session_id` nhưng có `agent_id` riêng, nên model hiện tại không thể biểu
  diễn đúng main session và nhiều sub-agent đồng thời.
- `ProviderHookConfiguration` chưa đăng ký `SubagentStart` và `SubagentStop`;
  `Task`/`Agent` mới chỉ được diễn giải thành activity của parent session.
- `AgentSessionStore.maximumEntries` và recovery journal đều giới hạn năm
  entry.
- Terminal main session hiện được giữ thêm năm giây rồi xóa.
- Bubble hiện là card cố định `264x112`, đặt bên trái/phải pet và có rail gồm
  tối đa năm status indicator.
- Snapshot hiện có provider, status, model và derived activity; chưa có session
  name, cost, session kind hoặc parent-child relationship.
- `AnimationPlayback` chỉ random các frame trong idle row. Ngoài jumping, các
  animation khác không có one-shot completion contract; overlay chưa có idle
  scheduler để tự đi hoặc tự diễn action.

## Nguồn dữ liệu provider

- Claude Code có lifecycle chính thức `SubagentStart`/`SubagentStop`; payload có
  root `session_id`, `agent_id` và `agent_type`. Đây là nguồn authoritative cho
  việc thêm/xóa sub-agent, không suy luận từ `PreToolUse`/`PostToolUse` của
  `Agent` tool. Xem [Claude Code hooks](https://code.claude.com/docs/en/hooks).
- Hook lifecycle thông thường không cung cấp estimated cost đầy đủ. Cost/tokens
  chỉ được lấy từ local metrics đã có, theo mô hình Claude OpenTelemetry; không
  dùng hoặc sửa Claude status line. Claude OTEL cung cấp
  `claude_code.cost.usage` và `claude_code.token.usage`, có thể correlate bằng
  `session.id` và `model`. Xem
  [Claude Code monitoring](https://code.claude.com/docs/en/monitoring-usage).
- Cost là estimate của provider, không phải billing authority. Bubble và
  dashboard tương lai phải ghi rõ đây là estimated cost.

## Quyết định thiết kế đã chốt cho plan

1. **Confirmed: single-provider nghĩa là user chọn đúng một provider trong
   Claude/Codex/Cursor, không hard-code Claude.** Runtime chỉ nhận event của
   provider đang active; muốn đổi provider phải chuyển selection.
2. **“All sessions” nghĩa là toàn bộ live sessions của provider đang active.**
   Không có count cap năm entry. Terminal entries vẫn được dọn, và stale
   recovery data vẫn có age-based pruning. Persistent history thuộc dashboard
   tương lai.
3. **Confirmed: sub-agent có identity riêng và giữ trạng thái `Finished` trong
   hai giây trước khi biến mất.** Key logic sẽ gồm provider, root session ID và
   scope (`primary` hoặc `subagent:<agent_id>`). `SubagentStop` chỉ kết thúc
   child entry tương ứng; parent entry vẫn tiếp tục.
4. **Bubble hiển thị một session tại một thời điểm nhưng browse được toàn bộ
   live sessions.** Không tạo một indicator cho mỗi session vì chiều cao sẽ
   tăng vô hạn; dùng previous/next + `current/total` và một window indicator
   nhỏ quanh selection.
5. **Confirmed: telemetry chỉ dùng PetRunner-owned hooks hoặc read-only local
   metrics/OTEL đã có.** Không tích hợp status line, không sửa thêm provider
   settings/env/collector, và không đọc raw prompt, assistant message hoặc tool
   result.
6. **Confirmed: provider và status luôn hiển thị; các bubble field còn lại do
   user chọn khi setup.** Model, current job, session name và estimated cost
   không được chọn hoặc không có dữ liệu sẽ bị ẩn hoàn toàn, không render dòng
   placeholder `—`.
7. **Interaction priority:** user drag/click/hover > active monitor status >
   autonomous idle action. Autonomous behavior dừng ngay khi monitor event hoặc
   user interaction xuất hiện.
8. **Monitor/UI triển khai macOS trước.** Autonomous animation/physics phải được
   giữ tương đương trên macOS và Windows vì đây là behavioral contract chung.
9. **Confirmed: autonomous behavior bật mặc định.** Menu paw có toggle
   `Autonomous Pet` để user tắt hoặc bật lại bất cứ lúc nào.
10. **Confirmed: idle interval random từ 10 đến 20 giây.** Timer reset sau mỗi
    user interaction, monitor activity hoặc autonomous action hoàn tất.
11. **Confirmed: autonomous action weights ban đầu là walk 40%, wave 25%, jump
    25% và cry/failed 10%.** Random source phải injectable để test chính xác.
12. **Confirmed: setup hỏi user bằng selectable options về bubble fields.**
    Model, current job, session name và estimated cost mặc định đều được chọn;
    user có thể bỏ chọn trước khi enable monitor. Provider và status vẫn bắt
    buộc.

## Data model mục tiêu

`AgentSessionKey` cần phân biệt root và child scope:

```text
provider + rootSessionID + scope(primary | subagent(agentID))
```

`AgentSessionSnapshot` dự kiến bổ sung:

```text
kind: primary | subagent
parentKey: optional
agentType: optional
sessionName: optional, sanitized and bounded
estimatedCostUSD: optional non-negative decimal
updatedAt: monotonic ordering/expiry input
```

`NormalizedAgentEvent` cần lifecycle intent rõ ràng thay vì chỉ status:

```text
upsert(snapshot fields) | finish(session key, gracePeriod) | remove(session key)
```

Việc biểu diễn child completion riêng giúp `SubagentStop` đưa đúng child sang
`Finished`, schedule removal sau hai giây và không làm terminal parent session.

## Phase 1 — Correct lifecycle and single-provider monitor

### P1.1 — Viết failing tests cho lifecycle mới

- Add sanitized fixtures/tests cho Claude `SubagentStart` và `SubagentStop`.
- Test hai sub-agent cùng root session có hai key riêng.
- Test stop một child chuyển đúng child sang `Finished`, giữ nó hai giây rồi
  xóa mà không ảnh hưởng parent hoặc sibling.
- Test hơn năm live sessions được giữ và browse đầy đủ.
- Test event từ provider không được chọn bị bỏ qua.

**Files:**

- `Tests/PetRunnerCoreTests/ProviderHookConfigurationTests.swift`
- `Tests/PetRunnerCoreTests/AgentMonitorTests.swift`
- `Tests/PetRunnerCoreTests/AgentMonitorBridgeContractTests.swift`
- `Tests/PetRunnerCoreTests/AgentMonitorRecoveryJournalTests.swift`

**Gate:** `test: swift test --filter AgentMonitorTests` và các focused suites
liên quan phải fail đúng expectation mới trước khi sửa implementation.

### P1.2 — Mở rộng event/key/store contract

- Thêm primary/sub-agent scope và explicit remove intent.
- Bump bridge envelope protocol; decoder chấp nhận v1 primary events trong thời
  gian chuyển tiếp.
- Bỏ count truncation trong live store và recovery journal.
- Recovery journal giữ toàn bộ active entries trong existing 15-minute recovery
  window, loại terminal/remove event và malformed/private-permission failures.
- Giữ selection ổn định khi entry khác update hoặc bị remove.

**Files:**

- `Sources/PetRunnerCore/AgentMonitor.swift`
- `Sources/PetRunnerCore/AgentMonitorBridgeContract.swift`
- `Sources/PetRunnerCore/AgentMonitorRecoveryJournal.swift`
- focused tests từ P1.1

**Gate:** `test: swift test --filter AgentMonitorTests`

**Gate:** `test: swift test --filter AgentMonitorRecoveryJournalTests`

**Gate:** `test: swift test --filter AgentMonitorBridgeContractTests`

### P1.3 — Normalize provider sub-agent lifecycle

- Đăng ký Claude `SubagentStart` và `SubagentStop` hooks.
- Chỉ lấy `session_id`, `agent_id`, `agent_type` và safe derived metadata.
- Không forward `last_assistant_message` hoặc transcript path.
- `SubagentStart` tạo child entry; `SubagentStop` phát child-finish intent với
  grace period hai giây.
- Giữ `PostToolUse Agent` như activity update của parent, không dùng nó để xóa
  child.
- Các provider chưa có equivalent lifecycle giữ capability `subagents=false`.

**Files:**

- `Sources/PetRunnerCore/ProviderHookConfiguration.swift`
- `Sources/PetRunner/AgentMonitorBridge.swift`
- `Tests/PetRunnerCoreTests/ProviderHookConfigurationTests.swift`

**Gate:** `test: swift test --filter ProviderHookConfigurationTests`

### P1.4 — Enforce exactly one selected provider

- Đổi setup UI từ checkbox sang radio/single selection.
- Thêm phần `Bubble fields`: provider và status được bật/khóa bắt buộc; user có
  thể chọn model, current job, session name và estimated cost.
- Present optional fields as setup question/options with all four checked by
  default, not as a hidden preference applied without confirmation.
- Persist ordered field selection trong PetRunner preferences và cho phép mở
  setup lại để thay đổi.
- Preference mới là `monitorProvider: AgentProvider?`.
- Legacy preference có đúng một provider thì migrate; zero hoặc nhiều provider
  thì yêu cầu user reconfigure, không tự chọn ngầm.
- Khi user enable một provider, transaction remove PetRunner-owned hooks khỏi
  provider khác rồi install provider đã chọn; không đụng third-party hooks.
- Bridge/app rejects normalized events không khớp provider đang active.
- Repair và disable chỉ thao tác đúng owned entries, giữ rollback behavior hiện
  tại.

**Files:**

- `Sources/PetRunner/MonitorSetupWindowController.swift`
- `Sources/PetRunner/Preferences.swift`
- `Sources/PetRunner/AppDelegate.swift`
- `Sources/PetRunnerCore/ProviderHookInstaller.swift`
- provider configuration/installer tests

**Gate:** `test: swift test --filter ProviderHookConfigurationTests`

**Gate:** `test: swift test --filter ProviderHookInstallerTests`

### P1.5 — Phase 1 integration proof

- Run one Claude main session with two parallel sub-agents.
- Verify each child appears once, shows `Finished` for two seconds, then
  disappears after its own `SubagentStop`.
- Verify more than five active sessions remain navigable.
- Verify events from a second provider do not appear.
- Disable monitor and confirm only PetRunner-owned hooks are removed.

**Gate:** `test: swift test`

**Gate:** `manual: build/run app and verify the five lifecycle scenarios above`

Stop after Phase 1, write `/handoff`, and request approval before Phase 2.

## Phase 2 — Telemetry contract and 8-bit thought bubble

### P2.1 — Telemetry feasibility gate

For the selected provider, prove a read-only hook or local-metrics source for:

- provider name
- model name
- status
- sanitized current job/activity
- explicit session name
- estimated cumulative session cost

Rules:

- Do not add, replace or wrap Claude `statusLine`.
- Do not mutate provider telemetry environment, settings or collector config.
- If OTEL/local metrics are already available, consume only metric name,
  numeric value, timestamp, `session.id` and `model`.
- Ignore and never persist account UUID, user/email identity, prompt/event
  content, tool details or unrelated OTEL attributes.
- Do not parse prompt/assistant text or tool results.
- Do not claim child-specific cost when provider only supplies root cumulative
  cost; child bubble shows root estimate with a clear `SESSION EST.` label or
  `—`.
- If no matching local metric exists, keep hook-derived fields working and
  leave the unsupported metric unavailable.

**Gate:** `manual: document one verified metadata source per displayed field for the selected provider`

### P2.2 — Add bounded telemetry types

- Add sanitized bounded `AgentSessionName`.
- Add non-negative decimal estimated cost with stable formatting (`$0.00`,
  `<$0.01`, or `—`).
- Preserve last known model/name/cost when a lifecycle event omits them.
- Never persist raw provider payloads.
- Recovery journal stores only the bounded display fields.
- Snapshot có thể giữ metadata hợp lệ dù field đang bị ẩn; visibility là user
  preference, không phải data-ingestion rule.

**Files:**

- `Sources/PetRunnerCore/AgentMonitor.swift`
- `Sources/PetRunnerCore/AgentMonitorBridgeContract.swift`
- `Sources/PetRunnerCore/AgentMonitorRecoveryJournal.swift`
- corresponding tests

**Gate:** `test: swift test --filter AgentMonitorTests`

**Gate:** `test: swift test --filter AgentMonitorBridgeContractTests`

### P2.3 — Pure thought-bubble placement and geometry

- Replace left/right placement with centered-above preference.
- If above does not fit the current screen visible frame, place below.
- If neither fully fits, choose the side with more space and clamp bubble and
  tail inside that screen.
- Above variant: dots grow from pet top toward bubble bottom.
- Below variant: dots grow from pet bottom toward bubble top.
- Use three pixel dots, small to large, with distinct above/below coordinates.
- Add a hard-edged offset pixel shadow; no blurred `NSShadow`.
- Keep geometry in PetRunnerCore so above/below, clamping and tail-dot order are
  deterministic unit tests.

**Files:**

- `Sources/PetRunnerCore/SessionBubbleLayout.swift`
- `Tests/PetRunnerCoreTests/SessionBubbleLayoutTests.swift`

**Gate:** `test: swift test --filter SessionBubbleLayoutTests`

### P2.4 — Render the new bubble and session navigation

- Replace stacked card/rail look with an 8-bit thought bubble.
- Always render provider and status. Render model, session name, current job
  and estimated cost only when selected and available.
- Omit unavailable/unselected rows completely; recompute bubble height while
  keeping a stable width and the same above/below placement rules.
- Use truncation/ellipsis at the sanitized type boundary; do not let AppKit
  labels silently overflow.
- Keep previous/next controls and `current/total`.
- Show only a fixed-size indicator window around the selected entry so an
  unbounded active-session count cannot grow the panel.
- Keep accessibility text with the full bounded field values.
- Bubble follows pet movement/resizing and recomputes above/below placement on
  screen changes.

**Files:**

- `Sources/PetRunner/SessionBubblePanelController.swift`
- `Sources/PetRunner/StackedBubbleBackgroundView.swift` (rename during
  implementation if the new responsibility is clearer)
- `Sources/PetRunner/AppDelegate.swift`
- layout tests

**Gate:** `test: swift test --filter SessionBubbleLayoutTests`

**Gate:** `manual: compare above and below variants at normal pet size on each screen edge, including shadow and three-dot tail`

### P2.5 — Phase 2 integration proof

- Verify selected fields render and unavailable/unselected fields are absent.
- Verify a long session name/job/model cannot escape the bubble.
- Verify all active sessions remain browsable when count exceeds five.
- Verify bubble switches above/below while pet moves between screen edges and
  displays.

**Gate:** `test: swift test`

**Gate:** `manual: run the telemetry, overflow, navigation, and placement scenarios above`

Stop after Phase 2, write `/handoff`, and request approval before Phase 3.

## Phase 3 — Autonomous idle actions and movement

### P3.1 — Define a deterministic autonomy state machine

Add a platform-neutral policy with injectable clock/random source:

```text
idle wait -> choose action -> perform one-shot action -> cooldown -> idle wait
```

Mỗi idle wait chọn ngẫu nhiên trong khoảng 10-20 giây. User interaction hoặc
monitor activity hủy action pending và bắt đầu một khoảng chờ mới khi pet thực
sự trở lại idle.

Candidate actions:

- short walk to a safe target using running-left/right rows: 40%
- wave: 25%
- jump: 25%
- cry/failed animation: 10%

Transitions must be interruptible by user interaction or an active monitor
session. Every action returns to idle; no action loops forever.

**Files:**

- `Sources/PetRunnerCore/Animation.swift`
- a focused Core autonomy type if the state machine does not fit animation
  playback cleanly
- `Tests/PetRunnerCoreTests/AnimationTests.swift`
- focused autonomy tests

**Gate:** `test: swift test --filter AnimationTests`

### P3.2 — macOS autonomous movement integration

- Schedule actions only while pet is visible, grounded, not dragged/resized and
  has no active monitor session.
- Pick movement targets inside the current screen visible frame with safe
  margins.
- Cancel autonomous motion immediately on click, hover, drag, resize, monitor
  event or screen-layout change.
- Persist only the resulting pet position, not pending timers/actions.
- Enable autonomous behavior by default and provide an `Autonomous Pet` menu
  preference to disable or re-enable it.

**Files:**

- `Sources/PetRunner/OverlayPanelController.swift`
- `Sources/PetRunner/AppDelegate.swift`
- `Sources/PetRunner/Preferences.swift`
- `Sources/PetRunner/StatusMenuController.swift`
- Core physics/animation tests as needed

**Gate:** `test: swift test --filter PhysicsTests`

**Gate:** `test: swift test --filter AnimationTests`

**Gate:** `manual: observe every action, interruption priority, and screen-bound clamping`

### P3.3 — Windows parity

- Port the same autonomy policy and action priority to WPF.
- Keep animation cycle counts, random ranges and movement safety semantics
  aligned with macOS.
- Do not add monitor UI to Windows as part of this phase unless separately
  approved.

**Files:**

- `windows/PetRunner.Core/Animation.cs`
- `windows/PetRunner.Windows/OverlayWindow.cs`
- `windows/PetRunner.Tests/AnimationTests.cs`
- `windows/PetRunner.Tests/PhysicsTests.cs`

**Gate:** `test: dotnet run --project windows/PetRunner.Tests/PetRunner.Tests.csproj`

### P3.4 — Phase 3 integration proof

**Gate:** `test: swift test`

**Gate:** `test: npm test`

**Gate:** `manual: macOS idle soak test covering no-action, each action, monitor interruption, pointer interruption, screen edge, and multi-display cases`

**Gate:** `manual: Windows smoke test after the .NET suite passes`

Stop after Phase 3 and write `/handoff`.

## Deferred discussion — Dashboard, history, and pet editor

Do not implement this section in Phases 1-3. Create a separate design after the
monitor fields and lifecycle are stable.

### Product requirements to retain

- Session cost history by provider/model/session/time range.
- Session detail with status timeline and safe derived job labels.
- Pet selection and editing/management from a dedicated UI.
- Settings for autonomous actions, intervals, allowed actions and pet position.
- No raw prompt, assistant response, command, file path or tool result in
  history by default.

### Decisions to discuss later

1. Native AppKit/SwiftUI dashboard versus localhost web UI.
2. Meaning of “edit pet”: preferences/selection only, manifest editing, or
   visual spritesheet tooling.
3. Storage format and retention policy: SQLite versus bounded JSON/event log.
4. Whether cost history is provider estimate only or reconciled with an
   authoritative billing API.
5. If localhost is selected: loopback-only binding, per-launch auth token,
   CSRF/origin rules, lifecycle, and browser-launch behavior.

Initial recommendation: prefer a native dashboard because PetRunner already is
a native desktop process and it avoids exposing a local HTTP surface. Revisit
only if web-based pet editing materially reduces implementation cost.

## Open questions before implementation

None. Product choices required for Phases 1-3 are confirmed. Dashboard and pet
editor decisions intentionally remain deferred to their separate design.

### Marketplace setup follow-up

The future `/pet-runner:setup` skill asks the same provider and bubble-field
questions as selectable options, with all optional fields selected by default.
It must call a supported PetRunner configuration/open-setup command; the AI
must not edit UserDefaults or provider settings directly. This belongs to the
experimental marketplace plugin plan, not Phases 1-3 here.

## Change management

- Implement one phase at a time; do not mix dashboard work into monitor or
  autonomy changes.
- Tests are written before behavior changes and are not weakened to pass.
- At each phase boundary, stop, summarize with `/handoff`, and wait for approval
  before continuing.
- The repository currently has overlapping uncommitted monitor changes. Before
  Phase 1 implementation, re-check the exact diff and preserve those changes;
  do not reset or overwrite them.
