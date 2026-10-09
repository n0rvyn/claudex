# Claudex — copy-ready App Store Connect metadata

Status: Recommended draft · verified against current runtime · 2026-10-09

Use English (U.S.) and Chinese (Simplified) localizations. China mainland storefront remains excluded; localization does not change territory availability. Copy only the contents of each code block. No URL placeholders are included.

## Field validation

| Localization | Field | Characters | UTF-8 bytes | Apple limit |
|---|---|---:|---:|---|
| en-US | name | 27 | 27 | 30 characters |
| en-US | subtitle | 29 | 29 | 30 characters |
| en-US | keywords | 84 | 84 | 100 bytes |
| en-US | promotional_text | 164 | 164 | 170 characters |
| en-US | description | 1686 | 1686 | 4000 characters |
| zh-Hans | name | 17 | 25 | 30 characters |
| zh-Hans | subtitle | 16 | 48 | 30 characters |
| zh-Hans | keywords | 38 | 100 | 100 bytes |
| zh-Hans | promotional_text | 67 | 173 | 170 characters |
| zh-Hans | description | 645 | 1573 | 4000 characters |

## en-US

### Name

```text
Claudex - AI Coding Gateway
```

### Subtitle

```text
Local model routing & traffic
```

### Keywords

```text
proxy,cli,terminal,developer,llm,localhost,token,usage,reasoning,streaming,debugging
```

### Promotional Text

```text
Connect your coding workflow through a local gateway. Choose model and reasoning effort, configure Advisor independently, and see recorded requests and token usage.
```

### Description

```text
Claudex connects Claude Code to eligible OpenAI models through a local gateway on your Mac. Keep Claude Code's terminal workflow, tool execution and permission controls while managing model routing in a native menu bar app.

CONNECT YOUR ACCOUNT
Connect ChatGPT in Settings and authorize access in your browser. Choose from models and reasoning efforts advertised for your account, then copy the local connection settings into your terminal.

CONTROL YOUR ROUTING
Choose the upstream model and reasoning effort for your requests. Configure Advisor with its own model and effort for supported advice requests. Advisor keeps its configured effort through tool continuation.

SEE RECORDED ACTIVITY
Start or pause the gateway from the menu bar. Check active requests, the recorded request trend, errors and provider-reported token usage. Open Activity for request outcomes and measured latency. Request counts and model calls are tracked separately; token usage is not remaining account quota.

UNDERSTAND THE CONNECTION
The gateway listens on your Mac's loopback address. Inference requests, including conversation context and tool content, are sent to OpenAI's public Responses API. Authorization data, response replay data and traffic diagnostics are stored locally. This is cloud inference, not an offline model.

REQUIREMENTS
macOS 15.7 or later, Claude Code installed separately, internet access and an eligible ChatGPT account. Model availability and usage limits depend on your account and the provider. Some provider-specific features and tool declarations are unsupported.

Claudex is an independent developer utility and is not affiliated with or endorsed by OpenAI or Anthropic.
```

## zh-Hans

### Name

```text
Claudex - AI 编程网关
```

### Subtitle

```text
本地模型路由、独立顾问与请求监测
```

### Keywords

```text
开发工具,命令行,终端工具,本地代理,令牌统计,推理强度,流式响应,请求诊断
```

### Promotional Text

```text
通过 Mac 本地网关连接编程工作流，自选模型与推理强度，为 Advisor 独立配置模型和强度，并查看已记录的请求、错误及令牌用量。
```

### Description

```text
Claudex 是 Mac 上的本地编程网关，可将 Claude Code 的请求转发至账户可用的 OpenAI 模型。继续使用 Claude Code 的终端工作流，由 Claude Code 执行工具并处理权限，在原生菜单栏应用中管理模型路由。

连接账户
在设置中连接 ChatGPT，通过浏览器授权。选择账户提供的模型与推理强度，再将本地连接配置复制到终端。

控制模型路由
为请求选择上游模型和推理强度。对于支持的顾问请求，可为 Advisor 单独配置模型与强度；工具执行后的续接请求会保留该配置，不会自动提高顾问的推理强度。

查看已记录的活动
在菜单栏启动或暂停网关，查看活动请求、已记录的请求趋势、错误和服务商报告的令牌用量。在“活动”中查看请求结果和实测延迟。请求数与模型调用次数分别统计；令牌用量不代表账户剩余额度。

了解数据流向
网关仅监听 Mac 的本机回环地址。推理请求中的对话上下文、工具内容等会发送至 OpenAI 的公开 Responses API。授权信息、响应重放数据和流量诊断记录保存在本机。模型推理需要联网，并非离线运行。

使用要求
需要 macOS 15.7 或更高版本、单独安装的 Claude Code、互联网连接及符合使用条件的 ChatGPT 账户。可用模型和使用限制取决于账户与服务商。部分服务商专有功能和工具声明不受支持。

Claudex 是独立开发者工具，与 OpenAI 或 Anthropic 无隶属关系，也未获得其背书。
```

## Recommendation and evidence

The name combines the existing Claudex brand with a specific coding-gateway category. The subtitle carries model routing and measured traffic; the description explains the actual Claude Code connection and separately configured Advisor. Generic keyword terms supplement those fields without repeating the brand or promising quota. These choices are relevance judgments, not measured search-volume estimates. Name changes must be submitted in an editable app-version state and reviewed; this is a recommendation, not an ASC change.

The old market.md draft is not an authoritative listing: its private backend, auth.json import, macOS 13, blanket privacy claims and broad compatibility wording conflict with the current implementation. Current claims are grounded in README.md, Sources/CCRouterCore/SIWCBridge.swift, SIWCAdvisor.swift, SIWCTraffic.swift, Claudex/ContentView.swift and the Advisor validation record, plus the parallel source audit. No new inference was used.

Public US bundle lookup returned resultCount 0 for com.90percent.Claudex. This confirms no public record returned by that lookup, not unpublished ASC status or global name availability. Public keywords are unreadable. Existing ASC fields and rejection history were not inspected.

## Apple rules checked

- [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/): name and subtitle each at most 30 characters.
- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/): keywords at most 100 bytes; promo 170 characters; plain-text description 4000 characters. Apple specifies each keyword longer than two characters. UTF-8 counts above include commas, spaces and line breaks.
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): accurate metadata and nonmisleading third-party references. Third-party brands appear only to explain actual interoperability in the description, with an independence statement. They are excluded from the name, subtitle and keyword field.

Current Apple documentation conflicts with the skill reference’s permissive trademark-keyword advice; the official field rules take precedence. The skill’s “promo does not undergo review” and “only name changes require review” statements are not used. Promotional text can be updated without an updated submission, but remains subject to metadata rules. No guarantee of acceptance is implied.

## Recheck after release

Repeat the public macSoftware bundle lookup and the same 20 US discovery terms listed in aso-research-2026-10-09.md. Compare returned metadata and discovery membership with the saved baseline, not synthetic ranking claims. Use ASO_FRESH=1 when invoking the installed skill so its six-hour cache does not replay old data. A valid Mac-specific ranked collector must pass a known Mac-app positive control before any Mac ranking claim. Do not re-use iOS search ranks as Mac ranks. Evaluate conversion through authorized ASC analytics only if later requested.

## Remaining publication dependencies

Verified new marketing/support/privacy URLs are pending the separate norvyn.com migration. Do not invent or publish URL values. Rights clearance and any prior review rejection history remain the owner’s submission checks; current listings are not proof of permission. No code, ASC account, submission or storefront settings were changed.
