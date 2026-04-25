# Dashboard Plan A — Surgical UI Fix

**Status:** draft
**Author:** assistant
**Date:** 2026-04-25
**Scope:** Menu bar popover (`Claudex/ContentView.swift`) + design system touch-up
**Estimated diff:** ~60 LOC across 2 files, no AppModel API changes
**Out of scope:** Settings window, AppModel state machine refactor (deferred to Plan B), Routing Insights IA redesign (deferred to Plan C)

---

## Why this plan exists

Screenshot (unauth state) reveals:

1. Footer button label `Authorize` wraps to `Authoriz / e` (clear bug)
2. `Authorize` CTA appears twice (auth card + footer)
3. Primary CTA renders red because system accent leaks through `.borderedProminent`
4. Three empty cards (KPI / Recent / Routing) compete with the only meaningful CTA when unauthorized
5. `routingInsights` displays three identical rows (`→ gpt-5.4 · xhigh`) with `—` metrics

The DesignSystem already has the right tokens. The fix is to use them.

---

## Acceptance criteria

| # | Criterion | How to verify |
|---|-----------|---------------|
| AC1 | `Authorize` footer label renders on a single line at popover width 380 | Visual inspection in light + dark mode |
| AC2 | When `model.requiresAuthAttention == true`, the only CTA visible is the auth card primary button | Visual + grep `chooseSubscriptionAuthFile` call sites |
| AC3 | Auth card primary button uses brand color (slate blue-teal), independent of system accent | Set system accent to Red in System Settings, button stays brand-colored |
| AC4 | KPI / Recent / Routing sections are hidden when unauthorized; visible when `isUpstreamReady == true` | Toggle auth file → sections fade in |
| AC5 | Transition between unauth and authorized states is animated (0.25s ease-in-out) | Visual |
| AC6 | `swift test` passes; existing tests in `ClaudexTests` and `CCRouterCoreTests` unchanged | `swift test --scratch-path /tmp/ClaudexSwiftTest` |
| AC7 | No regressions in Settings window (it shares `MBColor.brand`) | Open Settings, verify buttons render normally |

---

## Tasks

### T1. Lock footer button label to one line

**File:** `Claudex/ContentView.swift`

**Symbol:** `FooterButtonLabel.body` (currently lines 1330–1349)

**Steps:**

1. Append `.lineLimit(1)` and `.fixedSize()` to the trailing chain of `FooterButtonLabel.body`'s root `HStack` so the label measures at intrinsic width and never wraps.

**Verify:**

```bash
xcodebuild build -project Claudex.xcodeproj -scheme Claudex -destination 'platform=macOS'
```

Run app, simulate auth-required state, observe footer.

**Risk:** None — adding `fixedSize` ties the button to its content width. The popover is 380px wide; combined intrinsic widths of `Pause/Start + Copy env + Settings + Quit + spacings` ≈ 330px, leaves ~50px for `Spacer(minLength: 0)`.

**Width-budget note:** This 330px estimate holds only because T4 (below) hides the primary-action button entirely when `!isUpstreamReady`. After T4, the primary label that ever renders here is one of `Pause` / `Start` (max 5 chars). Wider labels from `primaryActionLabel` — `Authorize` (9), `Reauthorize` (11), `Checking` (8), `Fix auth` (8) — never reach this footer codepath because T4 trims the button when auth isn't ready. If T4 is later reverted without revisiting T1, `Reauthorize` would push intrinsic width past the popover boundary.

---

### T2. Pin auth card primary button to brand color

**File:** `Claudex/ContentView.swift`

**Symbol:** `authActionSection` (currently lines 1101–1135)

**Steps:**

1. After `.buttonStyle(.borderedProminent)` on the `Button(action: { model.chooseSubscriptionAuthFile() })`, add `.tint(MBColor.brand)`.
2. Optional: add `.controlSize(.regular)` for explicit size lock.

**Why brand instead of warn:** `MBColor.brand` (slate blue-teal, `DesignSystem.swift:36`) reads as "actionable", not "alarming". `MBColor.warn` (amber) is reserved for `recentFailureCount > 0` and `requiresAuthAttention` headers/dots, where it already appears.

**Verify:** Set macOS System Settings → Appearance → Accent color to Red. Reopen popover — button must remain slate blue-teal.

**Risk:** None — `.tint(MBColor.brand)` is scoped to this Button only.

---

### T3. Replace stacked sections with state-conditional layout

**File:** `Claudex/ContentView.swift`

**Symbol:** `ContentView.body` (currently lines 957–996)

**Current behavior (lines 965–986):**
- `bridgeSection` always renders
- `authActionSection` renders only when `requiresAuthAttention`
- `kpiSection` / `recentSection` / `routingInsightsSection` render unconditionally (the bug)

**Critical gate decision:** Use **two independent conditionals** with **different gates**:
- `if model.requiresAuthAttention { authActionSection }` — appears only when authState is non-nil AND not ready
- `if model.isUpstreamReady { kpiSection; recentSection; routingInsightsSection }` — appears only when authState is `.ready`

**Why two gates instead of `if/else`:** During the launch flicker window `authState == nil`, both `requiresAuthAttention` and `isUpstreamReady` are `false` (per `ContentView.swift:159-166`). With these two independent guards, neither block renders during "Checking" — popover shows only `bridgeSection + footerSection`. An `if/else` on `requiresAuthAttention` would re-create the empty-cards bug during the ~0.5s doctor probe window.

**New behavior:**

