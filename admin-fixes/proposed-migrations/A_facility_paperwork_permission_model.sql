-- Proposed migration for KellyJ386/Rink-Reports-5-6 (supabase/migrations/).
-- Rename with the next free numeric prefix before committing (repo was at ~174
-- as of 2026-07-06; prefixes have collided before — check first).
--
-- Problem (found in the 2026-07-06 admin-area review): the facility_paperwork
-- module is enabled in facility_modules but is structurally excluded from the
-- permission model —
--   1. user_permissions.module_name CHECK does not allow 'facility_paperwork',
--      so no per-user grant can ever be written for it (the admin UI and
--      apply_role_permission_defaults() both fail).
--   2. canonical_role_permission_grants() has no facility_paperwork ceilings,
--      so new roles are seeded without it.
-- Net effect: current_user_has_permission('facility_paperwork', ...) can only
-- ever be true via the super-admin bypass.
--
-- NOTE: seeding facility_paperwork rows into role_permission_defaults BEFORE
-- widening the CHECK breaks apply_role_permission_defaults() for every role
-- (the insert..select trips the constraint wholesale). This migration does the
-- constraint first for exactly that reason. A live seeding attempt on
-- 2026-07-06 hit this and was fully reverted; prod has no facility_paperwork
-- permission rows today.

begin;

-- 1) Allow the module in per-user permissions.
alter table public.user_permissions
  drop constraint user_permissions_module_name_check;
alter table public.user_permissions
  add constraint user_permissions_module_name_check
  check (module_name = any (array[
    'daily_reports','ice_depth','ice_operations','incident_reports',
    'accident_reports','refrigeration','air_quality','scheduling',
    'communications','facility_paperwork','admin']));

-- 2) Add facility_paperwork ceilings to the canonical grant matrix.
--    Recreate canonical_role_permission_grants() from its current definition,
--    adding these rows to the ceilings VALUES list (document library:
--    admins manage, everyone else reads):
--      ('super_admin','facility_paperwork','admin'::public.user_action),
--      ('admin','facility_paperwork','admin'::public.user_action),
--      ('gm','facility_paperwork','admin'::public.user_action),
--      ('manager','facility_paperwork','admin'::public.user_action),
--      ('supervisor','facility_paperwork','view'::public.user_action),
--      ('staff','facility_paperwork','view'::public.user_action),
--      ('driver','facility_paperwork','view'::public.user_action),
--    (Manager gets 'admin' for consistency: manager == admin ceiling on every
--    other module in the current matrix. Lower to 'view' here if paperwork
--    should be tighter.)
--    The full function body lives in the repo; edit it there rather than
--    pasting a drifted copy from this file.

-- 3) Backfill role_permission_defaults for existing facilities/roles
--    (same expansion the role-creation trigger uses).
insert into public.role_permission_defaults (facility_id, role_id, module_name, action, enabled)
select r.facility_id, r.id, g.module_name, g.action, true
from public.roles r
join public.canonical_role_permission_grants() g on g.role_key = r.key
where g.module_name = 'facility_paperwork'
on conflict (facility_id, role_id, module_name, action) do nothing;

-- 4) Propagate to users who have employee records (preserves manual overrides;
--    skips super-admins by design).
do $$
declare rec record;
begin
  for rec in
    select e.user_id, e.facility_id, e.role_id
    from public.employees e
    where e.user_id is not null and e.is_active
  loop
    perform public.apply_role_permission_defaults(rec.user_id, rec.facility_id, rec.role_id);
  end loop;
end $$;

commit;
