# Admin-Area Fixes — 2026-07-06

Follow-up to `../ADMIN-AREA-REVIEW.md`. Two kinds of work, kept deliberately separate:

## Applied directly to production (data-only, no schema drift)

1. **Purged 15 orphaned per-area permission grants** (`module_area_permissions` rows pointing at daily-report areas deleted on 2026-05-31). Verified 0 orphans / 11 valid rows remain. Deleted rows preserved in `orphaned-module-area-permissions.snapshot.json`.
2. **Seeded 7 default alert routing rules** (`communication_routing_rules`): one per alert-generating module (incident, accident, refrigeration, air quality, ice operations, ice depth, scheduling), any severity → role `admin` (resolves to 5 active admin employees), timing `immediate`, acknowledgement required. Named `Default: <module> alerts → Admins`; delete/edit freely in the Communications admin console.

## Proposed migrations for the app repo (`Rink-Reports-5-6/supabase/migrations/`)

Schema changes were **not** applied to prod — doing so would silently diverge prod from the repo's migration chain (the schema-drift gate rebuilds from migrations). Copy these in, **rename each with the next free numeric prefix**, review, and apply through the normal pipeline:

| File | What it fixes |
|---|---|
| `A_facility_paperwork_permission_model.sql` | `facility_paperwork` is structurally excluded from the permission model — the `user_permissions` module CHECK doesn't allow it and `canonical_role_permission_grants()` never seeds it, so it's effectively super-admin-only. Widens the constraint, extends the canonical matrix, backfills defaults, reapplies to linked users. **Order matters:** a live data-only seed attempt on 2026-07-06 tripped the CHECK inside `apply_role_permission_defaults()` and was fully reverted — the constraint must change first. |
| `B_module_area_permissions_integrity.sql` | Prevents the orphaned-grant problem from recurring: validation trigger on write + cleanup trigger when a daily-report area is deleted + idempotent purge. |
| `C_rpc_and_public_form_hardening.sql` | Revokes anon EXECUTE on `check_rate_limit` (verify call sites first — see file), gates `get_employee_counts_by_facility` to super-admin, makes the scheduling expiry jobs service-role-only, adds input constraints + server-side rate limiting to the public `information_requests` form. |

## Still needs a human

- **Acknowledge/resolve the two June 30 alerts** (critical incident "ambulance called", high refrigeration OOR) in the Communications console — routing now exists for *future* alerts, but these two predate it.
- **Enable leaked-password protection**: Supabase Dashboard → Authentication → Settings (one toggle).
- **Decide the two stranded logins** (`kellygjohnson@yahoo.com` — no employee record, no permissions; `geeka386@yahoo.com` — no employee record): link to employees or deactivate.
- **Routing noise preference**: rules currently match *all* severities. If admins get too much mail once volume grows, set each rule's severity to `critical`/`high` in the console.
