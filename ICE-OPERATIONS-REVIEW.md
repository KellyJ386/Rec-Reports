# Ice Operations Module — Full Review

**Prepared:** 2026-07-04
**Scope:** The Ice Operations module of Rink Reports — 11 tables (`ice_operations_*` + `ice_operation_change_log`), their RLS policies, constraints, triggers, indexes, functions, and all live data, inspected directly in the production Supabase database (project `bqbdgwlhbhabsibjgwmk`).
**Method:** Same caveat as the 360° audit — the application source lives in `KellyJ386/Rink-Reports-5-6`, which this session cannot read. Everything below is verified at the database layer; anything about form/UI behavior is inferred from schema comments and live data and flagged as such.

**Companion doc:** `RINK-REPORTS-360-AUDIT.md` (system-wide). This review drills into the one module that audit summarized as "Configured, light use — 4 submissions, 0 circle-check results," and explains *why* it's 0.

---

## 1. Executive Summary

The Ice Operations schema is well-engineered: complete facility-scoped RLS on all 11 tables, every foreign key covered by an index, sensible partial indexes, snapshot columns for history, an append-only follow-up-notes design, and both module functions (`seed_default_ice_operations_config`, `purge_old_ice_operations_submissions`) correctly locked down (`SECURITY DEFINER`, pinned `search_path`, no `anon`/`authenticated` EXECUTE — this module is *not* among the 7 exposed functions flagged in the 360° audit).

But the module has **three confirmed defects**, two of them serious:

1. **A leftover CHECK constraint makes it impossible to scope circle-check items to ice resurfacers — and will crash new-facility onboarding.** (§3.1)
2. **Every submission's `occurred_at` is stored 4–5 hours wrong** — local wall-clock time labeled as UTC. (§3.2)
3. **The circle-check feature appears un-completable in production** — two competing checklist designs coexist, the newer one (fuel-type templates) has zero configuration, and zero circle checks have ever been submitted despite 44 configured checklist items. (§3.3)

Usage to date: 4 submissions (3 `ice_make`, 1 `edging`), 0 `circle_check`, 0 `blade_change`, 0 follow-up notes, 0 change-log rows. The audit trail trigger is verified working (4 `create` rows in `audit_logs`, all with actors).

---

## 2. What the Module Looks Like (verified inventory)

| Table | Rows | Purpose |
|---|---|---|
| `ice_operations_settings` | 1 | Per-facility config: `temperature_unit` (F), `alerts_enabled` (true), `default_alert_severity` (high), `enabled_operation_types` (NULL) |
| `ice_operations_equipment` | 3 | Equipment dropdown ("Engo- Classic" resurfacer, "Engo" edger, "Hand edger" typed as `edger`); `hours_count` NULL on all rows |
| `ice_operations_fuel_types` | 2 | GAS, Electric |
| `ice_operations_rinks` | 2 | NHL Rink, Oval Rink |
| `ice_operations_circle_check_items` | 44 | Legacy(?) per-facility checklist — all 44 active, all `pass_fail`, **all with `applies_to_equipment_type = NULL`** |
| `ice_operations_circle_check_templates` | **0** | Newer(?) fuel-type-keyed checklist templates |
| `ice_operations_circle_check_template_items` | **0** | Items for the above |
| `ice_operations_submissions` | 4 | 3 ice_make + 1 edging; immutable (UPDATE/DELETE super-admin only) |
| `ice_operations_circle_check_results` | **0** | Per-item results of a circle check |
| `ice_operations_followup_notes` | 0 | Append-only admin notes (no UPDATE/DELETE policies — correct) |
| `ice_operation_change_log` | 0 | Before/after log for super-admin edits |

Module is enabled for the pilot facility (`facility_modules.ice_operations = enabled`, Tennity Ice Skating Pavilion, timezone `America/New_York`).

---

## 3. Confirmed Defects

### 3.1 HIGH — Conflicting CHECK constraints on `circle_check_items.applies_to_equipment_type`; new-facility seeding will fail

