# Rink Reports — Status Report & Fix Plan

**Prepared:** 2026-07-17
**Scope:** Live production system behind `www.rinkreports.com` — Next.js app (Vercel project `rink-reports-5-6`) + Supabase Postgres backend (project `bqbdgwlhbhabsibjgwmk`).
**Method:** Fresh direct inspection today of the live database (policies, functions, migrations table, row counts), Supabase security & performance advisors (re-run 2026-07-17), and Vercel deployment history. Compared against the 2026-07-01/02 baseline in `RINK-REPORTS-360-AUDIT.md`. The app source repo (`KellyJ386/Rink-Reports-5-6`) was again not directly readable from this session; code-level statements are reconstructed from deployment commit metadata and verified against the live database wherever possible.

---

## 1. TL;DR

**The app is healthy and improving fast — but its most important security fixes are stuck in the pipeline, not in production.**

1. **Migration drift is the headline problem.** The production database has migrations applied through **179**. The repo's `main` branch has carried migration **180** (the `information_requests` open-INSERT fix + `rate_limit_counters` policy cleanup) since it merged on **2026-07-08 — nine days ago — and it has never been applied to prod.** Verified directly today: `information_requests_insert` is still `WITH CHECK (true)` for `anon` in the live database. Merging a migration to `main` deploys the *app* via Vercel but does **not** touch the database; there is currently no step that applies migrations to prod, and this is the second time drift has appeared (migration 181 was previously applied out-of-band in the dashboard and back-ported to the repo afterward).
2. **Two confirmed HIGH security fixes are sitting in an open PR (#276, pushed 2026-07-16).** I verified both underlying vulnerabilities are live in prod right now: (a) the `communication_recipients_select` RLS policy has an unscoped `has_module_admin_access('communications')` branch — any facility's communications admin can read **every** tenant's recipient rosters and delivery/read/ack metadata; (b) per the PR, `setEmployeeModuleOverride`/`setRoleModuleAction` let a facility admin self-grant Admin Center access and mint peer admins. With one facility today the cross-tenant blast radius is zero, but both must land before facility #2.
3. **Leaked-password (HIBP) protection is *still* disabled** — flagged in the July 2 audit, attempted via `config.toml` (turns out it can't be set there), documented in the launch runbook, but never actually switched on. It is a one-click dashboard setting.
4. **Security posture otherwise improved markedly:** advisor findings down from 63 → 46; 6 of the 7 anon-callable RPC functions were locked down (only `check_rate_limit` remains, likely intentionally for the public form); the mutable-`search_path` finding is fixed; the scheduling publish-lock bypass is fully closed (I verified the four-leg trigger function live in prod); the stale `mfo-rink-reports-2-7` Vercel project is gone, resolving the dangling-domain concern.
5. **Adoption is essentially flat.** Two weeks of high engineering velocity (~12 PRs: security hardening, full WCAG/ADA pass, launch runbook, landing-page rework) against near-zero usage growth: still 1 facility, 5 users, 103 employees; daily reports still 2 submissions; accidents and air quality still 0. Bright spot: Communications got its first-ever real rows (2 alerts, 2 acknowledgements). The constraint on this product right now is not engineering — it's getting the pilot facility using the modules that are already built.

---

## 2. Scorecard vs. the July 2 Roadmap

| # | July 2 "Now" item | Status 2026-07-17 |
|---|---|---|
| 1 | Decide/narrow `information_requests` anon INSERT | ⚠️ **Half-done.** Decision made (it's a public form; policy tightened to `WITH CHECK (status = 'new')` + rate-limited via migration 177's public-form rate limit). Merged as migration 180 on Jul 8 — **but never applied to prod; live policy is still `WITH CHECK (true)`.** |
| 2 | Revoke EXECUTE on 7 anon-exposed functions | ✅ **6 of 7 done.** Only `check_rate_limit` remains anon-callable — plausibly intentional (it backs the public information-request form's rate limiting). Needs a one-line intent decision, not necessarily a fix. |
| 3 | Pin `search_path` on `schedule_swap_set_expiry` | ✅ Done — finding no longer appears; verified `schedule_shifts_publish_lock` (same hardening family) pins `search_path` in prod. |
| 4 | Enable leaked-password (HIBP) protection | ❌ **Still disabled.** PR #269 tried `password_hibp_enabled` in `config.toml`; PR #271 correctly removed it (not a valid CLI key — hosted-project setting only) and documented the dashboard path in the runbook. The actual toggle was never flipped. |
| 5 | Confirm `mfo-rink-reports-2-7` domain binding inert | ✅ **Resolved** — the project no longer exists in the Vercel team; only `rink-reports-5-6` and a new, unrelated `max-facility-website-12-19-25` (created ~Jul 10) remain. |
| 6 | FK covering indexes | ❌ Not done (advisor now counts 57 unindexed FKs, was 56). Still low-urgency at this scale. |
| 7 | Auth DB connections → percentage-based | ❌ Not done (still absolute 10). |
| 8 | Drop deprecated `role_module_permission_defaults` | ❌ Not done (table still present, 20 rows). |
| 9 | Real usage in dormant modules | ⚠️ Communications saw first use (2 alerts / 2 acks). Accident Reports and Air Quality remain at 0 rows. |
| 10 | Land PR #245's remaining phases (migrations 165/166) | ✅ Migrations 165/166 are in the applied list; the audit workstream continued through PRs #268–#276. |

---

## 3. Engineering Activity Since July 2 (~12 PRs, reconstructed from Vercel deployments)

- **PR #276** (open, preview-deployed 2026-07-16) — *Security hardening: privilege escalation, cross-tenant RLS leak, injection/rate-limit gaps.* Carries migration 182. **Both HIGH findings verified still-live in prod today** (see §5).
- **PR #277** (open, preview-deployed 2026-07-16) — Landing-page refactor: 10 module cards, SaaS positioning, "Max Facility LLC" branding, brand tokens.
- **PR #275** (merged 2026-07-11 — **current production deploy**) + **PR #274** — Full ADA/WCAG pass: Radix-based focus-trapped mobile nav, label associations, contrast fixes, keyboard-accessible accident-report body diagram and rink diagram, toast theming; module accent tokens darkened for light mode.
- **PR #268** (merged 2026-07-09) — App scan: security hardening, dependency refresh, E2E CI, repo hygiene.
- **PRs #269–#273** (merged 2026-07-08/09) — Launch-runbook workstream: two-day launch runbook; migration 180 (advisor follow-ups: `information_requests` tighten + `rate_limit_counters` explicit policy); migration 181 closing the final publish-lock leg (draft→published via `updateGridShift`'s client-supplied `status`) — notable because the fix was found **already applied out-of-band to prod** and had to be back-ported to the repo; SCHED-181 regression tests; `config.toml` HIBP correction.

**Pattern:** disciplined, audit-driven hardening with real regression coverage, but two process gaps keep recurring: (a) database changes and app deploys travel on different rails and nobody/nothing applies merged migrations to prod; (b) security work is landing in the repo faster than it reaches the production database.

---

## 4. Live Usage (deltas Jul 2 → Jul 17)

Still **1 facility, 5 users, 103 employees**.

| Module | Jul 2 | Jul 17 | Delta |
|---|---|---|---|
| Ice Depth | 19 sessions / 377 measurements | 20 / 382 | +1 / +5 — still the only habitually-used module |
| Employee Scheduling | 7 shifts | 10 shifts | +3; swaps/time-off/availability still 0 |
| Ice Operations | 4 submissions | 5 | +1 |
| Communications | 0 rows in all 10 tables | **2 alerts, 2 acknowledgements** | **First-ever real usage** |
| Daily Reports | 2 submissions | 2 | flat (vs. 51 templates / 506 checklist items configured) |
| Incident / Refrigeration | 1 / 1 reports | 1 / 1 | flat |
| Accident / Air Quality | 0 | 0 | still never used |
| `information_requests` | 0 | 0 | no abuse of the open policy to date |

**Read:** engineering output is ~10x ahead of adoption. The July 2 open question — "are dormant modules awaiting rollout, or is something blocking adoption?" — is now two weeks more pressing and still unanswered.

---

## 5. Security Posture (advisors re-run 2026-07-17)

**46 findings (45 WARN, 1 INFO) — down from 63 on July 2.**

### Confirmed live vulnerabilities (verified by direct DB inspection today, not just advisors)

1. **`information_requests` open INSERT** — `information_requests_insert` is `WITH CHECK (true)` for `anon, authenticated` in prod. The fix exists (migration 180, merged Jul 8) and simply hasn't been applied. Zero rows to date, so unexploited.
2. **Cross-tenant Communications leak** — `communication_recipients_select` contains a bare `has_module_admin_access('communications')` OR-branch with no `facility_id` scoping. Fix is migration 182 in open PR #276. Blast radius today: zero (one tenant), but this is exactly the class of bug that must be gone before facility #2.
3. **Facility-admin → Admin Center privilege escalation** (from PR #276's description; app-code level, not directly verifiable from the DB): `setEmployeeModuleOverride` / `setRoleModuleAction` only call `requireAdmin()`, so a facility admin can grant the admin/admin cell and mint peer admins. Fix is in PR #276.
4. **HIBP leaked-password protection disabled** (Auth setting, one click, three reports in a row now).

### Findings that are fine or near-fine

- `check_rate_limit` anon-EXECUTE — the one survivor of the anon-RPC lockdown; almost certainly intentional (public form rate limiting). Document intent or wrap it; not urgent.
- 42 `SECURITY DEFINER` functions executable by `authenticated` — the standard Supabase helper pattern, accepted as intentional in the July audit.
- `rate_limit_counters` RLS-no-policy INFO — deliberate deny-all; migration 180 adds the explicit `service_role` policy that clears the linter (also waiting on the migration apply).

### Performance (161 findings, all INFO — unchanged in character)

103 unused indexes (ignore at this volume), 57 unindexed FKs (batch into one migration pre-GA), Auth pool still absolute-10 (flip to percentage in settings).

---

## 6. Fix Plan

### P0 — this week (all are hours, not days)

| # | Action | Owner/effort | Detail |
|---|---|---|---|
| 1 | **Merge PR #276** | Review + merge | Closes the two live HIGHs (privilege escalation, cross-tenant recipients leak) plus injection/rate-limit gaps. It's already preview-deployed and green. |
| 2 | **Apply pending migrations to prod** (180, 181, 182 post-merge) | `supabase db push` / `supabase migration up` against the linked project | 181's function body is already live out-of-band and the migration is an idempotent `create or replace`, so re-applying is safe and fixes the bookkeeping. **Afterwards, verify:** `information_requests_insert` shows `WITH CHECK (status = 'new')`, `rate_limit_counters` has the `service_role` policy, `communication_recipients_select` is facility-scoped, and the advisor WARNs clear. |
| 3 | **Enable HIBP leaked-password protection** | Dashboard → Auth → Passwords (or Management API `PATCH /v1/projects/{ref}/config/auth`) | Third report flagging this; it cannot be set from `config.toml`, someone has to click it. |
| 4 | **Close the migration-deploy gap permanently** | CI change in `Rink-Reports-5-6` | Add a GitHub Action on merge-to-`main` that runs `supabase db push` (project ref + access token as secrets), or at minimum a required launch-runbook checklist step. Drift has now happened in both directions (repo ahead of prod: 180; prod ahead of repo: the out-of-band 181). The repo already has schema-drift CI comparing migrations to a snapshot — extend the same rigor to *prod vs. repo*: a scheduled job diffing `supabase_migrations.schema_migrations` against `supabase/migrations/**` and failing loudly on mismatch. |
| 5 | **Decide `check_rate_limit` anon-EXECUTE intent** | 1-line decision | If intentional (public form), add a schema comment saying so and accept the advisor WARN; if not, revoke like the other six. |

### P1 — before onboarding facility #2

6. **Merge PR #277** (landing page/SaaS positioning) — the marketing front door for going beyond the pilot.
7. **FK covering indexes** — one migration for the 57 flagged columns.
8. **Auth pool → percentage-based** in project settings.
9. **Drop `role_module_permission_defaults`** (deprecated since migration 77, still holding 20 rows) after confirming the admin/roles UI no longer reads it.
10. **Adoption push, not code:** run the pilot facility through Accident Reports and Air Quality end-to-end (real or structured UAT), and keep Communications momentum going. Modules with 0 production rows have had zero real-world validation of their write paths — this is now the largest unknown-risk surface in the product.
11. **Answer the standing product question:** target date/customer for exiting single-facility pilot. Every P1 item's urgency keys off this.

### P2 — scale-readiness (unchanged from July 2)

12. Revisit the 103 unused indexes only once real multi-tenant query patterns exist.
13. DB-level enforcement (or documented app-layer rationale) for the `module_area_permissions.area_id` polymorphic reference.

---

## 7. Bottom Line

Two weeks ago the risk was *unfixed vulnerabilities*. Today the risk is *fixed vulnerabilities that aren't deployed*. The team's find-fix-test loop is working well — publish-lock is fully closed, anon RPC surface is nearly eliminated, accessibility got a genuine deep pass — but the last mile (apply migrations to prod, flip the HIBP toggle, merge the security PR) keeps not happening. Items P0-1 through P0-3 are collectively under an hour of work and would clear every known live security issue; P0-4 makes sure this class of gap can't silently recur.
