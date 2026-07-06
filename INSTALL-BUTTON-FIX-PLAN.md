# Fix Plan — "Install Rink Reports" Button Not Functional

> **STATUS UPDATE (2026-07-05): IMPLEMENTED — awaiting push/PR into the app repo.**
> The fix is fully built and verified against `KellyJ386/Rink-Reports-5-6` (commit `aeaa25a`,
> branch `claude/install-button-fix` in a session clone). This session had read-only access
> to that repo, so the commit could not be pushed from here; the complete change is preserved
> as [`patches/0001-fix-install-banner-ios.patch`](patches/0001-fix-install-banner-ios.patch)
> in this repo. To land it: in a session with write access to Rink-Reports-5-6, run
> `git checkout -b claude/install-button-fix && git am patches/0001-fix-install-banner-ios.patch`
> (or just ask Claude to apply the patch and open the PR).
>
> What shipped, per the phases below: Phase 0 found the PWA foundation already solid
> (manifest + icons + service worker + Android `beforeinstallprompt` handling all present) —
> the defect was iOS-only. Phase 2's platform-aware banner is implemented: expandable
> device-correct steps on iOS Safari (iPhone vs iPad share-button location), an
> "open in Safari" card with Copy Link on non-Safari iOS browsers (the user's screenshot
> case), unchanged native install on Chromium, a 14-day dismissal cool-down, an explicit
> apple-touch-icon, and PostHog instrumentation. Verified with 16 new unit tests plus an
> 18-check Playwright pass against the production build (all green).

**Prepared:** 2026-07-05
**Reported symptom:** On mobile (iPhone screenshot, `www.rinkreports.com`), the "Install Rink Reports" banner at the bottom of the landing page does nothing when tapped. Only the ✕ (dismiss) works.
**Where the fix lands:** The app source repo (`KellyJ386/Rink-Reports-5-6`) — this docs repo carries the plan only. This session could not read that repo or fetch the live site (network policy), so Phase 0 below re-verifies the assumptions before code changes.

---

## 1. Diagnosis (from the screenshot + how PWA installs work)

The banner in the screenshot is the app's **iOS fallback install prompt**. Its copy reads:

> *Install Rink Reports — Tap the Share button below, then choose "Add to Home Screen".*

That tells us the app already knows iOS cannot install a PWA programmatically — Safari/WebKit has no `beforeinstallprompt` event and no API to trigger installation. So on iOS the card is **instructions-only by design**: nothing on it is meant to be tappable except ✕. Three distinct problems compound into "the button doesn't work":

1. **It looks like a button but isn't one.** A bright green icon + bold title in a card reads as tappable. Users tap it, nothing happens, and they reasonably report it as broken. This is a UX defect even when everything else works.

2. **The instructions are wrong for the browser in the screenshot.** The screenshot is **not standard Safari** — the bottom toolbar has an "Ask" AI button (an AI/alternative iOS browser or in-app browser). Two consequences:
   - The copy says "Tap the Share button **below**" — but in this browser the share icon is in the **top** address bar, not a bottom toolbar. The user is told to look somewhere the button doesn't exist.
   - Many third-party/in-app iOS browsers don't offer "Add to Home Screen" in their share sheet at all (WebKit-based browsers gained it in iOS 16.4+, but support is inconsistent and in-app webviews generally lack it). Following the instructions can dead-end entirely.

3. **Possibly missing PWA prerequisites (unverified — Phase 0).** Even in real Safari, "Add to Home Screen" only produces a true installed app (standalone window, own icon, splash) if the site ships a valid web app manifest with `display: "standalone"`, proper icons, and (for a robust experience) a registered service worker. If any of these are missing, A2HS silently creates a plain bookmark — which also gets reported as "install doesn't work."

There is also an Android/desktop side to check: a *functional* install button on Chrome/Edge/Android requires capturing the `beforeinstallprompt` event and calling `.prompt()` on click. If the same instructional card is shown there, it's broken on those platforms too.

---

## 2. Fix Plan

### Phase 0 — Reproduce & audit the current state (½ day)
*(Requires access to the `Rink-Reports-5-6` repo and the live site.)*

