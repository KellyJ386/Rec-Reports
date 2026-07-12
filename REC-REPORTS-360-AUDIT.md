# Rec Reports — 360° Audit & Roadmap

> **Product name:** the product is **Rec Reports**. Its live infrastructure still carries the legacy "Rink Reports" branding — the `rinkreports.com` domain, the Vercel project `rink-reports-5-6`, the Supabase project "Rink Reports 5-6", and the GitHub repo `Rink-Reports-5-6`. Those literal identifiers are left unchanged below because they are real, in-use names; only the product name has been corrected.

**Prepared:** 2026-07-01 · **Verification passes:** 2026-07-02 (advisors re-run, usage counts re-queried, deployment history refreshed) · **2026-07-12** (security & performance advisors re-run against live — significant security movement, deltas noted inline in §4–§5 and §8)
**Scope:** Live production system behind `www.rinkreports.com` — Next.js app (Vercel project `rink-reports-5-6`) + Supabase Postgres backend (project `bqbdgwlhbhabsibjgwmk`, Postgres 17.6).
**Method:** Direct inspection of the live database schema/data (140 tables), Supabase security & performance advisors, and Vercel deployment history (~25 most recent merged PRs). The application source code itself lives in a separate GitHub repo (`KellyJ386/Rink-Reports-5-6`) that this audit session did not have read access to — findings about code-level behavior below are inferred from commit messages, schema comments, and live data, not from reading the source directly. Anything in that category is flagged as such.

---

## 1. Executive Summary

Rec Reports is a multi-tenant, facility-operations platform for ice rinks (daily checklists, incident/accident reporting, refrigeration & air-quality monitoring, ice-depth tracking, employee scheduling, internal communications, role-based permissions). The schema is unusually mature for a pre-launch product: 140 tables, 165 migrations worth of iteration, deliberate immutability/audit-trail patterns (snapshot columns, append-only change logs, 24-hour edit windows), and a genuine multi-tenant permission model (roles → module permissions → per-area permissions).

Engineering velocity is high — the last ~25 merged PRs alone cover a full scheduling-grid rebuild (drag/drop, keyboard accessibility, publish-lock governance), a new Playwright E2E suite, an 8-chapter training/onboarding manual, and two rounds of RLS/RPC security hardening.

The system is currently running with **1 facility, 5 users, 103 employee records** — this reads as an active pilot/onboarding deployment, not yet multi-customer production. Several fully-built modules (Communications, Air Quality, Accident Reports, Employee Invites/Certifications) have **zero rows of real usage**, meaning they're built and deployed but not yet validated by real workflows.

Two security items need attention this week: an anon-writable `information_requests` table with an unconditionally-permissive INSERT policy, and 7 seed/trigger functions still callable directly by unauthenticated `anon` role via PostgREST RPC (a prior PR already fixed some of this pattern, but not all of it).

---

## 2. What's Built (Module Inventory)

| Module | Tables | Real usage (rows) | Read as |
|---|---|---|---|
| **Daily Reports** | 6 | 51 templates / 506 checklist items configured, only **2 submissions** | Fully configured, barely exercised |
| **Incident Reports** | 6 | 1 report | Configured, minimal use |
| **Accident Reports** | 6 | **0 reports** | Built, unused |
| **Refrigeration** | 8 | 1 report, 32 captured values | Configured, light use |
| **Air Quality** | 8 | **0 reports** | Built, unused |
| **Ice Operations** | 9 | 4 submissions, 0 circle-check results | Configured, light use |
| **Ice Depth** | 8 | **19 sessions, 377 measurements** | **Most-used module by far** |
| **Employee Scheduling** | 15 | 7 shifts, 212 job-area assignments, 0 swaps/time-off/availability rows | Config-heavy, live use just starting |
| **Communications** | 10 | **0 rows across all 10 tables** | Fully built, completely unused |
| **Permissions/Roles/Employees** | 8 | 5 roles, 103 employees, 140 user_permissions rows | Actively maintained |
| **Facility Documents, Retention, Export Settings** | 3 | 0 rows | Built, unused |

