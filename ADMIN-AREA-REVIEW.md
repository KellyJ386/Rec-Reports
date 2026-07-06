# Rink Reports — Admin Area 360° Review

**Prepared:** 2026-07-06
**Scope:** Every admin-facing feature of the live production system (`www.rinkreports.com`, Supabase project `bqbdgwlhbhabsibjgwmk`). Reviewed from the live database: RLS write-gates on every admin-managed table, the SECURITY DEFINER admin RPCs and their internal authorization checks, DB triggers/guards, actual configuration data, audit-trail coverage, and current security/performance advisors. Deployment history (Vercel) was used to confirm which recent fixes are live.
**Limitation:** The application source repo (`KellyJ386/Rink-Reports-5-6`) was not attached to this session, so admin **UI** behavior (layout, form validation, navigation) is out of scope; everything below is verified against the live backend, which is where the admin area's guarantees actually live. Where a finding needs a code-level look, it says so.

This complements `RINK-REPORTS-360-AUDIT.md` (2026-07-01). Since that audit, PRs #246–#253 merged (scheduling audit waves, communications broadcast + permission consolidation, accident/incident admin-console gating, timezone rework, ice-ops fixes; migrations now through ~174). Everything below reflects the system **after** those merges.

---

## 1. Executive Summary

The admin area's security backbone is in genuinely good shape: every admin-managed table has correct, facility-scoped, role-gated RLS write policies; the dangerous RPCs check authorization internally; the privilege-escalation guard from migration 165 is live in production; and admin actions on employees, roles, and permissions are audit-logged. Of the four security items flagged a week ago, two are fixed (anon-exposed functions cut from 7 to 1, `search_path` pinned) and two remain open (`information_requests` anon insert, leaked-password protection).

The real problems found are of a different kind:

1. **Data-integrity drift the admin UI can't see** — 15 of 26 per-area permission rows point at deleted checklist areas (the un-enforced soft reference the schema itself warned about has now actually happened in production).
2. **A permission matrix hole** — the `facility_paperwork` module has *zero* role-default permission rows for *any* role, so nobody gets seeded access to it.
3. **Critical alerts going nowhere** — the alert pipeline works (a real "ambulance called" critical alert fired June 30) but Communications routing is completely unconfigured, and both alerts requiring acknowledgement sit unacknowledged six days later.
4. **A long tail of empty-but-required admin config** — incident activities, workers' comp instructions, certification catalog, air-quality monitors, retention/export settings are all unconfigured, which silently degrades the staff-facing forms that depend on them.

None of these need a rebuild. Items 1–2 are one migration each; item 3 is either a seeded default routing rule or a dashboard surface; item 4 is an onboarding/UX problem that a "setup completeness" panel would solve permanently.

---

## 2. Feature-by-Feature Review

Legend: ✅ works (verified) · ⚠️ needs fixing · 💡 idea

### 2.1 Roles & Permissions

The heart of the admin area: 5 roles (super_admin 0 / admin 1 / manager 2 / staff 3 / custom "driver" 4), a per-role default matrix (`role_permission_defaults`, 151 rows), per-user overrides (`user_permissions`, 140 rows), and per-area grants (`module_area_permissions`, 26 rows).

