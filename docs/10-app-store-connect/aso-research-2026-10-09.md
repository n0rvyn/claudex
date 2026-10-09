# Claudex — ASO research evidence

Status: Public-data research completed; Mac search rankings not established · 2026-10-09

## Exact skill and discovery

Applied [ASO-Research SKILL.md](/Users/norvyn/.codex/plugins/cache/indie-toolkit/apple-dev/1.25.0/skills/aso-research/SKILL.md), plus its trademark-by-field.md and appstore-data-apis.md references. Located through the available executor skill catalog and filesystem discovery under the project, ~/.codex/skills, ~/.agents and ~/.codex/plugins. Project .agents does not exist. Read repository AGENTS.md, existing docs/10-app-store-connect/market.md, README.md and current Advisor validation. Skill is present; no substitute skill was used.

The skill script was copied unchanged to /tmp/claudex-aso-20261009/aso.py to keep its cache inside writable task storage. Initial sandbox network lookups returned null even for a known listing; these were discarded. Successful public-network lookups followed. No credentials, ASC login, paid panel, installs, new accounts or inference were used.

## Public listing baseline

GET https://itunes.apple.com/lookup?bundleId=com.90percent.Claudex&country=us&entity=macSoftware returned resultCount=0. A known macSoftware control, Model Proxy id6760217982, returned a valid listing. Therefore the empty Claudex result is usable as an endpoint result, but not proof of unpublished ASC state or global brand availability. Existing authenticated ASC metadata and keywords remain unknown.

## 20-term US discovery matrix

Method: Apple public Search API, country=us, entity=macSoftware, limit=50. Counts are returned records within that requested limit, NOT total market size, search volume, difficulty or on-device search ranks. Mac-compatible iOS apps can appear in the catalog. The 50-result row is capped. This is a discovery baseline; no ordinal is promoted into a Mac ranking claim.

| Term | Returned records | First returned examples |
|---|---:|---|
| Claudex | 1 | Token Gauge |
| LLM gateway | 40 | Cumbersome: AI LLM API Client, Private LLM - Local AI Chat, XiFan LLM Gateway Status Ball |
| API gateway | 42 | HTTPBot: API & HTTP Client, Cumbersome: AI LLM API Client, Model Proxy - LLM API Gateway |
| AI gateway | 50 | Microsoft Copilot, Gab AI, Locally AI by LM Studio |
| model routing | 27 | inRoute – Intelligent Routing, Karing, Ducky Model Editor |
| model proxy | 42 | Model Proxy - LLM API Gateway, Shadowrocket, Happ - Proxy Utility |
| coding assistant | 44 | AI Coding Assistant : Code AI, C.AI: AI Chatbot Assistant, LingCode |
| developer tools | 38 | Apple Developer, TestFlight, Developer Tools - Tooly |
| local proxy | 45 | Shadowrocket, Happ - Proxy Utility, Clash - Rule Based Proxy |
| localhost | 43 | io1: Publish Localhost, Localhost Port Scanner, WebSSH - Sysadmin Toolbox |
| CLI | 43 | Termius: SSH Client & Terminal, Todo CLI: To Do List, CLI Pulse |
| terminal | 42 | Terminux: SSH Client, Termius: SSH Client & Terminal, Termial – AI SSH Terminal |
| token usage | 47 | Usage for Claude, AI Token Usage Tracker, Token Usage for Claude |
| traffic monitor | 42 | NetTraffic - Speed Monitor, Process Traffic Monitor, Device Monitor² |
| reasoning effort | 22 | ArguMap - Map Arguments, ArguMap Pro - Map Arguments, Assocy - The Smart Notebook |
| AI coding | 48 | Microsoft Copilot, C.AI: AI Chatbot Assistant, AICoding |
| streaming | 48 | Friendly Streaming Browser, Amazon Prime Video, Easy Streaming |
| loopback | 23 | Audio Capture, Sound Recorder, XME LOOPS, Playback |
| 模型路由 | 4 | Model Proxy - LLM API Gateway, MCP Beast: Local Gateway, 模型枢纽 ModelHub |
| 编程助手 | 45 | Moss - AI Chat & Genie Chatbot, AI Pro: Private AI Assistant, 智谱清言-AI智能体定制视频通话智能搜索深度推理问答聊天助手 |

## Listings retrieved directly