`ice_operations_circle_check_items` carries **two** validated CHECK constraints on the same column:

- `..._applies_to_equipment_type_check` → allows `('zamboni', 'edger', 'blade_set', 'other')`
- `..._applies_to_equipment_type_che` → allows `('ice_resurfacer', 'edger', 'blade_set', 'hand_edger', 'other')`

Both are enforced (AND semantics), so the *effective* allowed set is the intersection: **`edger`, `blade_set`, `other`** (plus NULL). This is clearly debris from a `zamboni` → `ice_resurfacer` terminology migration where the old constraint was renamed-around instead of dropped. Two concrete consequences:

1. **No checklist item can be scoped to an ice resurfacer** — the primary equipment a circle check exists for. `hand_edger` is also un-scopable. This explains the live data: all 44 items have NULL scoping, so every equipment type sees all 44 items.
2. **`seed_default_ice_operations_config()` will throw on any new facility.** Four of its five default checklist items insert `applies_to_equipment_type = 'ice_resurfacer'`, which violates the zamboni-era constraint. The first insert raises, the whole function aborts (settings row survives only because it's written first… actually no — the exception rolls back the entire function's work unless the caller catches it). Whatever onboarding path calls this function breaks with it. It evidently ran before the constraint situation arose for the pilot facility, but **facility #2 onboarding will hit this**.

**Fix (one line):** `ALTER TABLE ice_operations_circle_check_items DROP CONSTRAINT ice_operations_circle_check_ite_applies_to_equipment_type_check;` (drop the zamboni one, keep the `ice_resurfacer` one). Worth grepping the other modules' migrations for the same rename-without-drop pattern.

### 3.2 HIGH — `occurred_at` stores facility-local wall time mislabeled as UTC

All four submissions show the same signature (facility TZ is `America/New_York`, UTC-4 in these months):

| `submitted_at` (UTC, server-set) | true local time | `occurred_at` as stored | payload `time_in` |
|---|---|---|---|
| 2026-05-22 14:10:35+00 | 10:10 EDT | 2026-05-22 **10:09**:00**+00** | — |
| 2026-06-01 01:00:36+00 | 21:00 EDT (May 31) | 2026-05-31 **20:59**:00**+00** | "21:00" |
| 2026-06-14 11:32:32+00 | 07:32 EDT | 2026-06-14 **07:28**:00**+00** | "07:32" |
| 2026-06-22 16:20:05+00 | 12:20 EDT | 2026-06-22 **12:18**:00**+00** | "12:00" |

`occurred_at` always matches the local wall clock but carries a `+00` offset — the client is sending a naive local datetime into a `timestamptz` column. Every stored instant is 4 hours early (5 in winter, and the error size will silently change across DST transitions). This corrupts anything time-based: cross-module timelines, "submitted within X hours of occurrence" logic, retention purges keyed off dates, and any future multi-timezone customer.

**Fix:** in the app, serialize `occurred_at` as a proper ISO-8601 instant (with offset or converted to UTC) before insert; then backfill the 4 existing rows (`occurred_at + interval '4 hours'`). Worth checking whether sibling modules (incident/accident/refrigeration `occurred_at`-style columns) share the same client code path and the same bug — the Ice Depth module's heavy usage would make it the best place to verify.

### 3.3 HIGH (product) — Circle checks appear impossible to complete; two competing checklist designs

Zero circle-check submissions and zero results, ever, despite: 44 checklist items configured (someone put real effort into that list), 2 fuel types, a resurfacer linked to a fuel type, and `alerts_enabled = true` waiting to fire on failed checks. Meanwhile the *other* checklist mechanism — fuel-type-keyed templates (`circle_check_templates` + `template_items`, "at most one template per (facility, fuel_type), app caps 4") — has **zero rows of configuration**.

From the DB alone I can't see which one the submission form actually reads (source-access caveat), but the shape strongly suggests: the form was migrated to the template system, no template was ever configured, so operators hit an empty/blocked circle-check flow — and the 44-item legacy list is orphaned. The `circle_check_results` table supports both lineages (`checklist_item_id` FK for items, `checklist_item_id = NULL` + `label_snapshot` for template items), which confirms the two systems coexist by design rather than by accident.

