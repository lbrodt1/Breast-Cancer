-- ============================================================
--  OktoHands - schema built to survive a HIPAA obligation later
--  Run once, in a NEW Supabase project's SQL editor.
--
--  What this adds over a simple table:
--    * per-user accounts, not a shared login   (unique user identification)
--    * membership-scoped access                (minimum necessary)
--    * append-only audit trail via trigger     (the client cannot skip it)
--    * soft delete                             (retention / amendment)
--    * roles: owner / caregiver / viewer
-- ============================================================

-- ------------------------------------------------------------
-- 1. Circles - one care situation
-- ------------------------------------------------------------
create table if not exists public.circles (
  id           text primary key,
  name         text not null,
  subject_type text not null default 'patient'
               check (subject_type in ('patient','elder','sitter','pet','postpartum','athlete','student','trainee')),
  created_at   timestamptz not null default now(),
  created_by   uuid references auth.users(id)
);

-- ------------------------------------------------------------
-- 2. Membership
-- ------------------------------------------------------------
create table if not exists public.circle_members (
  circle_id    text not null references public.circles(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         text not null default 'caregiver'
               check (role in ('owner','caregiver','viewer')),
  display_name text,
  added_at     timestamptz not null default now(),
  primary key (circle_id, user_id)
);
create index if not exists circle_members_user_idx on public.circle_members (user_id);

-- security definer so policies can call these without recursing into
-- circle_members' own RLS. search_path locked per Supabase lint guidance.
create or replace function public.is_member(c text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.circle_members
                 where circle_id = c and user_id = auth.uid());
$$;

create or replace function public.can_write(c text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.circle_members
                 where circle_id = c and user_id = auth.uid()
                   and role in ('owner','caregiver'));
$$;

create or replace function public.is_owner(c text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.circle_members
                 where circle_id = c and user_id = auth.uid() and role = 'owner');
$$;

-- ------------------------------------------------------------
-- 3. Records - soft delete, server-stamped writer
-- ------------------------------------------------------------
create table if not exists public.tracking_records (
  id         text        not null,
  circle_id  text        not null references public.circles(id) on delete cascade,
  kind       text        not null,
  data       jsonb       not null,
  deleted_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  primary key (circle_id, id)
);
create index if not exists tracking_records_live_idx
  on public.tracking_records (circle_id) where deleted_at is null;

-- ------------------------------------------------------------
-- 4. Audit log - append only, written by trigger
-- ------------------------------------------------------------
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       uuid,
  circle_id   text,
  action      text not null,
  record_id   text,
  record_kind text
);
create index if not exists audit_log_circle_at_idx on public.audit_log (circle_id, at desc);

create or replace function public.log_record_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare act text;
begin
  if tg_op = 'INSERT' then act := 'create';
  elsif tg_op = 'DELETE' then act := 'hard_delete';
  elsif new.deleted_at is not null and old.deleted_at is null then act := 'delete';
  else act := 'update';
  end if;

  insert into public.audit_log (actor, circle_id, action, record_id, record_kind)
  values (auth.uid(),
          coalesce(new.circle_id, old.circle_id),
          act,
          coalesce(new.id, old.id),
          coalesce(new.kind, old.kind));
  return coalesce(new, old);
end $$;

drop trigger if exists tracking_records_audit on public.tracking_records;
create trigger tracking_records_audit
  after insert or update or delete on public.tracking_records
  for each row execute function public.log_record_change();

-- stamp the writer server-side so a client cannot claim to be someone else
create or replace function public.stamp_writer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists tracking_records_stamp on public.tracking_records;
create trigger tracking_records_stamp
  before insert or update on public.tracking_records
  for each row execute function public.stamp_writer();

-- ------------------------------------------------------------
-- 5. Row level security
-- ------------------------------------------------------------
alter table public.circles          enable row level security;
alter table public.circle_members   enable row level security;
alter table public.tracking_records enable row level security;
alter table public.audit_log        enable row level security;

drop policy if exists circles_select on public.circles;
drop policy if exists circles_update on public.circles;
create policy circles_select on public.circles
  for select to authenticated using (public.is_member(id));
create policy circles_update on public.circles
  for update to authenticated using (public.is_owner(id)) with check (public.is_owner(id));

drop policy if exists circle_members_select on public.circle_members;
drop policy if exists circle_members_insert on public.circle_members;
drop policy if exists circle_members_delete on public.circle_members;
create policy circle_members_select on public.circle_members
  for select to authenticated using (public.is_member(circle_id));
create policy circle_members_insert on public.circle_members
  for insert to authenticated with check (public.is_owner(circle_id));
create policy circle_members_delete on public.circle_members
  for delete to authenticated using (public.is_owner(circle_id));

drop policy if exists tracking_select on public.tracking_records;
drop policy if exists tracking_insert on public.tracking_records;
drop policy if exists tracking_update on public.tracking_records;
create policy tracking_select on public.tracking_records
  for select to authenticated using (public.is_member(circle_id));
create policy tracking_insert on public.tracking_records
  for insert to authenticated with check (public.can_write(circle_id));
create policy tracking_update on public.tracking_records
  for update to authenticated using (public.can_write(circle_id))
                                with check (public.can_write(circle_id));
-- no DELETE policy on purpose: removal sets deleted_at

drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log
  for select to authenticated using (public.is_owner(circle_id));

-- ============================================================
--  SEED - edit the email, then run
-- ============================================================
insert into public.circles (id, name, subject_type)
values ('patient-recovery', 'Recovery', 'patient')
on conflict (id) do nothing;

insert into public.circle_members (circle_id, user_id, role, display_name)
select 'patient-recovery', id, 'owner', 'Laura'
from auth.users where email = 'YOU@EXAMPLE.COM'
on conflict (circle_id, user_id) do update set role = 'owner';

-- For each additional caregiver, first create their account in
-- Authentication -> Users -> Add user (tick Auto Confirm User), then:
--
-- insert into public.circle_members (circle_id, user_id, role, display_name)
-- select 'patient-recovery', id, 'caregiver', 'Dana'
-- from auth.users where email = 'DANA@EXAMPLE.COM'
-- on conflict (circle_id, user_id) do nothing;

-- ============================================================
--  VERIFY - expect 4 tables, RLS true on all, and one owner row
-- ============================================================
select c.relname as table_name, c.relrowsecurity as rls_on,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as policies
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by 1;

select circle_id, role, display_name from public.circle_members;