**Takeaway:** the backend has clearly been engineered ahead of adoption — most modules are production-ready schema-wise but have never processed a real report. Ice Depth is the only module with genuine day-to-day usage patterns. This is a normal shape for a pre-launch pilot, but it means the untested modules (Communications, Air Quality, Accident Reports) carry more unknown risk than the audit's clean schema suggests — they haven't been exercised by real data yet.

---

## 3. Recent Engineering Activity (last ~25 merged PRs)

Reconstructed from Vercel deployment metadata (commit messages), most recent first:

- **PR #245** (open, very active as of 2026-07-02) — A deep code-level audit of the app itself, run in phases: Phase 0 inventoried 84 routes, ~600 interactive elements, 38 forms, and 31 modals; Phase 1 fanned out five audit agents (navigation, buttons/forms, admin-config propagation, RBAC/security, offline/state) and triaged **3 HIGH, 10 MEDIUM, 26 LOW, 4 INFO** findings; Phase 3 is landing fixes. Notable fixes already pushed on this branch: migration 165 closes a **HIGH facility-admin → cross-tenant super-admin escalation** (profile-update trigger now gates `is_super_admin`/`id` changes to super-admins only), migration 166 adds a module-access gate to `facility_documents` SELECT, open-redirect-safe `redirectTo` on login, several facility-scoping fixes on delete/swap actions, and threshold-fallback alignment for Ice Depth. This PR complements the present report with the code-level depth this audit couldn't reach (see Method note above).
- **PRs #241–#244** (merged 2026-07-01/02) — Moved `citext`/`pg_trgm` extensions out of the `public` schema (ultimately done manually in the dashboard — Supabase owns extensions as `supabase_admin`, so a migration can't do it — with PR #244 documenting the permanent repo/prod divergence), plus deferred discovery cleanups (job-area docs, brand typography, HIBP notes).
- **PR #240** (merged) — Closed a publish-lock bypass: `createGridShift` could INSERT a shift with `status='published'` directly, skipping the two-person publish approval flow. Fix removes client-supplied `status` on create and extends the DB trigger to also fire `BEFORE INSERT`. The PR #245 audit independently re-verified this regression as fixed.
- **PR #239** — Revoked anon/authenticated EXECUTE on several internal seed/trigger functions exposed via PostgREST RPC (see §4 — partially effective; more functions remain exposed).
- **PR #238** — Added a full Playwright E2E suite (10 spec files: auth, role permissions, daily reports, ice ops, incidents/accidents, refrigeration/air quality, ice depth, admin console, multi-tenant isolation, quality checks) across 7 staged role accounts.
- **PR #237** — Removed a redundant meta-chip header from the Daily Reports form (dead-code cleanup).
- **PR #236** — Authored an 8-chapter training/onboarding manual, master manual, role-based onboarding paths, print-ready PDFs, and a from-zero "duplicate this software" runbook.
- **PR #235** — Scheduling grid: keyboard-accessible drag-and-drop (`@dnd-kit`), editable shift times in the assign popover, operating-hours advisory, and visual/interaction lock-down of published shifts.
- **PR #234** — Default shift-template end time aligned to staff-availability defaults (09:00–17:00).
- **PR #233** — Scheduling grid: position filter (job-area chips) and expandable multi-shift day cells.

**Pattern:** the team (human + Claude-assisted commits) has been alternating between feature depth on Employee Scheduling and hardening passes on the database security model — a healthy rhythm, but it means scheduling is the newest/least-battle-tested surface area (matches the 0-swap/0-time-off usage data above).

---

## 4. Security Findings (from live Supabase advisors)

**As of the 2026-07-12 re-run: 46 advisor entries total — 45 WARN, 1 INFO, 0 ERROR** (down from 63 at the 2026-07-02 pass). The drop reflects real hardening: 6 of the 7 anon-executable functions were revoked, the mutable `search_path` on `schedule_swap_set_expiry` was fixed, and the intentional-pattern SECURITY DEFINER count fell 52 → 42. Two of the four "needs action" items below remain open; status is marked inline.