**This needs a product decision, not just a fix** — see Questions §6.1. Whichever way it goes: if templates win, the 44 items should be migrated into a template (and the items admin UI retired); if items win, drop the empty template tables. Note that once results *do* flow, template-item results are stored with `checklist_item_id = NULL` and only a label snapshot — there is no `template_item_id` column, so results can never be traced back to the specific template item or trended per-item across submissions. If per-item failure trending matters (e.g., "tire pressure fails every week"), add a `template_item_id uuid` snapshot column before real data accumulates.

---

## 4. Security & Integrity Findings (medium)

### 4.1 `circle_check_results` INSERT is weaker than `submissions` INSERT

- `ice_operations_submissions` INSERT requires `current_employee_module_permission('ice_operations') >= 'submit'`.
- `ice_operations_circle_check_results` INSERT requires only `has_module_access('ice_operations')` — i.e., **view-level access suffices to insert result rows** via direct PostgREST calls.

Additionally, nothing in the policy or constraints requires the referenced `submission_id` to (a) belong to the same facility as the result row, (b) be a `circle_check` submission, or (c) be recent. So any authenticated facility member with view access can append extra "results" to any historical submission — quietly undermining the module's carefully-built immutability story (submissions themselves are super-admin-only to modify, but their child results are open). The denormalized `has_failed_check`/`failed_count` on the submission are app-maintained, so injected rows also silently desynchronize those counters (a failed-look result could exist under a submission that says `failed_count = 0`, or vice versa).

**Suggested hardening:** raise the INSERT policy to `>= 'submit'`, and add a trigger (or extend the policy with an EXISTS) asserting the parent submission is same-facility and `operation_type = 'circle_check'`. A trigger that recomputes `failed_count`/`has_failed_check` on result INSERT would eliminate the drift class entirely — cheap at this volume.

### 4.2 `ice_operation_change_log` INSERT policy is broader than its only legitimate writer

