-- Recovery Tracker - tenancy + authenticated access
-- Run this in the Supabase SQL editor AFTER v1.0.11 is deployed and you have
-- signed in successfully on one phone. Steps 1-3 are safe on their own; step 4
-- is the one that closes public access, so run it last.

-- ---------------------------------------------------------------
-- 1. Tenancy column. Existing rows inherit the current circle.
-- ---------------------------------------------------------------
alter table public.mom_recovery_records
  add column if not exists circle_id text not null default 'brodt-recovery';

-- ---------------------------------------------------------------
-- 2. Composite primary key so two households can each have a row
--    called 'settings' without colliding.
--    The app now sends circle_id on every write, so upserts still resolve.
-- ---------------------------------------------------------------
alter table public.mom_recovery_records
  drop constraint if exists mom_recovery_records_pkey;
alter table public.mom_recovery_records
  add constraint mom_recovery_records_pkey primary key (circle_id, id);

-- ---------------------------------------------------------------
-- 3. Index for the filtered reads the app now issues.
-- ---------------------------------------------------------------
create index if not exists mom_recovery_records_circle_idx
  on public.mom_recovery_records (circle_id);

-- ---------------------------------------------------------------
-- 4. Replace the wide-open anon policies with authenticated-only ones.
--    THIS IS THE STEP THAT CLOSES PUBLIC ACCESS.
--    Any phone still running v1.0.10 or earlier stops syncing after this.
-- ---------------------------------------------------------------
drop policy if exists mom_recovery_anon_select on public.mom_recovery_records;
drop policy if exists mom_recovery_anon_insert on public.mom_recovery_records;
drop policy if exists mom_recovery_anon_update on public.mom_recovery_records;
drop policy if exists mom_recovery_anon_delete on public.mom_recovery_records;

create policy mom_recovery_auth_select on public.mom_recovery_records
  for select to authenticated using (true);
create policy mom_recovery_auth_insert on public.mom_recovery_records
  for insert to authenticated with check (true);
create policy mom_recovery_auth_update on public.mom_recovery_records
  for update to authenticated using (true) with check (true);
create policy mom_recovery_auth_delete on public.mom_recovery_records
  for delete to authenticated using (true);

-- ---------------------------------------------------------------
-- Verify: should return four policies, all scoped to {authenticated}
-- ---------------------------------------------------------------
select policyname, cmd, roles::text
from pg_policies
where schemaname='public' and tablename='mom_recovery_records'
order by cmd;

-- ---------------------------------------------------------------
-- LATER, when a second household is added, tighten from "any signed-in
-- user sees everything" to real per-circle isolation. Sketch only - it
-- needs a memberships table first, mirroring groups/group_members:
--
--   create table public.circle_members (
--     circle_id text not null,
--     user_id uuid not null references auth.users(id),
--     primary key (circle_id, user_id)
--   );
--
--   -- then swap using (true) for:
--   using (circle_id in (select circle_id from public.circle_members
--                        where user_id = auth.uid()))
-- ---------------------------------------------------------------
