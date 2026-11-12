-- Camp Bed Board schema. Run once on a fresh project.

create extension if not exists pgcrypto;

-- Who may open the board. role 'admin' can change everything, 'viewer' can only look.
create table if not exists members (
  email text primary key,
  role text not null default 'admin' check (role in ('admin','viewer')),
  added_at timestamptz not null default now()
);

-- Single-row settings (reserved for future options).
create table if not exists settings (
  id text primary key default 'main' check (id = 'main'),
  updated_at timestamptz not null default now()
);
insert into settings (id) values ('main') on conflict do nothing;

create table if not exists companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  color text not null default '#7a8a84',
  created_at timestamptz not null default now()
);
create unique index if not exists companies_name_ci on companies (lower(name));

create table if not exists layout (
  id text primary key default 'main' check (id = 'main'),
  sections jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists stays (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  company text not null,
  arrive date not null,
  depart date not null,
  notes text not null default '',
  bed text,
  requester_email text,
  status text not null default 'requested'
    check (status in ('requested','assigned','checked_out','declined')),
  created_at timestamptz not null default now(),
  assigned_at timestamptz,
  closed_at timestamptz,
  check (depart >= arrive)
);
create index if not exists stays_status_idx on stays (status);
create index if not exists stays_bed_idx on stays (bed);

-- ---------- security ----------
alter table members   enable row level security;
alter table settings  enable row level security;
alter table companies enable row level security;
alter table layout    enable row level security;
alter table stays     enable row level security;

create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from members where lower(email) = lower(coalesce(auth.jwt()->>'email','')) limit 1;
$$;
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$ select coalesce(my_role() = 'admin', false); $$;
create or replace function is_member() returns boolean
language sql stable security definer set search_path = public as $$ select my_role() is not null; $$;
revoke all on function my_role() from public, anon;  grant execute on function my_role() to authenticated;
revoke all on function is_member() from public, anon; grant execute on function is_member() to authenticated;

-- admins: full access to everything
drop policy if exists admin_all on members;   create policy admin_all on members   for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists admin_all on settings;  create policy admin_all on settings  for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists admin_all on companies; create policy admin_all on companies for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists admin_all on layout;    create policy admin_all on layout    for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists admin_all on stays;     create policy admin_all on stays     for all to authenticated using (is_admin()) with check (is_admin());

-- viewers (any member) may read the board
drop policy if exists member_read on stays;     create policy member_read on stays     for select to authenticated using (is_member());
drop policy if exists member_read on layout;    create policy member_read on layout    for select to authenticated using (is_member());
drop policy if exists member_read on settings;  create policy member_read on settings  for select to authenticated using (is_member());

-- anyone: may read company names for the request form dropdown. Nothing else.
drop policy if exists anon_read_companies on companies;
create policy anon_read_companies on companies for select to anon, authenticated using (true);

-- anyone: submit a request. This is the ONLY write path for requesters.
-- A typed company is stored on the request only; the public dropdown (companies) is admin-managed.
create or replace function submit_request(
  p_email text, p_name text, p_company text, p_arrive date, p_depart date, p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if trim(coalesce(p_email,'')) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'A valid email is required'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Name is required'; end if;
  if length(trim(coalesce(p_company,''))) < 1 then raise exception 'Company is required'; end if;
  if p_depart < p_arrive then raise exception 'Departure must be on or after arrival'; end if;
  if (select count(*) from stays where created_at > now() - interval '1 hour' and status = 'requested') > 200 then
    raise exception 'Too many requests right now, try later';
  end if;
  insert into stays (name, company, arrive, depart, notes, requester_email)
    values (left(trim(p_name),120), left(trim(p_company),80), p_arrive, p_depart, left(coalesce(p_notes,''),500), lower(trim(p_email)))
    returning id into v_id;
  return v_id;
end $$;
revoke all on function submit_request(text,text,text,date,date,text) from public;
grant execute on function submit_request(text,text,text,date,date,text) to anon, authenticated;

-- live updates for the admin board
do $$ begin
  alter publication supabase_realtime add table stays;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table companies;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table layout;
exception when duplicate_object then null; end $$;

-- tighten grants flagged by the security advisor
revoke execute on function is_admin() from anon, public;
revoke execute on function rls_auto_enable() from anon, authenticated, public;

-- ---------- notifications (see supabase/functions/notify) ----------
create extension if not exists pg_net with schema extensions;
alter table stays add column if not exists req_arrive date;
alter table stays add column if not exists req_depart date;
alter table settings add column if not exists hook_secret text not null default encode(gen_random_bytes(24),'hex');
alter table settings add column if not exists notify_url text not null default 'https://dppmbpcbglloitnfkyaw.supabase.co/functions/v1/notify';
-- submit_request also fills req_arrive/req_depart (original request) — see migration "notifications".
-- Trigger notify_stay() posts {event, stay_id, old} to notify_url with header x-camp-hook = settings.hook_secret
-- on: insert (requested), status -> assigned, bed/date change while assigned (changed), status -> declined.
-- Edge Function secret needed: RESEND_API_KEY. From address noreply@mgmcamp.com (domain verified in Resend).

-- ---------- company portals + change requests (2026-11-12) ----------
-- members.role gains 'company'; members.company names the company that login manages.
alter table members drop constraint if exists admins_role_check;
alter table members add column if not exists company text;
create or replace function my_company() returns text
language sql stable security definer set search_path = public as $$
  select company from members where lower(email) = lower(coalesce(auth.jwt()->>'email','')) limit 1; $$;
create or replace function is_company() returns boolean
language sql stable security definer set search_path = public as $$ select coalesce(my_role() = 'company', false); $$;
revoke all on function my_company() from public, anon; grant execute on function my_company() to authenticated;
revoke all on function is_company() from public, anon; grant execute on function is_company() to authenticated;
-- admins and viewers read every stay; a company login reads only its own company's stays
drop policy if exists member_read on stays;
create policy member_read on stays for select to authenticated
  using (my_role() in ('admin','viewer') or (my_role() = 'company' and lower(company) = lower(coalesce(my_company(),''))));
-- settings (holds hook_secret) is admin-only
drop policy if exists member_read on settings;

-- shift: day or night, asked on the request form, editable by admins
alter table stays add column if not exists shift text not null default 'day' check (shift in ('day','night'));
-- submit_request(p_email, p_name, p_company, p_arrive, p_depart, p_notes, p_shift default 'day') replaces the 6-arg version.

-- a company asks to extend or move a stay; an admin approves (dates applied) or declines; both sides get email
create table if not exists change_requests (
  id uuid primary key default gen_random_uuid(),
  stay_id uuid not null references stays(id) on delete cascade,
  requested_by text not null,             -- contact email given by the company portal
  new_arrive date not null, new_depart date not null,
  note text not null default '',
  status text not null default 'pending' check (status in ('pending','approved','declined')),
  decision_note text not null default '',
  created_at timestamptz not null default now(), decided_at timestamptz
);
alter table change_requests enable row level security;
-- policies: admin_all (admins), company_read (own company's stays). Writes only through:
--   request_change(p_stay, p_arrive, p_depart, p_email, p_note)  -- company (own stays) or admin; replaces an older pending one
--   decide_change(p_id, p_approve, p_note)                       -- admin; approve applies the dates after a bed-clash check
-- trigger change_requests_notify -> notify_change() posts change_requested / change_decided to the notify function.
-- live definitions: migration applied 2026-11-12 through the Supabase MCP (see NOTES.md).