- ✅ **Write-gating is correct everywhere.** Roles, defaults, and overrides are writable only by facility admin/GM/super-admin, always facility-scoped. Role DELETE is super-admin-only (deactivation is the normal path — `deactivate_role`/`reactivate_role` RPCs exist and internally check authorization). Custom role support works (the "driver" role, hierarchy level 4, with a sensibly reduced matrix).
- ✅ **Privilege-escalation guard is live.** The `users_profile_update_guard` trigger (migration 165) is on the production `users` table — a facility admin can no longer flip `is_super_admin`. Role creation auto-seeds its permission defaults via trigger; permission changes are audit-logged (148 audit rows across the two permission tables).
- ⚠️ **15 of 26 per-area permission rows are orphaned.** `module_area_permissions.area_id` is a soft reference by design ("callers must validate"), and there is no validation trigger and no cleanup on area delete. In production, 15 rows for `daily_reports` point at `daily_report_areas` ids that no longer exist. Consequences: the per-area permission admin screen is showing (or silently carrying) grants to ghost areas, and the row cap/queries operate on garbage. **Fix:** one migration — delete the orphans, add a validation trigger on insert/update, and delete matching rows when an area is deleted. This exact failure mode was predicted in the prior audit (§6); it's now observed fact, so the defense-in-depth trigger stops being optional.
- ⚠️ **`facility_paperwork` has no permission defaults at all.** All 10 modules are enabled for the facility, but the role-defaults matrix has 0 rows for `facility_paperwork` for *every* role (all other gaps in the 151/200 matrix are the intentional staff/driver exclusions). New employees therefore get no seeded permission for it, and it likely doesn't render in the role-defaults admin grid. Looks like the matrix was never extended when the module was added. **Fix:** seed the missing role×action rows (mirror how `facility_documents` SELECT is gated), and add a safety net so future modules can't ship without defaults (e.g., a check in the module-registration migration or a startup assertion).
- ⚠️ **Every user_permissions row is `source='manual_override'`** (140 rows, 4 users — none marked as role-derived). Either `apply_role_permission_defaults()` stamps the wrong source or the admin UI always writes overrides. This makes "reset to role defaults" and "why does this user have this permission" semantics murky, and it will get worse with more users. Needs a code-level look at what writes these rows.
- ⚠️ **The deprecated `role_module_permission_defaults` table is still live** (20 rows; its own comment says "drop after admin/roles page is migrated"; it even still receives audit entries). Confirm the admin roles page no longer reads it, then drop it — carrying two permission-defaults tables invites a divergence bug.
- 💡 The resolver `effective_module_permission_with_source()` already exists — expose it in the admin UI as a "why does this user have access?" explainer and a per-user effective-permissions preview ("view as"). This turns permission debugging from support tickets into self-service.

### 2.2 Employees, Users, Invites & Certifications

103 employees (all active), 5 auth users, 3 employees linked to logins.

- ✅ Employee writes gated to admin/GM/super-admin; DELETE is super-admin-only (deactivate is the workflow). All 326 employee changes are audit-logged. `create_employee_complete` RPC checks authorization internally. The 4-job-area cap is trigger-enforced and holds in production data (max observed = 4). Wages are correctly isolated in an admin-only table (`employee_wages`) instead of the staff-readable `employees`.
- ⚠️ **Two stranded auth users.** `kellygjohnson@yahoo.com` has no employee record *and* no permission rows; `geeka386@yahoo.com` has no employee record. These accounts can authenticate but exist outside the entire permission/employee model — invisible in an employee-centric admin UI. Decide: link, deactivate, or delete; and give the admin area an "unlinked accounts" view so this class of orphan is visible.
- ⚠️ **The activation funnel is unused.** 103 employees, 0 invites ever sent (`employee_invites` empty), 3 with logins. The invite feature is built and correctly admin-gated but has never been exercised — the single biggest adoption lever in the system right now.
- ⚠️ **Certifications are a fully-built dead end so far:** `certification_types` (the catalog), `employee_certifications`, and `job_area_certification_requirements` are all empty, and scheduling has `require_job_area_qualification=false`. The cert-gating machinery (including the override-with-audit path, `schedule_assignment_overrides`) is ready but inert. That's fine as a rollout choice — but worth an explicit decision rather than drift.
- 💡 Bulk import + bulk invite (CSV → employees → invites) with progress and per-row errors; 103 hand-entered employees suggests this pain was already felt once.
- 💡 Employee-profile completeness indicators (missing email/phone/emergency contact, minor without max-hours) surfaced as chips in the roster.

### 2.3 Module Toggles & Facility Settings

