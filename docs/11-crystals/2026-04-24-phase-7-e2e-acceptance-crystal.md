# Decision Crystal: Phase 7 端到端验收

Date: 2026-04-24

## Initial Idea

用户在 `/run-phase` 启动 Phase 7 时补充约束：「按计划验收，不过注意不要污染当前 session 的环境变量。」

## Discussion Points

Phase 7 的所有 smoke / e2e 脚本都需要配置 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` 指向本地 daemon；以及可能涉及 `CC_ROUTER_*` 覆盖配置路径。用户的常用 shell session 中已有 daemon 在跑或可能正在使用 claude CLI，env 污染会导致后续 claude 调用意外走到验收 daemon 或错误 trace 文件。

## Rejected Alternatives

- 在 `scripts/smoke_*.sh` 顶部写 `export ANTHROPIC_BASE_URL=...` — ❌ 被用户拒绝：脚本 `source` 进来会污染父 shell
- 让用户自己 `export` 变量再跑脚本 — ❌ 违反用户补充约束；必须脚本自己管理

## Decisions (machine-readable)

- [D-001] 所有 Phase 7 smoke / e2e 脚本的环境变量必须用 `env VAR=value command ...` 或 `VAR=value command` 单行式传递，禁止 `export`。
- [D-002] 所有 smoke / e2e 脚本必须以独立 `bash scripts/xxx.sh` 调用方式运行（子 shell），文档与 README 里禁止 `source` 这些脚本。
- [D-003] Phase 7 验收期间生成的 trace 写入独立路径（推荐 `$TMPDIR/modelbridge-acceptance/trace-*.jsonl` 或 `/tmp/modelbridge-phase7-trace.jsonl`），不得写入生产默认路径 `~/Library/Application Support/ModelBridge/trace.jsonl`（由 `UserHomeResolver.defaultTraceLogFilePath()` 返回，`TraceLogger.swift:17-19`）。关联 deferred issue #3：现有 12 份 bridge/daemon 测试文件未绑定 `TraceLogger.$overrideFileURL`，测试跑时会污染生产 trace 文件；Phase 7 用机械 wrap（在 test body 外层加 `TraceLogger.$overrideFileURL.withValue(tmp) { ... }`）关闭此 leak，不做 bridge 层注入式重构。
- [D-004] 脚本启动的 daemon 实例必须在脚本退出时 teardown（trap + kill），不得把监听端口遗留给父 shell；用非默认端口（例如 `4318`）避免与用户已跑 daemon 冲突。
- [D-005] 本会话内 Claude 调用 Bash 工具跑验收命令时，同样采用 `VAR=value cmd` 一行式，不 `export`。
- [D-006] Acceptance report 必须附每条 acceptance criterion 的真实命令 + 输出片段（trace 行、curl 响应、test runner 输出），禁止只写 "verified manually"。
- [D-007] Phase 5 deferred #1 #2 #3 在 Phase 7 框架下一并验证：#1 真机 refresh 触发 / #2 count_tokens 精度 ≤10%（若不达标需在 report 里写入 DP-005 Chose B 的实测偏差） / #3 test trace 泄漏 hygiene bug 的 fix 与回归断言。
- [D-008] DP-P6R-003 Routing insights 点击下钻（deferred #4）不纳入 Phase 7；若 feature-reviewer 在 Phase 6 complete 时已把它判为 deferred，Phase 7 只做 "不下钻" 路径的验收。

## Constraints

- 不污染调用者 session env（见 D-001/D-002/D-005）
- 不覆盖生产 trace 文件（见 D-003）
- 不遗留监听端口（见 D-004）

## Scope Boundaries

- IN: 脚本扩展、unit/integration 测试的 env 隔离断言、acceptance report 骨架、Phase 5 #1/#2/#3 deferred 的对应验证、Regression checklist against `docs/scheme3/01-validated-baseline.md`
- OUT: Phase 6 deferred #4（Routing insights 点击下钻）、新的产品功能、重构现有已 green 的代码路径

## Source Context

- Design doc: dev-guide `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md` §Phase 7
- Project brief: `docs/scheme3/00-project-brief.md`
- Validated baseline: `docs/scheme3/01-validated-baseline.md`
- User-stated constraint: 2026-04-24 run-phase checkpoint「按计划验收，不过注意不要污染当前 session 的环境变量」
- Existing deferred issues: `.claude/dev-workflow-state.yml` #1 #2 #3 #4
