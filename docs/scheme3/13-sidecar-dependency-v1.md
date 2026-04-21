# 辅助产品面依赖 v1

Date: 2026-04-20

## 1. 文档定位

本文件只回答一个问题：

- 当前非交互主路径要不要依赖 `/backend-api/...`

这里不讨论交互 TUI、apps 或其他未验证入口。

## 2. 当前适用范围

本页所有结论只适用于以下范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- `features.apps=false`
- 主推理面通过本地 `/responses` 透明转发到真实订阅上游
- 辅助产品面通过本地 blocker 返回统一 `404` 或统一 `500`

## 3. 当前实验

固定命令骨架：

```text
codex exec --skip-git-repo-check \
  -c 'features.apps=false' \
  -c 'chatgpt_base_url="http://127.0.0.1:<backend-port>/backend-api"' \
  -c 'openai_base_url="http://127.0.0.1:<responses-port>"' \
  --json '<prompt>'
```

其中：

- `/responses` 侧保持真实转发成功
- `/backend-api/...` 侧分别跑两种 blocker：
  - `404`
  - `500`

## 4. 已验证结果

| backend-api mode | 观测到的 sidecar 请求 | 主路径结果 | 当前结论 |
| --- | --- | --- | --- |
| `404` | `GET /backend-api/plugins/featured?platform=codex`、`GET /backend-api/plugins/list`、`POST /backend-api/codex/analytics-events/events` | `item.completed = SIDECAR`；`turn.completed` | 当前观测到的 sidecar 请求全部 `404` 时，当前非交互主路径仍然完成 |
| `500` | `GET /backend-api/plugins/list`、`GET /backend-api/plugins/featured?platform=codex`、`POST /backend-api/codex/analytics-events/events` | `item.completed = SIDECAR500`；`turn.completed` | 当前观测到的 sidecar 请求全部 `500` 时，当前非交互主路径仍然完成 |

当前样本还确认：

- 两组实验里，`codex exec` 都继续走 `/responses`
- websocket `GET /responses` 仍然全部 `404`
- 主路径 HTTP `POST /responses` 都得到 `200`

## 5. 当前结论

对当前范围，已经可以写成结论：

- 当前观测到的 `/backend-api/plugins/*` 与 `/backend-api/codex/analytics-events/events`
- 不是当前非交互主路径的 hard dependency
- 它们在 `404` 和 `500` 两种失败下都不会阻止本轮 `/responses` 完成

因此，当前非交互主路径可以表述成：

- 必需：
  - `/responses`
- 当前非必需：
  - `/backend-api/plugins/list`
  - `/backend-api/plugins/featured`
  - `/backend-api/codex/analytics-events/events`

## 6. 当前还不能扩大解释的内容

当前还不能写死：

- 交互 TUI 是否也不依赖 `/backend-api/...`
- `features.apps=true` 是否也不依赖 `/backend-api/...`
- 未来还会不会出现新的 sidecar 路径

## 7. 证据位置

- `/backend-api` blocker logs:
  - `/tmp/backend-api-404/events.jsonl`
  - `/tmp/backend-api-500/events.jsonl`
- `/responses` forward logs:
  - `/tmp/responses-forward-8797/events.jsonl`
