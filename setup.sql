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

-- Security: anyone with the site can read the list and add through the function,
-- but nobody can edit or delete rows directly from the browser.
alter table public.students enable row level security;

drop policy if exists "anyone can read" on public.students;
create policy "anyone can read" on public.students for select using (true);

revoke insert, update, delete on public.students from anon, authenticated;
grant select on public.students to anon, authenticated;
grant execute on function public.add_student(text, text) to anon, authenticated;

-- Live updates: push new rows to every open browser.
do $$
begin
  alter publication supabase_realtime add table public.students;
exception when duplicate_object then null;
end $$;
