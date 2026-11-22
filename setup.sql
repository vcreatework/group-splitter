-- Student Group Splitter: run this once in Supabase > SQL Editor > New query > Run

create table if not exists public.students (
  id         bigint generated always as identity primary key,
  name       text not null check (length(trim(name)) > 0),
  phone      text not null check (length(trim(phone)) > 0),
  group_no   int  not null,
  created_at timestamptz not null default now()
);

create index if not exists students_group_no_idx on public.students (group_no);

-- Phone numbers are compared by digits only, with a leading 0 treated as +94,
-- and a bare 9-digit number treated as +94, so "077 123 4567", "771234567" and
-- "+94 77 123 4567" count as the same number.
create or replace function public.norm_phone(p text)
returns text language sql immutable set search_path = public as $f$
  select case when d like '0%' then '94' || substr(d, 2)
              when length(d) = 9 then '94' || d
              else d end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x
$f$;

-- One registration per phone number.
create unique index if not exists students_phone_unique on public.students (public.norm_phone(phone));

-- Adds a student and puts them in the first group that has fewer than 3 people.
-- If every group is full, a new group is started.
-- The advisory lock makes simultaneous adds wait their turn, so a group never gets 4.
create or replace function public.add_student(p_name text, p_phone text)
returns public.students
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group int;
  v_row   public.students;
  v_existing int;
begin
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_phone), '') = '' then
    raise exception 'Name and phone are required';
  end if;

  if length(public.norm_phone(p_phone)) < 9 then
    raise exception 'Please enter a full phone number';
  end if;

  perform pg_advisory_xact_lock(424242);

  select group_no into v_existing from public.students
  where public.norm_phone(phone) = public.norm_phone(p_phone) limit 1;
  if v_existing is not null then
    raise exception 'This phone number is already registered (Group %)', v_existing;
  end if;

  select g into v_group
  from generate_series(1, coalesce((select max(group_no) from public.students), 0) + 1) as g
  where (select count(*) from public.students s where s.group_no = g) < 3
  order by g
  limit 1;

  insert into public.students (name, phone, group_no)
  values (trim(p_name), trim(p_phone), v_group)
  returning * into v_row;

  return v_row;
end;
$$;

-- "Remove me": the page calls join_group with a random key it keeps in the browser.
-- Only a hash of the key is stored, and leave_group deletes the row only with the same key,
-- so a student can remove their own entry from the phone they registered on, and nobody else's.
alter table public.students add column if not exists remove_key text;

create or replace function public.join_group(p_name text, p_phone text, p_token text)
returns public.students
language plpgsql security definer set search_path = public as $$
declare v_row public.students;
begin
  if coalesce(length(p_token), 0) < 20 then raise exception 'Missing device key'; end if;
  v_row := public.add_student(p_name, p_phone);
  update public.students set remove_key = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
  where id = v_row.id returning * into v_row;
  return v_row;
end $$;

create or replace function public.leave_group(p_id bigint, p_token text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.students
  where id = p_id and remove_key is not null
    and remove_key = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex');
  get diagnostics n = row_count;
  return n = 1;
end $$;

-- Security: anyone with the site can read the list and add through the function,
-- but nobody can edit or delete rows directly from the browser.
alter table public.students enable row level security;

-- Privacy: visitors cannot read the table. They only see their own group through my_group(),
-- and the full list needs the admin password through admin_list().
drop policy if exists "anyone can read" on public.students;

revoke insert, update, delete on public.students from anon, authenticated;
grant select on public.students to anon, authenticated;
grant execute on function public.add_student(text, text) to anon, authenticated;
grant execute on function public.join_group(text, text, text) to anon, authenticated;
grant execute on function public.leave_group(bigint, text) to anon, authenticated;

-- Live updates: push new rows to every open browser.
do $$
begin
  alter publication supabase_realtime add table public.students;
exception when duplicate_object then null;
end $$;

-- ---- Private lookups and admin password ----
create schema if not exists gs_private;
revoke all on schema gs_private from public, anon, authenticated;
create table if not exists gs_private.settings (key text primary key, value text not null);
-- Set the admin password (change CHANGE-ME, keep the salt random):
insert into gs_private.settings values
  ('admin_salt', md5(random()::text)),
  ('admin_hash', '')
on conflict (key) do nothing;
update gs_private.settings set value = encode(sha256(convert_to(
  (select value from gs_private.settings where key = 'admin_salt') || 'CHANGE-ME', 'UTF8')), 'hex')
where key = 'admin_hash' and value = '';

create or replace function gs_private.is_admin(p_password text)
returns boolean language sql stable security definer set search_path = gs_private, public as $$
  select coalesce((select value from gs_private.settings where key = 'admin_hash') =
    encode(sha256(convert_to((select value from gs_private.settings where key = 'admin_salt') || coalesce(p_password, ''), 'UTF8')), 'hex'), false)
$$;

create or replace function public.my_group(p_phone text)
returns table (id bigint, name text, phone text, group_no int)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.phone, s.group_no from public.students s
  where s.group_no = (select group_no from public.students
                      where public.norm_phone(phone) = public.norm_phone(p_phone)
                        and length(public.norm_phone(p_phone)) >= 9 limit 1)
  order by s.id
$$;

create or replace function public.group_stats()
returns table (students bigint, groups bigint)
language sql stable security definer set search_path = public as $$
  select count(*), count(distinct group_no) from public.students
$$;

create or replace function public.admin_list(p_password text)
returns table (id bigint, name text, phone text, group_no int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not gs_private.is_admin(p_password) then
    perform pg_sleep(1);
    raise exception 'Wrong password';
  end if;
  return query select s.id, s.name, s.phone, s.group_no from public.students s order by s.id;
end $$;

revoke execute on function gs_private.is_admin(text) from public;
grant execute on function public.my_group(text) to anon, authenticated;
grant execute on function public.group_stats() to anon, authenticated;
grant execute on function public.admin_list(text) to anon, authenticated;