Submissions can only be UPDATEd by super-admins, so the change log's only legitimate write path accompanies a super-admin edit. But the INSERT policy allows **any submit-level employee** to insert arbitrary `before`/`after`/`reason` rows against any `report_id` in their facility. The audit trail for "who changed this report and why" is spoofable one level below the UI. Suggested: restrict INSERT to `is_super_admin()` (matching the UPDATE policy on submissions), or better, populate the change log from a trigger on `ice_operations_submissions` UPDATE so it can't diverge from reality at all. (Also note `audit_row_change()` already captures before/after on this table — worth confirming the change-log table isn't fully redundant with `audit_logs` before investing in it.)

### 4.3 UI-only invariants with cheap DB backstops available

Schema comments openly acknowledge several app-enforced rules with no DB enforcement. All are fine at pilot scale; each is a one-line constraint if you want defense-in-depth:

- `failed_notes` required when `passed = false` (comment: "UI-enforced") → `CHECK (passed IS DISTINCT FROM false OR failed_notes IS NOT NULL)`
- ≤ 50 active checklist items, ≤ 4 templates per facility (comment: "enforced in app") — a trigger-based cap if it ever matters
- `enabled_operation_types text[]` has no element-level CHECK (the four canonical values) and is currently NULL — NULL's meaning ("all enabled"?) is undocumented; a NULL-vs-empty-array mixup would silently disable the module's forms
- `payload jsonb` has no shape validation per `operation_type` — acceptable, but see §5.1 on the shape having already drifted

---

## 5. Consistency & Data-Quality Findings (low)

### 5.1 The documented `ice_make` payload no longer matches reality

The table comment says `ice_make` payload = "water/ice temps, time_in/out, water_used_gal, surface_pass_count". Actual live payloads contain `time_in`, `time_out`, `machine_hours`, `snow_taken_pct`, `water_used_gal` — **no temperatures, no surface_pass_count**. Two knock-on effects: `ice_operations_settings.temperature_unit` currently governs nothing (no temps are captured anywhere in the module), and the schema comment (the only DB-side "spec") is stale. Either the form changed and docs/settings should follow, or fields were unintentionally dropped from the form.

### 5.2 `machine_hours` values look untrustworthy and go nowhere

The three ice_make submissions record `machine_hours` of **777 → 700 → 7777** (chronological). Non-monotonic and suspiciously keyboard-mashed — there's evidently no client-side sanity check (e.g., "must be ≥ last recorded value for this equipment"). Meanwhile `ice_operations_equipment.hours_count` ("admin-maintained cumulative hours; staff-side forms display the latest value") is NULL on all equipment — so the form is presumably displaying nothing, and the hours captured in submissions never update it. Suggestion: either auto-roll `hours_count` forward from submission payloads (trigger or app logic) with a monotonicity check, or drop one of the two hour-tracking mechanisms. Two disconnected sources of truth for the same odometer is how both end up wrong.

### 5.3 Duplicated rink lists across modules — already drifted

`ice_operations_rinks` (NHL Rink, Oval Rink) and `ice_depth_rinks` (Main Rink, Oval Rink) are independent per-module tables, and for the same physical facility they already disagree on what the non-Oval sheet is called. Cross-module reporting ("show me everything that happened on the NHL rink today") is impossible to join reliably. `facility_spaces` also exists at the facility level. Suggest a single canonical facility-level rink/surface table that module tables FK into (or at minimum an admin UI that manages both lists together). This gets 10× harder to retrofit after multi-facility launch.

### 5.4 Naming and small nits

- `ice_operation_change_log` — singular prefix (vs `ice_operations_*` everywhere else) and `report_id` (vs `submission_id` in sibling child tables). Cosmetic, but it's the kind of thing that breaks `like 'ice_operations%'` maintenance scripts — including, notably, some of the inventory queries used for this review.
- "Hand edger" equipment row is typed `edger`, though a dedicated `hand_edger` equipment type exists (which per the comments has looser submission-type rules). Data-entry nit for the pilot facility admin.
- `ice_operations_equipment.tank_capacity_gal` is NULL everywhere and referenced by nothing visible in the DB — presumably feeds a future fuel/consumption feature; confirm it's still wanted.

### 5.5 Retention purge is unreachable

`purge_old_ice_operations_submissions()` is well-written (per-facility `keep_days`, honors `auto_purge`) but: `retention_settings` has **0 rows** (any module), `pg_cron` is not installed, and the function grants execute to neither `anon` nor `authenticated`. So nothing can currently invoke it and it would no-op if invoked. Fine if retention is a not-yet-launched feature; worth a deliberate note somewhere so it isn't mistaken for active behavior (e.g., a customer being told data auto-purges when it doesn't). Also note the purge keys off `submitted_at` — as long as §3.2 stands, `occurred_at`-based expectations and `submitted_at`-based purging will disagree by hours around midnight boundaries.

---

## 6. Questions for the Product Owner

