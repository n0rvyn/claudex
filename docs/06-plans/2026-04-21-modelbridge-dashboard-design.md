---
type: design
status: active
tags: [macos, dashboard, settings, monitoring, swiftui]
refs:
  - docs/00-session-brief.md
  - docs/scheme3/20-implementation-blueprint.md
  - docs/06-plans/2026-04-21-modelbridge-productization-plan.md
---

# ModelBridge Dashboard Design

## Goal

Turn `ModelBridge` from a functional menu bar utility into a polished macOS app with:

- a real-time menu bar monitoring dashboard
- a single-window tabbed Settings experience that acts as the operational control center
- stronger visual hierarchy without weakening runtime clarity

## Information Architecture

### Menu Bar

The menu bar panel is the live monitoring surface. It answers:

- Is the daemon healthy?
- Is upstream auth healthy?
- Are requests succeeding?
- What has happened recently?

Sections:

1. Hero health card
2. Core metric cards
3. Runtime activity cards
4. Live trace feed
5. Compact action row

### Settings

Settings is a single-window, tabbed control surface. Tabs:

1. `Overview`
2. `Gateway`
3. `Claude Code`
4. `Upstream`
5. `Diagnostics`
6. `Advanced`

## User Journeys

### Journey: Monitor Current Health
1. User opens the menu bar panel and immediately sees daemon, upstream auth, and last-request state in the hero card.
2. User scans the metric row to understand traffic, latency, and reliability.
3. User checks runtime activity and live trace only if something looks off.

### Journey: Configure Claude Code Forwarding
1. User opens Settings and goes to `Claude Code`.
2. User reviews the exact `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` snippet.
3. User copies the env snippet and uses it with `Claude Code CLI`.

### Journey: Investigate a Runtime Problem
1. User opens Settings and goes to `Diagnostics`.
2. User sees recent request outcome, error reasons, connector activity, and trace location.
3. User opens or copies diagnostics without needing terminal spelunking.

## UX Assertions

| ID | Assertion | Verification |
|----|-----------|-------------|
| UX-001 | The menu bar opens into a dashboard, not a plain menu list. | Check `ModelBridge/ContentView.swift` for card-based sections and a scrollable dashboard layout. |
| UX-002 | The first visible region communicates current health before detailed logs. | Check for a hero card above metric and feed sections. |
| UX-003 | Settings is a tabbed single window with operational tabs, not a long doctor page. | Check `DoctorSettingsView` for `TabView` and the six tab labels. |
| UX-004 | The Claude Code setup path is copyable without manual editing. | Check for a dedicated `Claude Code` tab and copy actions using `envSnippet`. |
| UX-005 | Diagnostics expose recent request outcome, connector activity, and trace location in one place. | Check the diagnostics tab content for trace, connector, error, and recent-event sections. |

## Visual Design Decisions

| Page/Component | Info Hierarchy | Density | Key Color Decisions |
|----------------|---------------|---------|---------------------|
| Menu bar hero | Primary: health state; Secondary: endpoint/model; Tertiary: support detail | Compact | Deep graphite surface with cool blue highlight and semantic success/warning/error badges |
| Metric cards | Primary: key values; Secondary: trend/support labels | Compact | Neutral elevated cards with semantic accent rings and tinted icons |
| Activity/feed cards | Primary: latest activity; Secondary: detailed trace lines | Standard | Muted card surfaces; failures use coral accents; trace uses low-contrast terminal styling |
| Settings overview | Primary: current state; Secondary: quick actions; Tertiary: guidance | Standard | Reuse dashboard semantic colors with calmer backgrounds |
| Settings forms | Primary: editable controls; Secondary: file paths/status; Tertiary: hints | Standard/comfortable | Light semantic grouping; dangerous actions isolated with warning tone |

## Component Structure

- `AppModel` remains the source of truth for daemon state, config state, and diagnostics.
- `TraceDiagnostics` grows to include real dashboard metrics:
  - recent request count
  - recent success/failure count
  - requests per minute
  - p50/p95 latency
  - last request outcome
  - recent error reasons
- `RouterConfigurationStore` gains write APIs for Settings-driven changes.
- `ContentView` becomes the dashboard composition root.
- `DoctorSettingsView` becomes the tabbed settings composition root.

## Edge Cases

- When no trace exists yet, metric cards fall back to “No recent traffic”.
- When upstream auth is missing, hero state shows warning instead of pretending healthy.
- When configuration changes require restart, the UI states that explicitly and offers restart actions.
- When the trace path is unreadable, diagnostics stay functional and show the file-path problem directly.