- ✅ `facility_modules` (all 10 enabled) is facility-admin gated; per-user dashboard hide/show RPCs correctly self-scope to `auth.uid()`. Facility record itself is super-admin-only — deliberate and fine for now. Facility spaces (22 active) are shared across incident/accident/air-quality and correctly writable by any of those modules' admins. The generic `facility_dropdown_options` system works but only one domain (`facility_timezone`) is populated — and the zip→timezone auto-derivation just merged (#252) makes that path smooth.
- ⚠️ **Retention (`retention_settings`) and export branding (`export_settings`) are empty.** Both tables are correctly gated and ready; nothing has ever been configured. If the admin pages exist, they've never been used; either way, seed sensible defaults at facility creation so "keep forever / plain PDF" is an explicit choice, not an accident of emptiness.
- ⚠️ Facility documents (`facility_documents` + private storage bucket) — correctly gated (facility-admin write, module-gated read per migration 166), bucket is private ✅, but zero documents uploaded. Same "built, unused" pattern.
- 💡 **Admin setup checklist / config-health panel.** This review found ~8 places where an empty admin table silently degrades a staff-facing feature (see 2.4–2.9). A single dashboard card — "Incident activities: 0 configured · Workers' comp text: missing · Alert routing: none · 2 users unlinked · 15 orphaned area grants" — would have surfaced every one of them to you months ago. This is the highest-leverage admin-area idea in this report.

### 2.4 Daily Reports (areas / templates / checklist items)

- ✅ Richest configured module: 17 active areas (cap 30, DB-checked), 51 templates (uniformly 3 per area), 506 items (~10 per template). Label snapshots on submissions protect history from later template edits. Per-area staff permissions are supported (the 26 `module_area_permissions` rows are all for this module).
- ⚠️ The orphaned-permission problem (2.1) lives here: whatever flow deleted areas left 15 permission grants behind. The area-delete admin action should clean up grants in the same transaction (or the DB should do it).
- ⚠️ Config is 25× ahead of usage (506 items, 2 submissions ever). Not a defect — but until real submissions flow, the admin-configured structure is unvalidated against reality.
- 💡 Template duplication ("copy area with templates+items"), drag-to-reorder, and a "preview as staff" render would make the heaviest-config module much cheaper to maintain. An "archive" path matters too: today deleting is the only cleanup (see orphans above); everything is `is_active=true`.

### 2.5 Incident Reports

- ✅ Types (5), severities (4), spaces (22) all configured and active; admin-only append-only change log working (create logged for the one real report); witness cap enforced; the June 30 ambulance incident correctly generated a critical alert. Post-#251/#252: admin console gated on module-admin grant, status values fixed, atomic persist RPCs (migration 173), timezone handling fixed.
- ⚠️ **`incident_activities` is empty.** The "activity at the time" picker is per-facility admin config and has zero options — staff filing an incident see an empty (or hidden) dropdown, and reports lose a categorization dimension. Seed a starter set (skating, hockey, broomball, birthday party, public skate, spectating…) like the other pickers already do.
- 💡 The `metadata` extension point pattern from accident dropdowns (`{"triggers_alert": true}`) would serve incidents too — e.g., admin-configurable "this incident type always pages an admin."

### 2.6 Accident Reports

- ✅ Best-designed admin config in the app: 46 dropdown options across 5 categories, `ON DELETE RESTRICT` protects body parts referenced by history, 24-h edit window + append-only change log, workers'-comp settings designed with a partial unique index (exactly one active per facility). Seed-drift bug fixed in #249.
- ⚠️ **`accident_workers_comp_settings` is empty.** The workers'-comp toggle on the form has no instruction text behind it — when a real workplace accident happens, the one moment this text matters, it's blank. Two-minute admin task (or seed a default at facility creation); zero real accident reports so far means it's cheap to fix now.
- 💡 Module is fully built with zero real usage — schedule one deliberate UAT accident drill before trusting it in a real event.

### 2.7 Refrigeration & Air Quality