```
bridgeSection            (always)
─────────────────────────────────────
if requiresAuthAttention:                  (authState != nil && !ready)
    authActionSection
if isUpstreamReady:                        (authState == .ready)
    kpiSection
    recentSection
    routingInsightsSection
─────────────────────────────────────
footerSection            (always, contents trimmed by T4)
```

State coverage:
- `authState == nil` (Checking): neither block renders → bridge + footer only
- `authState == .authorizationRequired/etc`: auth card only
- `authState == .ready`: KPI + Recent + Routing only

**Steps:**

1. Replace the existing `if model.requiresAuthAttention { authActionSection ... }` block (lines 969–986) with the structure below. Keep all existing `.padding(...)` modifiers attached to each subview **inside** the conditional (so animation propagates to layout shifts):

```swift
Group {
    if model.requiresAuthAttention {
        authActionSection
            .padding(.horizontal, 12)
            .padding(.top, 10)
    }
    if model.isUpstreamReady {
        kpiSection
            .padding(.horizontal, 12)
            .padding(.top, 10)
        recentSection
            .padding(.horizontal, 12)
            .padding(.top, 12)
        routingInsightsSection
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
    }
}
.animation(.easeInOut(duration: 0.25), value: model.isUpstreamReady)
.animation(.easeInOut(duration: 0.25), value: model.requiresAuthAttention)
```

(Two `.animation(...value:)` modifiers because state transitions can flip either flag independently — auth-check resolving to ready vs auth-check resolving to required.)

**Why this is safe:** No section depends on another's presence. `kpiSection` reads `model.recentRequestCount` (defaults to 0); `recentSection` reads `recentTraceLines` (empty array safe); `routingInsightsSection` reads `model.routingInsights` (always non-empty, three rows with placeholders). Hiding them removes noise without breaking data flow.

**Verify:**
- Launch with no `auth.json` → only auth card visible (after probe completes)
- Launch flicker check: during the brief `authState == nil` window, only `bridgeSection + footerSection` should render — no empty KPI cards
- Authorize → KPI / Recent / Routing fade in
- Stop daemon → sections stay (auth still ready, just paused — `isUpstreamReady` remains true)

**Risk:** Low — existing sections render correctly when unhidden; gate semantics verified against `ContentView.swift:159-166`.

**Note on Routing Insights repetition:** After auth, the three rows still show `→ gpt-5.4 · xhigh` with `—` metrics until traffic generates real data. This plan addresses only the "appears in unauth state" issue; condensing the rows to a single line + override badges is deferred to Plan C.

---

### T4. Trim footer when unauthorized

**File:** `Claudex/ContentView.swift`

**Symbol:** `footerSection` (currently lines 1241–1274)

**Current:** Footer always shows `[Authorize/Pause][Copy env][Spacer][Settings][Quit]`. When unauth, `Authorize` here duplicates the auth card CTA.

**New:**

- When `model.isUpstreamReady == false`: footer shows only `[Spacer][Settings][Quit]`
- When `model.isUpstreamReady == true`: footer shows `[Pause/Start][Copy env][Spacer][Settings][Quit]`

**Steps:**

1. Wrap the first two `FooterButton`s (primary action + Copy env) in `if model.isUpstreamReady { ... }`.
2. Keep `SettingsLink` and `Quit` unconditional.

**Why:** Footer becomes "secondary controls only" until the gateway is configured. Reduces CTA duplication. Saves the user from staring at a disabled `Copy env` they can't act on.

**Verify:** Same as T3.

**Risk:** None — `model.toggleDaemon()` and `model.copyEnvSnippet()` are still callable after auth resolves.

---

### T5. Smoke tests

**Steps:**

```bash
swift test --scratch-path /tmp/ClaudexSwiftTest
xcodebuild test -project Claudex.xcodeproj -scheme Claudex \
  -destination 'platform=macOS' -only-testing:ClaudexTests
```

**Expected:** All tests green. None of T1–T4 touch logic — only view structure and modifiers.

**Manual smoke (cannot be automated):**
- Move `~/.codex/auth.json` aside → reopen popover → confirm only auth card visible
- Restore `auth.json` → confirm sections fade in
- Set system accent to Red → confirm auth button stays brand color
- Resize popover (n/a, fixed 380) → confirm footer never wraps

---

## Non-goals (deferred)

| Item | Why deferred | Future plan |
|------|--------------|-------------|
| `DashboardMode` enum on `AppModel` | Conditional renders cover unauth/authed today; enum adds value when adding `.starting`, `.degraded`, `.offline` states | Plan B |
| Routing Insights condensed view | Requires UX call: keep three rows or one "all routes" line + override badges | Plan C |
| Empty state copy refresh | Current copy is functional; rewrite is a content task, not a UI task | Separate doc PR |
| `MBFlowLine` static-state visual polish | Cosmetic; not blocking | Future polish pass |

---

## Rollout

- One commit, one PR, one branch (`ui/dashboard-plan-a`)
- No feature flag — change is purely visual, no routing/auth/runtime logic touched
- Reviewer sanity check: open popover in unauth and auth states, confirm both look intentional

---

## Files touched

| File | Lines changed (estimated) |
|------|---------------------------|
| `Claudex/ContentView.swift` | ~40 |
| `Claudex/DesignSystem.swift` | 0 (no token changes — only consumption) |
| `Tests/...` | 0 |

**Total:** ~40 LOC, single file, single concern (popover visual structure).

---

## Verification
- **Verdict:** Approved
- **Date:** 2026-04-25
- **Cycles:** 2 (initial → revision after S1 flicker-window finding → re-verify approved)
- **Reports:** `.claude/reviews/plan-verifier-2026-04-25-091336.md` (must-revise) → `.claude/reviews/plan-verifier-2026-04-25-091840.md` (approved)