1. Run a Lighthouse **PWA/installability audit** against `https://www.rinkreports.com` (Chrome DevTools → Application → Manifest shows exact installability failures).
2. Verify what actually ships today:
   - `manifest.webmanifest` linked from `<head>`? Contains `name`, `short_name`, `start_url`, `scope`, `display: "standalone"`, `theme_color`, `background_color`, and **192px + 512px icons (incl. a `purpose: "maskable"` variant)**?
   - `<link rel="apple-touch-icon">` (180×180) and `<meta name="apple-mobile-web-app-capable" content="yes">` present?
   - Service worker registered and controlling the page?
3. Locate the install-banner component in the source; document its current platform detection, what (if anything) its tap handler does, and where/whether it handles `beforeinstallprompt`.
4. Test matrix snapshot of today's behavior: iOS Safari (iPhone + iPad), iOS Chrome, an in-app browser (e.g. from a messaging app), Android Chrome, desktop Chrome.

### Phase 1 — PWA foundation (only what Phase 0 finds missing) (½–1 day)

- Complete/correct the manifest per the checklist above. `start_url` should land signed-in users somewhere sensible (e.g. `/` with auth redirect), and `scope` must cover the whole app.
- Add Apple-specific tags (`apple-touch-icon`, `apple-mobile-web-app-capable`, `apple-mobile-web-app-status-bar-style`, `apple-mobile-web-app-title`).
- Ensure a service worker is registered (for Next.js, `next-pwa`/`@serwist/next` or a minimal hand-rolled SW is fine — offline support can stay out of scope; installability is the goal).

### Phase 2 — Rebuild the banner as a platform-aware install component (1–2 days)

One component, four render modes, chosen at runtime:

| Environment | Detection | Behavior |
|---|---|---|
| **Already installed** | `matchMedia('(display-mode: standalone)')` or `navigator.standalone` | Never render the banner. |
| **Chromium (Android/desktop)** | `beforeinstallprompt` fired | Capture the event (`preventDefault`, stash it). Render a **real Install button** → `deferredPrompt.prompt()`; on `appinstalled`, hide permanently. |
| **iOS Safari** | iOS UA + Safari (not standalone) | Instructional card, but: make the whole card a tap target that opens a small sheet with **illustrated, device-correct steps** (iPhone: share button in bottom toolbar; iPad: top-right). Use the exact share glyph. |
| **iOS non-Safari / in-app browsers** | iOS UA + `CriOS`/`FxiOS`/`EdgiOS`/webview heuristics | Don't show unusable A2HS steps. Show *"To install, open this page in Safari"* with a **Copy Link** button (iOS offers no programmatic 'open in Safari'). |

Shared behavior:
- Tapping anywhere on the card does *something* on every platform — no dead-looking button, ever.
- Dismissal (✕) persists in `localStorage` with a cool-down (e.g. don't re-show for 14–30 days); `appinstalled` hides it forever.
- Delay first appearance until meaningful engagement (e.g. 2nd visit or 30s on page) rather than immediately covering the landing page.

### Phase 3 — Verification (½ day)

- Re-run Lighthouse installability → passes.
- Manual matrix: iOS Safari iPhone/iPad (A2HS produces a standalone app that opens to `start_url`, auth session behaves), iOS Chrome (gets Safari redirect card), Android Chrome + desktop Chrome/Edge (native prompt appears and installs), already-installed state (no banner).
- Add lightweight instrumentation: log banner impressions, `prompt()` outcomes (`accepted`/`dismissed`), and `appinstalled` events so adoption is measurable.

### Acceptance criteria

1. No platform ever shows a tappable-looking element that does nothing.
2. On Chromium browsers, tapping **Install** triggers the native install dialog.
3. On iOS Safari, following the card's steps yields a standalone home-screen app (not a bookmark tab).
4. On iOS non-Safari browsers, the user is told to open Safari instead of being given impossible steps.
5. Banner respects installed-state and dismissal cool-down.

---

## 3. Blockers / asks

- **Repo access:** implementation must happen in `KellyJ386/Rink-Reports-5-6`, which this session cannot read. Start the fix session from that repo (or add it to the session) so Phases 0–2 can be executed.
- **Live-site access:** this environment's network policy blocked fetching `rinkreports.com`, so the Phase 0 manifest/service-worker audit could not be pre-run here; it is the first task of implementation.
