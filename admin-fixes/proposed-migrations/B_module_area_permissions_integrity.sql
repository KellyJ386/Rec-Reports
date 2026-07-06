-- Proposed migration for KellyJ386/Rink-Reports-5-6 (supabase/migrations/).
-- Rename with the next free numeric prefix before committing.
--
-- Problem: module_area_permissions.area_id is a soft reference by design
-- ("callers must validate"), but nothing enforces it and area deletion leaves
-- grants behind. In production, 15 of 26 rows were orphaned (grants pointing
-- at daily_report_areas deleted ~2026-05-31). The orphans were purged live on
-- 2026-07-06 (snapshot: admin-fixes/orphaned-module-area-permissions.snapshot.json);
-- this migration adds the enforcement so it cannot recur, plus an idempotent
-- re-purge for environments rebuilt from migrations.

begin;

-- 1) Idempotent purge (no-op in prod after the 2026-07-06 cleanup).
delete from public.module_area_permissions map
where map.module_key = 'daily_reports'
  and not exists (select 1 from public.daily_report_areas a where a.id = map.area_id);

-- 2) Validate area on write. daily_reports is the only module using per-area
--    permissions today; extend the CASE as other modules adopt areas.
create or replace function public.validate_module_area_permission()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
begin
  if new.module_key = 'daily_reports' then
    if not exists (
      select 1 from public.daily_report_areas a
      where a.id = new.area_id and a.facility_id = new.facility_id
    ) then
      raise exception
        'module_area_permissions: area % does not exist in facility % for module daily_reports',
        new.area_id, new.facility_id;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validate_module_area_permission on public.module_area_permissions;
create trigger trg_validate_module_area_permission
  before insert or update of area_id, module_key, facility_id
  on public.module_area_permissions
  for each row execute function public.validate_module_area_permission();

-- 3) Clean up grants when an area is deleted (mirrors an FK ON DELETE CASCADE,
--    which cannot be used here because the target table varies by module_key).
create or replace function public.cleanup_daily_report_area_permissions()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
begin
  delete from public.module_area_permissions
  where module_key = 'daily_reports' and area_id = old.id;
  return old;
end;
$$;

drop trigger if exists trg_cleanup_daily_report_area_permissions on public.daily_report_areas;
create trigger trg_cleanup_daily_report_area_permissions
  after delete on public.daily_report_areas
  for each row execute function public.cleanup_daily_report_area_permissions();

commit;