| Listing | Subtitle | Seller | Version / update | US rating count |
|---|---|---|---|---:|
| [Model Proxy - LLM API Gateway](https://apps.apple.com/us/app/id6760217982) | Token usage for Claude Code | 志杰 张 | 2.5 / 2026-08-29 | 0 |
| [MCP Beast: Local Gateway](https://apps.apple.com/us/app/id6773765736) | ChatGPT, Claude, Codex, Cursor | SwiftLee | 1.2.0 / 2026-09-14 | 0 |
| [Token Gauge](https://apps.apple.com/us/app/id6795682556) | Track your token usage limits | Morten Iversen | 1.1.1 / 2026-09-11 | 0 |

Lookups used entity=macSoftware; subtitles came from the skill’s viewSoftware endpoint. Rating count 0 is the returned US value, not worldwide popularity. These fields were observed on 2026-10-09; public listings are not proof of rights clearance or reproducible review acceptance.

Model Proxy is the closest functional comparison: vendor routing and usage monitoring. MCP Beast is an adjacent local gateway centered on MCP connections. Token Gauge is an adjacent account-limit monitor. Claudex’s positioning should emphasize the actual coding gateway, account-discovered model/effort and independent Advisor configuration, without borrowing general-vendor support, web-search bridging or quota promises.

## Ranked collector and autocomplete limitation

The installed skill’s US configuration is 143441-1,29 with an iOS App Store user agent and clientApplication=Software. Its forced Facebook positive control returned 250 results. Its proxy search returned 249 records, with VPN-oriented apps in the first results. This establishes a working iOS collector, not valid Mac ranks. A Mac-specific collector was not established; no Mac ranking matrix or Claudex rank is claimed.

Autocomplete raw order, from that same iOS-configured endpoint, is retained as adjacent evidence only:

- proxy: proxy browser; proxypin; proxy master; proxy; proxypics; proxy vpn· for iphone &amp; ipad; proxyman; proxy server; proxyvote; proxy share.
- coding: coding game; coding learning; coding c++; coding x: learn to code; coding practice; coding; coding for kids; coding ai; coding game free; coding games for kids.
- Claudex: empty. Proxy/coding nonempty controls validate retrieval; empty hints do not quantify demand. These results cannot establish Mac autocomplete availability.

## Rules and conflicts resolved

[Apple platform field rules](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/) explicitly prohibit other app/company names in keywords and specify 100 bytes. [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) section 2.3.7 states subtitles should not reference other apps. This overrides the skill reference’s permissive subtitle/keyword conclusions. Recommended name/subtitle/keywords use no third-party brands. Descriptive interoperability references do not establish permission; rejected-metadata history was not supplied.

No search-volume, difficulty, conversion or ranking estimate is given. Metadata relevance recommendations are qualitative. Broad proxy terms pull VPN results; broad traffic terms pull network monitors; loopback pulls audio products. These ambiguities favor the narrower coding-gateway category in the title and explicit operational context in the description. Chinese localization is retained for Chinese-speaking users in supported territories; no China mainland research or storefront changes were made.

## Reproduction and recheck

Public lookup: https://itunes.apple.com/lookup?bundleId=com.90percent.Claudex&country=us&entity=macSoftware

Discovery template: https://itunes.apple.com/search?term=API%20gateway&country=us&entity=macSoftware&limit=50; substitute every term in the matrix. Compare membership/counts cautiously; this endpoint does not establish Mac search ranking.

Installed skill metadata check: call aso.live(bundle_id="com.90percent.Claudex", store="us", entity="macSoftware") from the copied library. Use ASO_FRESH=1 for viewSoftware/search/hints rechecks. Do not use its default software entity for Mac live lookup.

Raw public responses and scripts: /tmp/claudex-aso-20261009/. Persistent compact baseline: aso-discovery-2026-10-09.json. Copy-ready fields and validated counts: metadata-copy-2026-10-09.md / .json. Once a Mac-specific ranked collector passes a known Mac positive control, collect that separate baseline and compare the same terms after release.

## Remaining blockers

No public Claudex record or authenticated ASC baseline was available. Mac-specific ranked/autocomplete evidence is not verified. Metadata prior-rejection history is unknown. New norvyn.com URLs await the parallel migration; none were invented. These limit ranking/approval conclusions, not delivery of the five requested localized text fields.