1. **Circle checks — items or templates?** Which checklist system is the submission form supposed to read: the 44-row per-facility item list (equipment-type-scoped), or the fuel-type-keyed templates (currently completely unconfigured)? Is the empty-template state the reason zero circle checks have ever been submitted, or are operators simply not using the feature yet? The answer decides whether §3.3 is a migration task or a training/adoption task.
2. **Was the ice_make form intentionally changed** from water/ice temperatures + surface passes to machine hours + snow-taken %? If temps are gone for good, should `temperature_unit` be removed from settings (it currently controls nothing)? If temps are supposed to be there, that's a form regression worth a ticket.
3. **What is `occurred_at` supposed to mean** — true instant (fix serialization, keep `timestamptz`) or facility wall-clock time (then it should arguably be `timestamp` + rely on facility timezone)? §3.2's fix differs depending on intent. And is this module's datetime picker shared with other modules' "occurred at" fields?
4. **Should equipment `hours_count` auto-update** from submission payloads (`machine_hours`, `hours_run`, `hours_at_change`), or remain purely admin-maintained? Current state — both mechanisms present, neither actually working — suggests the design was never settled.
5. **Is view-level INSERT on `circle_check_results` intentional** (e.g., a shared kiosk account that can record checks but not create submissions)? If not, §4.1's tightening is safe to apply.
6. **Rinks: is per-module rink configuration deliberate** (different modules genuinely track different surfaces), or should there be one facility-level rink list? The NHL/Main naming drift suggests the pilot facility's admin already lost track of the duplication.
7. **Retention:** is auto-purge a launched feature commitment (some jurisdictions want fixed retention for safety-check records — sometimes *minimum* retention, which auto-purge could violate)? Who is intended to call the purge function — pg_cron, a Vercel cron, an edge function?
8. **Blade changes:** `blade_change` submissions carry `blade_serial`/`hours_at_change` in payload, and `blade_set` is an equipment type — but with 0 blade_change submissions and no blade-set equipment rows, is blade lifecycle tracking (which blade is on which machine, hours per blade) an intended near-term feature? The current payload-only design can't answer "which blade is currently mounted."

---

## 7. Recommended Actions (in order)

**Now (small, safe, high-value):**
1. Drop the zamboni-era CHECK constraint on `circle_check_items` (§3.1) — one-line migration; unblocks both item scoping and facility onboarding. Grep other modules for the same double-constraint pattern.
2. Fix `occurred_at` serialization in the app and backfill the 4 mislabeled rows (§3.2). Audit sibling modules for the same bug.
3. Decide items-vs-templates for circle checks (§6.1) and either configure a template or repoint the form — this single decision likely takes circle-check usage from impossible to live.

**Next (before facility #2):**
4. Tighten `circle_check_results` INSERT (submit-level + same-facility/circle-check parent) and add a counter-sync trigger for `failed_count`/`has_failed_check` (§4.1).
5. Restrict or trigger-populate `ice_operation_change_log` (§4.2).
6. Add the `failed_notes` CHECK and an element CHECK on `enabled_operation_types`; document NULL semantics (§4.3).
7. Refresh the stale `ice_make` payload comment and resolve the `temperature_unit` question (§5.1); settle the `hours_count` design (§5.2).
8. If template-based circle checks win: add `template_item_id` to results before real data accumulates (§3.3).

**Later (scale-readiness, aligns with the 360° audit's "Later" tier):**
9. Unify rink/surface configuration at the facility level (§5.3).
10. Wire up (or explicitly shelve) retention purge with a documented scheduler (§5.5).
11. Consider payload JSON-shape validation per `operation_type` once the shapes stabilize.

---

## 8. What's Good (so it doesn't get lost)

- **RLS coverage is complete and consistent**: every table facility-scoped, admin-config tables gated on `has_module_admin_access`, reads gated on `has_module_access`, submissions gated on an explicit permission level. No table in this module appears in the advisor warnings.
- **Both module functions are properly hardened** — `SECURITY DEFINER` with pinned `search_path`, not executable by `anon`/`authenticated`. This module already follows the pattern PR #239 retrofitted elsewhere.
- **Indexing is exemplary**: every FK covered (this module contributes nothing to the audit's 56 uncovered-FK list), plus purposeful composites (`facility_id, submitted_at DESC`) and partial indexes (`WHERE passed = false`, `WHERE has_failed_check = true`) that match the obvious dashboard queries.
- **The immutability architecture is real, not aspirational**: super-admin-only UPDATE/DELETE on submissions, append-only follow-up notes (no UPDATE/DELETE policies at all), label/response-type snapshots on results, a shape CHECK tying `passed` to `response_type_snapshot`, and a verified-firing audit trigger. The gaps found (§4.1, §4.2) are edges of an otherwise sound design.
- **Slug uniqueness per facility** on equipment/fuel-types/rinks and one-settings-row-per-facility are all enforced at the DB, not just the app.