- ✅ Refrigeration admin config is coherent and exercised: 6 sections, 7 equipment, 56 fields, 19 thresholds; OOR alerting enabled and **proven live** (the June 30 refrigeration alert quotes real threshold breaches with correct limits). Air Quality's compliance engine is impressive on the admin side: 4 jurisdiction profiles (MN/MA binding, WI/USIRA guidance), facility bound to MN with CO+NO₂ active, stricter-only overrides design.
- ⚠️ **Air Quality has no monitors configured** (`air_quality_equipment` = 0) and null testing frequency, with `alerts_enabled=true` and zero submissions ever. The module can't be meaningfully used until an admin adds at least one monitor/location. Either configure it or disable the module tile until ready — a permanently-empty enabled module erodes trust in the dashboard.
- 💡 Refrigeration `readings_per_shift` is null — if the field drives a compliance expectation, give it a default and surface "expected vs. actual readings today" on the admin dashboard.

### 2.8 Ice Operations & Ice Depth

- ✅ Ice Depth is the flagship: 2 rinks, 2 layouts (21+40 points, within the 60/layout DB-enforced cap), thresholds snapshotted into every session (19 sessions, 377 measurements survive any admin reconfiguration), severity computed server-side. Ice Ops: rinks/equipment/fuel-types configured; equipment-type-driven dropdown filtering is a nice admin design; recent fixes (#253) closed real bugs (RLS-dropped failure rollups, timezone skew).
- ⚠️ **Two circle-check config systems coexist.** The legacy per-facility checklist has 44 active items; the new fuel-type-anchored template system (`ice_operations_circle_check_templates`, cap 4/facility) has zero templates. If the app has cut over to templates, staff see an empty circle check while 44 legacy items sit ignored — if not, the new system is dead config. Needs a code-level check of which table the form reads, then either migrate the 44 items into templates or drop the unused system. (PR #254 — open — is actively touching circle-check behavior, so resolve this before it compounds.)
- ⚠️ Ice Depth `alerts_enabled=false` while thin-ice (`alert_on='low'`) is exactly the safety condition the alert system exists for. Deliberate? Flip it once alert routing (2.9) is fixed.
- 💡 Admin-maintained `hours_count` on resurfacers is manual; auto-accumulate from `edging`/`ice_make` payload hours with an admin correction field.

### 2.9 Scheduling

- ✅ The most admin-hardened module after its 5-wave audit (#246): publish-lock trigger live (both BEFORE INSERT and UPDATE — the #240 bypass stays closed), two-person publish governance, all admin RPCs (`scheduling_admin_*`, approve/decide/apply) internally check module-admin + facility scope + identity, cert-override logging is immutable, compliance rules configured (3), job areas (10) with the 4-per-employee cap enforced. Settings are thoughtfully complete (overtime 40h, minor cap 30h, breaks, swap expiry 72h, first-come open shifts).
- ⚠️ **Housekeeping RPCs are callable by any authenticated user:** `scheduling_expire_open_claims` / `scheduling_expire_stale_swaps` have no authorization check and no facility scoping — any staff member (of any facility, once there are several) can force-expire claims/swaps globally and spam `swap_expired` notifications. Effect is semi-benign today (it only expires things already past `expires_at`) but it's the wrong trust boundary. Revoke from `authenticated`, run them from the cron/service role only. (Minor: they also pin `search_path=public` without `pg_temp`, unlike every other function.)
- ⚠️ `get_employee_counts_by_facility()` — SECURITY DEFINER, no auth check, returns employee counts for **all facilities** to any authenticated user. Harmless with one facility; a cross-tenant metadata leak the day facility #2 onboards. Gate to super-admin (it reads like a super-admin dashboard helper) or scope to the caller's facility.
- ⚠️ All 10 shifts ever created are still `draft`; publish events: 0. The publish/notify/acknowledge flow — the part with the most governance machinery — has zero production reps. Same UAT recommendation as accidents.
- 💡 Labor-cost estimates are built but `employee_wages` is empty and `default_hourly_rate` is null — one seeded default rate would light the feature up for evaluation.

### 2.10 Communications (the biggest gap between built and used)

- ✅ The machinery works end-to-end on the *generation* side: source modules insert real alerts (2 on June 30 — one critical incident, one high refrigeration), with correct severity, titles, structured bodies, and `requires_acknowledgement=true`. Broadcast + scheduled-send + cancellable queue merged in #248 with proper module-admin outbox policies. All 10 tables correctly gated; audit log append-only.
- ⚠️ **The consumption side is unconfigured, so acknowledgement-required alerts go nowhere.** 0 groups, 0 routing rules, 0 recurring reminders, 0 messages, 0 acknowledgements — and both June 30 alerts are unresolved/unacknowledged 6 days later. A critical "ambulance called" alert with nobody routed to acknowledge it is the single most operationally dangerous finding in this review. **Fix in two layers:** (1) seed a default routing rule at facility creation — critical/high severity → all facility admins — so the pipeline is never configured-to-nowhere; (2) put an "unacknowledged alerts" tile on the admin dashboard regardless of routing config.
- 💡 Escalation policy on the routing rule (unacknowledged after N minutes → next rule / SMS via `sms_opt_in`, which already exists on users). The schema (`communication_routing_rules` severity/source matching) already supports most of this.

### 2.11 Audit & Governance

- ✅ Strong pattern discipline: central `audit_logs` (580 rows) covers exactly the right admin entities (employees 326, permissions 148, roles 7, departments 5, users 1, plus per-module submissions), every module has an append-only change log with no UPDATE/DELETE policies, `profile_audit_log` is wired for supervisor profile edits, `schedule_assignment_overrides` is immutable. This is better audit hygiene than most shipped SaaS.
- 💡 If there's no admin-facing audit-log viewer yet (needs a code check), build one: filter by entity/actor/date, humanized diffs. 580 rows of history nobody can browse is latent value. It also makes the deprecated-table drop (2.1) safer — you can *watch* what still writes to it.

---

## 3. Security Posture Delta (vs. 2026-07-01 audit)

| Item | Status 07-01 | Status today |
|---|---|---|
| 7 functions callable by `anon` | Open | **Fixed** — only `check_rate_limit` remains (see below) |
| `schedule_swap_set_expiry` mutable search_path | Open | **Fixed** — no longer flagged |
| Facility-admin → super-admin escalation (migration 165) | In open PR | **Live in prod** (`users_profile_update_guard` verified) |
| `information_requests` anon INSERT `WITH CHECK (true)` | Open | **Still open** — see below |
| Leaked-password protection (HIBP) | Disabled | **Still disabled** — one click in Auth settings |
| Unindexed FKs / unused indexes / auth pool absolute | 56 / 105 / 1 | Essentially unchanged (57 / 107 / 1) — still a pre-GA batch job |

**`information_requests`:** the column shape (name, email, company, address, note, status) confirms it's an intentional public "request info" lead form. Keep anon INSERT, but: deny the columns you don't need, add CHECK constraints (lengths, email format), wire it to the existing `check_rate_limit()` via trigger or move the insert behind an edge function, and confirm the admin area actually surfaces submissions (status column exists; 0 rows so far).

**`check_rate_limit` (the one remaining anon function):** callable by `anon` with **caller-supplied** `p_max`/`p_window_seconds`, and it fails **open** on null/invalid params. If it's only invoked server-side, revoke anon/authenticated EXECUTE. If it must stay public, wrap it: fixed per-bucket budgets server-side, never caller-supplied — otherwise the "limit" is decorative, and anyone can bloat `rate_limit_counters` with junk buckets (unbounded insert path).

---

## 4. Prioritized Fix List

**This week (small, high-value):**
1. Seed a default critical-alert routing rule (critical/high → facility admins) + "unacknowledged alerts" admin tile; acknowledge/resolve the two June 30 alerts. (§2.10)
2. Migration: purge the 15 orphaned `module_area_permissions` rows; add validation trigger + cascade cleanup on area delete. (§2.1)
3. Migration: seed `facility_paperwork` role-permission defaults for all roles. (§2.1)
4. Enable leaked-password protection (Auth settings, one click). (§3)
5. Revoke anon EXECUTE on `check_rate_limit` (or wrap with fixed budgets); tighten `information_requests` (constraints + rate limit). (§3)
6. Resolve the two stranded auth users (link or deactivate). (§2.2)
7. Admin content pass (no code): populate incident activities, workers'-comp instruction text; decide Air Quality monitor config or disable its tile. (§2.5–2.7)

**Next (before facility #2):**
8. Gate/scope `get_employee_counts_by_facility`; move `scheduling_expire_*` to service-role-only. (§2.9)
9. Resolve the circle-check dual-config (migrate 44 legacy items into fuel-type templates or drop the new system) — coordinate with open PR #254. (§2.8)
10. Investigate `user_permissions.source` always being `manual_override`; fix the seeding path so role-derived rows are distinguishable. (§2.1)
11. Confirm admin/roles page no longer reads `role_module_permission_defaults`; drop it. (§2.1)
12. Seed retention + export defaults at facility creation; backfill for the pilot facility. (§2.3)
13. FK-covering-index migration (57 columns) + auth pool percentage — unchanged from prior audit. (§3)

**Ideas that would make the admin area meaningfully better (§2 passim):**
- **Setup-completeness / config-health panel** — the single change that would have caught most of this report automatically.
- Effective-permissions "view as role/user" explainer built on the existing resolver functions.
- Bulk employee import + invite campaign (0 of 103 employees invited is the adoption bottleneck).
- Alert escalation policies (unacked → escalate/SMS).
- Admin audit-log viewer with humanized diffs.
- Template/config duplication tools for the heavy-config modules (daily reports, circle checks).
- UAT drills for the zero-usage modules with governance machinery (accidents, schedule publish) before real events depend on them.

---

## 5. Status Update — 2026-07-06, fixes applied (see `admin-fixes/`)

Applied live (data-only): the 15 orphaned area-permission rows are **purged** (snapshot committed in `admin-fixes/`), and **7 default alert routing rules** now route every module's alerts to the 5 admin-role employees (fix-list items 1–2 partially done; the two pre-existing June 30 alerts still need manual acknowledgement).

Upgraded finding while fixing item 3: `facility_paperwork` isn't just missing role defaults — the `user_permissions` CHECK constraint **doesn't allow the module at all**, and the canonical grant matrix (`canonical_role_permission_grants()`) omits it, so no one except a super-admin can ever be granted access. A data-only seed was attempted and cleanly reverted (it would have broken `apply_role_permission_defaults()` until the constraint is widened). The complete fix — constraint, canonical matrix, backfill, reapply — is packaged as `admin-fixes/proposed-migrations/A_*.sql`, with the integrity triggers and RPC/public-form hardening as `B_*.sql` / `C_*.sql`, ready to renumber and drop into the app repo's migration chain. Also resolved: §2.1's `manual_override` mystery is a UI-path issue — `apply_role_permission_defaults()` itself stamps sources correctly and preserves overrides.

Still needs a human: acknowledge the two June 30 alerts, flip the HIBP toggle, decide the two stranded logins, and land the three migrations in the app repo.

---

## 6. What I Could Not Verify From Here

- Admin **UI** correctness (forms, empty states, navigation, error surfacing) — needs the `Rink-Reports-5-6` repo attached to a session. The recent module-review PRs (#249, #251) show this is being worked through module-by-module and repeatedly found the same class of bug (admin console not gated on the module-scoped grant; the communications console had the pattern right first). Modules not yet deep-reviewed by that series, per deployment history: **Daily Reports, Refrigeration, Air Quality, Ice Depth admin consoles** — worth the same treatment.
- Whether an audit-log viewer, retention enforcement job, or export/PDF admin page exist in the UI at all.
- Which circle-check table the form actually reads (§2.8).
- What writes `user_permissions.source` (§2.1).
