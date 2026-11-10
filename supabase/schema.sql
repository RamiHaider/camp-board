-- Camp Bed Board schema. Run once on a fresh project.

create extension if not exists pgcrypto;

-- Who may run the board. Add an email here to make someone an admin.
create table if not exists admins (
  email text primary key,
  added_at timestamptz not null default now()
);

-- Single-row settings. request_code is the short code requesters type (posted on the kitchen wall).
create table if not exists settings (
  id text primary key default 'main' check (id = 'main'),
  request_code text not null default 'CAMP',
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
alter table admins    enable row level security;
alter table settings  enable row level security;
alter table companies enable row level security;
alter table layout    enable row level security;
alter table stays     enable row level security;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where lower(email) = lower(coalesce(auth.jwt()->>'email','')));
$$;

-- admins: full access to everything
drop policy if exists admin_all on admins;    create policy admin_all on admins    for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists admin_all on settings;  create policy admin_all on settings  for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists admin_all on companies; create policy admin_all on companies for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists admin_all on layout;    create policy admin_all on layout    for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists admin_all on stays;     create policy admin_all on stays     for all to authenticated using (is_admin()) with check (is_admin());

-- anyone: may read company names for the request form dropdown. Nothing else.
drop policy if exists anon_read_companies on companies;
create policy anon_read_companies on companies for select to anon, authenticated using (true);

-- anyone with the camp code: submit a request. This is the ONLY write path for requesters.
create or replace function submit_request(
  p_code text, p_name text, p_company text, p_arrive date, p_depart date, p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not exists (select 1 from settings where id = 'main' and upper(request_code) = upper(trim(coalesce(p_code,'')))) then
    raise exception 'Wrong camp code' using errcode = '28000';
  end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Name is required'; end if;
  if length(trim(coalesce(p_company,''))) < 1 then raise exception 'Company is required'; end if;
  if p_depart < p_arrive then raise exception 'Departure must be on or after arrival'; end if;
  if (select count(*) from stays where created_at > now() - interval '1 hour' and status = 'requested') > 200 then
    raise exception 'Too many requests right now, try later';
  end if;
  insert into companies (name) values (trim(p_company)) on conflict (lower(name)) do nothing;
  insert into stays (name, company, arrive, depart, notes)
    values (left(trim(p_name),120), left(trim(p_company),80), p_arrive, p_depart, left(coalesce(p_notes,''),500))
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