### Needs action

1. **`information_requests` — unconditionally permissive INSERT policy, open to `anon`.** ⚠️ **STILL OPEN (2026-07-12).**
   Policy `information_requests_insert` has `WITH CHECK (true)` for roles `anon, authenticated` — anyone on the internet can insert rows with no validation. Table currently has 0 rows, so no data has been affected, but this is either (a) an intentional public "request more info" form, in which case it should be paired with rate-limiting and a narrower column set, or (b) an oversight. **Needs a decision, not just a fix** — confirm intent before changing.

2. **Anon-executable RPC functions — ✅ mostly resolved (2026-07-12): 6 of 7 revoked, 1 remains.** The audit flagged 7 functions callable by unauthenticated `anon` via `/rest/v1/rpc/<name>`. As of 2026-07-12 only **`check_rate_limit(p_bucket, p_identifier, p_max, p_window_seconds)`** is still anon-executable; the other six (`enforce_incident_witnesses_cap`, `seed_default_facility_air_quality_config`, `seed_default_facility_modules`, `tg_seed_facility_air_quality_config`, `tg_seed_facility_modules`, `trg_seed_facility_dropdown_options`) have had EXECUTE revoked. `check_rate_limit` is the rate limiter itself but takes caller-supplied args with no internal authorization gate, so the same fix pattern still applies: revoke `EXECUTE` from `anon`/`authenticated`/`public`, keep it callable from `SECURITY DEFINER` context.

