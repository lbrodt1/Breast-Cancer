-- ============================================================
--  Recovery Tracker - fresh setup on a NEW Supabase project
--  Run this once, in the new project's SQL editor.
--  Creates the table, tenancy, index, and authenticated-only policies
--  in their final state. Nothing to migrate - the old project holds
--  a single throwaway settings row.
-- ============================================================

create table if not exists public.tracking_records (
  id         text        not null,
  kind       text        not null,
  data       jsonb       not null,
  circle_id  text        not null default 'default',
  updated_at timestamptz not null default now(),
  primary key (circle_id, id)
);

create index if not exists tracking_records_circle_idx
  on public.tracking_records (circle_id);

alter table public.tracking_records enable row level security;

-- Signed-in users only. The publishable key alone gets you nothing.
drop policy if exists tracking_auth_select on public.tracking_records;
drop policy if exists tracking_auth_insert on public.tracking_records;
drop policy if exists tracking_auth_update on public.tracking_records;
drop policy if exists tracking_auth_delete on public.tracking_records;

create policy tracking_auth_select on public.tracking_records
  for select to authenticated using (true);
create policy tracking_auth_insert on public.tracking_records
  for insert to authenticated with check (true);
create policy tracking_auth_update on public.tracking_records
  for update to authenticated using (true) with check (true);
create policy tracking_auth_delete on public.tracking_records
  for delete to authenticated using (true);

-- ------------------------------------------------------------
-- Verify: four policies, all {authenticated}, and RLS on.
-- ------------------------------------------------------------
select policyname, cmd, roles::text
from pg_policies
where schemaname = 'public' and tablename = 'tracking_records'
order by cmd;

select relrowsecurity as rls_enabled
from pg_class
where oid = 'public.tracking_records'::regclass;

-- ------------------------------------------------------------
-- LATER, for real multi-household isolation. Right now any signed-in
-- user can read every circle, which is fine while there is one.
--
--   create table public.circle_members (
--     circle_id text not null,
--     user_id   uuid not null references auth.users(id) on delete cascade,
--     primary key (circle_id, user_id)
--   );
--   alter table public.circle_members enable row level security;
--   create policy circle_members_self on public.circle_members
--     for select to authenticated using (user_id = auth.uid());
--
--   -- then replace using (true) on the four policies above with:
--   using (circle_id in (
--     select circle_id from public.circle_members where user_id = auth.uid()
--   ))
-- ------------------------------------------------------------
