-- Proposed migration for KellyJ386/Rink-Reports-5-6 (supabase/migrations/).
-- Rename with the next free numeric prefix before committing.
--
-- Hardens the four remaining RPC/public-surface findings from the 2026-07-06
-- admin-area review. Items 1 and 4 need a quick code check before applying —
-- each is marked with what to verify.

begin;

-- 1) check_rate_limit — the last function still executable by anon, and its
--    limits (p_max / p_window_seconds) are caller-supplied, so a direct RPC
--    caller can pick their own budget or spam junk buckets into
--    rate_limit_counters. It also fails OPEN on null/invalid params.
--    VERIFY FIRST: grep the app for .rpc('check_rate_limit'. If every call
--    site runs server-side (service role / route handlers), apply the revoke
--    below. If any call runs under the anon key (e.g. login flow), keep anon
--    EXECUTE but replace call sites with a fixed-budget wrapper so the client
--    never chooses its own limits.
revoke execute on function public.check_rate_limit(text, text, integer, integer)
  from anon, authenticated;

-- 2) get_employee_counts_by_facility — SECURITY DEFINER, no auth check,
--    returns employee counts for ALL facilities to any authenticated user.
--    Cross-tenant metadata leak once facility #2 onboards. It reads like a
--    super-admin dashboard helper; gate it as one.
create or replace function public.get_employee_counts_by_facility()
returns table (facility_id uuid, employee_count bigint)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not public.is_super_admin() then
    raise exception 'get_employee_counts_by_facility: super admin only';
  end if;
  return query
    select e.facility_id, count(*)::bigint
    from public.employees e
    group by e.facility_id;
end;
$$;

-- 3) scheduling_expire_open_claims / scheduling_expire_stale_swaps —
--    housekeeping jobs callable by any authenticated user with no facility
--    scoping; a staff member can force-expire claims/swaps across facilities
--    and generate notification spam. They should run only from the cron /
--    service role (service_role keeps EXECUTE implicitly as table owner path;
--    re-grant explicitly if the cron uses a dedicated role).
revoke execute on function public.scheduling_expire_open_claims(integer)
  from anon, authenticated;
revoke execute on function public.scheduling_expire_stale_swaps(integer)
  from anon, authenticated;
-- Also align their search_path with the house style (they pin 'public' only).
alter function public.scheduling_expire_open_claims(integer)
  set search_path to 'public', 'pg_temp';
alter function public.scheduling_expire_stale_swaps(integer)
  set search_path to 'public', 'pg_temp';

-- 4) information_requests — intentional public lead form (anon INSERT is by
--    design) but currently WITH CHECK (true) and no input constraints or rate
--    limit. Keep it public; make it abuse-resistant.
--    VERIFY FIRST: match these column limits against the marketing form's
--    actual validation so legitimate submissions can't be rejected.
alter table public.information_requests
  add constraint information_requests_name_len
    check (name is null or char_length(name) <= 200),
  add constraint information_requests_email_format
    check (email is null or (char_length(email) <= 320 and email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  add constraint information_requests_company_len
    check (company is null or char_length(company) <= 200),
  add constraint information_requests_note_len
    check (note is null or char_length(note) <= 5000);

-- Server-side rate limit: 5 submissions/hour per email (plus a coarse global
-- hourly cap so rotating emails doesn't bypass it). Uses the existing
-- fixed-window counter machinery.
create or replace function public.rate_limit_information_requests()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not public.check_rate_limit('information_requests_email', coalesce(lower(new.email), 'missing'), 5, 3600) then
    raise exception 'Too many requests; please try again later.';
  end if;
  if not public.check_rate_limit('information_requests_global', 'all', 100, 3600) then
    raise exception 'Too many requests; please try again later.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_rate_limit_information_requests on public.information_requests;
create trigger trg_rate_limit_information_requests
  before insert on public.information_requests
  for each row execute function public.rate_limit_information_requests();

commit;

-- Not in this migration (needs a decision / different surface):
-- * Leaked-password protection (HIBP): Supabase Dashboard → Auth → Settings,
--   one toggle. Still disabled as of 2026-07-06.
-- * Stranded auth users (kellygjohnson@yahoo.com, geeka386@yahoo.com): link to
--   employee records or deactivate — owner's call.
-- * role_module_permission_defaults (deprecated, 20 rows): drop once the
--   admin/roles page is confirmed off it (its comment says migration 77).