3. **`function_search_path_mutable` — `schedule_swap_set_expiry`** ✅ **FIXED (2026-07-12):** no longer flagged by the advisor; the function now has a pinned `search_path`. *(Original finding: it resolved unqualified object names using the caller's `search_path`, a schema-hijacking vector.)*

4. **Leaked-password protection is disabled** in Supabase Auth (HaveIBeenPwned check). ⚠️ **STILL DISABLED (2026-07-12).** One-click enable in Auth settings; no code change needed. *(PR #243 touched HIBP-related docs but the Auth setting itself remains off.)*

### Not action items (verified as intentional)

- **Functions flagged as "authenticated can execute SECURITY DEFINER"** (`current_user_id`, `has_module_access`, `is_facility_admin`, `scheduling_claim_open_shift`, etc.) — **42 as of 2026-07-12, down from 52** at the audit. This is the standard Supabase pattern for permission-check/RPC helper functions that need `SECURITY DEFINER` to read across RLS boundaries safely. These are almost certainly intentional; a full one-by-one audit would need source access to confirm each function internally re-validates `auth.uid()`/facility scope, which the app's schema comments suggest is the established convention (e.g. `current_employee_id()`, `is_super_admin()`).
- **`rate_limit_counters` — RLS enabled, no policies.** Flagged INFO, but the table's own comment states this is deliberate: "Reachable ONLY through `public.check_rate_limit()`; RLS is enabled with no policies so direct anon/authenticated access is denied." Correct pattern, no action needed.

---

## 5. Performance Findings (from live Supabase advisors)

**161 advisor entries as of 2026-07-12, all INFO level** (162 at the audit — essentially unchanged; no errors/warnings, all "could be tighter," not "something's broken"):

- **103 unused indexes** (105 at audit) across ~58 tables — expected at this data volume (most tables have single-digit-to-low-hundreds row counts); not a real cost yet, but worth revisiting once production traffic and real query patterns exist. Don't drop these pre-emptively — they were sized for expected access patterns, not current pilot data.
- **57 foreign keys without a covering index** (56 at audit) — the standard next-tier finding after unused indexes; matters more once join volume grows (e.g., `audit_logs.actor_employee_id`, `schedule_shifts.template_origin_id`, various `*_followup_notes.employee_id`). Low urgency at current scale, worth batching into one migration before general availability.
- **1 `auth_db_connections_absolute` finding** — Auth server connection pool is configured as an absolute count (10) rather than a percentage of the pool, so vertically scaling the Postgres instance won't automatically scale Auth throughput. Cheap fix in Supabase project settings before any real load-testing.

---

## 6. Technical Debt Already Flagged in the Schema Itself

The team has been disciplined about leaving breadcrumbs — several tables carry their own deprecation notes:

- **`role_module_permission_defaults`** — comment: *"DEPRECATED as of migration 77. Source of truth is now `public.user_permissions`. Resolver functions no longer read this table. Drop after admin/roles page is migrated."* Confirm the admin/roles UI has actually cut over, then drop this table.
- **`module_area_permissions.area_id`** is explicitly a soft/unenforced reference ("no FK is enforced here because the target table varies by module... callers must validate area_id belongs to the same facility before inserting") — worth a defense-in-depth check (a trigger or app-layer assertion) since it's a hand-rolled polymorphic association with no DB-level guarantee.

---

## 7. Domain/Infra Note (worth a 2-minute manual check)

Two Vercel projects both currently list `rinkreports.com` / `www.rinkreports.com` in their domain configuration: `rink-reports-5-6` (the actively-deployed project, `live: true`) and `mfo-rink-reports-2-7` (`live: false`). This is likely just stale metadata from an earlier project rename/migration, but worth a quick check in the Vercel dashboard to confirm the domain is bound to only the live project — a dangling domain binding on a dormant project is a low-probability but easy-to-fix footgun.

---

## 8. Recommended Roadmap

**Now (this week, low-effort/high-value security cleanup):** — *2026-07-12 status inline*
1. ⚠️ **STILL OPEN** — Decide intent on `information_requests` anon-insert policy; narrow or rate-limit it either way.
2. ✅ **6 of 7 done** — Anon EXECUTE revoked on six functions; only `check_rate_limit` remains (§4.2). Revoke it too, same pattern as PR #239.
3. ✅ **DONE** — `search_path` now pinned on `schedule_swap_set_expiry` (no longer advisor-flagged).
4. ⚠️ **STILL OPEN** — Enable leaked-password protection in Auth settings.
5. Confirm the `mfo-rink-reports-2-7` domain binding is inert. *(Vercel-side; not covered by the 2026-07-12 DB advisor re-run.)*

**Next (before onboarding a second facility / real GA):**
6. Land the FK-covering-index migration (~57 columns as of 2026-07-12) — cheap insurance before multi-tenant write volume grows.
7. Fix Auth DB connection strategy to percentage-based.
8. Drop `role_module_permission_defaults` once confirmed unused by the admin UI.
9. Get real usage into the untested modules (Communications, Air Quality, Accident Reports) — either through the pilot facility's actual workflows or a deliberate UAT pass — before trusting their RLS/business logic under real load. A module with 0 production rows has had zero real-world validation of its write paths.
10. ~~Merge/resolve PR #240 (publish-lock bypass fix)~~ — **Done as of 2026-07-02**: merged, and independently re-verified fixed by the PR #245 audit. Replacement item: land PR #245's remaining phases — it carries a HIGH cross-tenant privilege-escalation fix (migration 165) and a facility-documents access gate (migration 166) that shouldn't sit unmerged long.

**Later (scale-readiness):**
11. Revisit the unused-index list once real query patterns exist from actual customer traffic — don't act on it now, the data volume is too low to be meaningful.
12. Add DB-level enforcement (trigger or constraint) for the `module_area_permissions.area_id` polymorphic reference, or explicitly document why app-layer validation is sufficient.

---

## 9. Open Questions for the Product Owner

- Is `information_requests` meant to be a public-facing contact/inquiry form (e.g., on a marketing page), or was the anon-insert policy an oversight?
- Is there a target date/customer for exiting "1-facility pilot" mode? That affects how urgently items 6–9 above need to land.
- Are Communications, Air Quality, and Accident Reports intentionally dormant pending a rollout phase, or are they expected to be in active use already and something's blocking adoption (training gap, UI friction, etc.)?
