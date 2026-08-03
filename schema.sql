create table if not exists students (
  id text primary key,
  name text not null,
  school text,
  grade text,
  days text,
  access_code text unique,
  created_at timestamptz not null default now()
);

alter table students add column if not exists access_code text;
create unique index if not exists students_access_code_idx
  on students(access_code)
  where access_code is not null;

create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('teacher', 'student')) default 'student',
  student_id text references students(id) on delete set null,
  display_name text,
  created_at timestamptz not null default now()
);

create table if not exists textbooks (
  id text primary key,
  category text not null,
  name text not null,
  chapter text,
  total_units integer not null default 1,
  created_at timestamptz not null default now()
);

create table if not exists monthly_tests (
  id text primary key,
  student_id text not null references students(id) on delete cascade,
  month text not null,
  section text not null,
  range text,
  score numeric,
  previous numeric,
  updated_at timestamptz not null default now()
);

create table if not exists word_tests (
  id text primary key,
  student_id text not null references students(id) on delete cascade,
  date date not null,
  book_id text references textbooks(id) on delete set null,
  unit_text text,
  unit integer,
  range text,
  score numeric,
  max numeric,
  memorized integer default 0,
  updated_at timestamptz not null default now()
);

create table if not exists progress_logs (
  id text primary key,
  student_id text not null references students(id) on delete cascade,
  date date not null,
  category text,
  book_id text references textbooks(id) on delete set null,
  unit integer,
  units jsonb not null default '[]'::jsonb,
  lesson text,
  manual_lesson text,
  homework text,
  memo text,
  updated_at timestamptz not null default now()
);

create table if not exists counseling_records (
  id text primary key,
  student_id text not null references students(id) on delete cascade,
  date date not null,
  type text,
  target text,
  topic text,
  content text,
  action text,
  follow_date date,
  updated_at timestamptz not null default now()
);

create table if not exists observations (
  id text primary key,
  student_id text not null references students(id) on delete cascade,
  month text not null,
  attitude text,
  strength text,
  weakness text,
  plan text,
  comment text,
  updated_at timestamptz not null default now()
);

create table if not exists daily_statuses (
  id text primary key,
  student_id text not null references students(id) on delete cascade,
  date date not null,
  arrival_time text,
  attendance text,
  updated_at timestamptz not null default now()
);

create table if not exists word_memory_checks (
  key text primary key,
  student_id text not null references students(id) on delete cascade,
  checked boolean not null default false,
  memorized integer not null default 0,
  updated_at timestamptz not null default now()
);

create or replace function is_teacher()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid()
      and role = 'teacher'
  );
$$;

create or replace function own_student_id()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select student_id from profiles where id = auth.uid();
$$;

create or replace function student_pin_login(p_access_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_id text;
  attendance_date date;
  attendance_time text;
  attendance_id text;
begin
  select id into target_id
  from students
  where access_code = p_access_code;

  if target_id is null then
    raise exception 'invalid_student_code';
  end if;

  attendance_date := (clock_timestamp() at time zone 'Asia/Seoul')::date;
  attendance_time := to_char(clock_timestamp() at time zone 'Asia/Seoul', 'HH24:MI');
  attendance_id := 'daily-' || target_id || '-' || attendance_date::text;

  insert into daily_statuses(id, student_id, date, arrival_time, attendance, updated_at)
  values (attendance_id, target_id, attendance_date, attendance_time, '출석', now())
  on conflict (id)
  do update set
    arrival_time = coalesce(nullif(daily_statuses.arrival_time, ''), excluded.arrival_time),
    attendance = case
      when daily_statuses.attendance is null or daily_statuses.attendance in ('미확인', '결석') then '출석'
      else daily_statuses.attendance
    end,
    updated_at = now();

  return jsonb_build_object(
    'students', coalesce((select jsonb_agg(row_to_json(s)) from (
      select id, name, school, grade, days, access_code
      from students
      where id = target_id
    ) s), '[]'::jsonb),
    'textbooks', coalesce((select jsonb_agg(row_to_json(t)) from (
      select id, category, name, chapter, total_units
      from textbooks
    ) t), '[]'::jsonb),
    'monthly_tests', coalesce((select jsonb_agg(row_to_json(m)) from (
      select id, student_id, month, section, range, score, previous
      from monthly_tests
      where student_id = target_id
    ) m), '[]'::jsonb),
    'word_tests', coalesce((select jsonb_agg(row_to_json(w)) from (
      select id, student_id, date, book_id, unit_text, unit, range, score, max, memorized
      from word_tests
      where student_id = target_id
    ) w), '[]'::jsonb),
    'progress_logs', coalesce((select jsonb_agg(row_to_json(p)) from (
      select id, student_id, date, category, book_id, unit, units, lesson, manual_lesson, homework, memo
      from progress_logs
      where student_id = target_id
    ) p), '[]'::jsonb),
    'daily_statuses', coalesce((select jsonb_agg(row_to_json(d)) from (
      select id, student_id, date, arrival_time, attendance
      from daily_statuses
      where student_id = target_id
    ) d), '[]'::jsonb),
    'word_memory_checks', coalesce((select jsonb_agg(row_to_json(c)) from (
      select key, student_id, checked, memorized, updated_at
      from word_memory_checks
      where student_id = target_id
    ) c), '[]'::jsonb),
    'counseling_records', '[]'::jsonb,
    'observations', '[]'::jsonb
  );
end;
$$;

create or replace function student_memory_check_upsert(
  p_access_code text,
  p_key text,
  p_checked boolean,
  p_memorized integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_id text;
begin
  select id into target_id
  from students
  where access_code = p_access_code;

  if target_id is null then
    raise exception 'invalid_student_code';
  end if;

  insert into word_memory_checks(key, student_id, checked, memorized, updated_at)
  values (p_key, target_id, coalesce(p_checked, false), greatest(coalesce(p_memorized, 0), 0), now())
  on conflict (key)
  do update set
    checked = excluded.checked,
    memorized = excluded.memorized,
    updated_at = now()
  where word_memory_checks.student_id = target_id;

  return jsonb_build_object('ok', true, 'student_id', target_id);
end;
$$;

grant execute on function student_pin_login(text) to anon, authenticated;
grant execute on function student_memory_check_upsert(text, text, boolean, integer) to anon, authenticated;

alter table students enable row level security;
alter table profiles enable row level security;
alter table textbooks enable row level security;
alter table monthly_tests enable row level security;
alter table word_tests enable row level security;
alter table progress_logs enable row level security;
alter table counseling_records enable row level security;
alter table observations enable row level security;
alter table daily_statuses enable row level security;
alter table word_memory_checks enable row level security;

drop policy if exists "profiles can read own or teacher can read all" on profiles;
drop policy if exists "profiles can insert own" on profiles;
drop policy if exists "profiles can update own or teacher can update all" on profiles;
drop policy if exists "students read teacher or own" on students;
drop policy if exists "students teacher insert" on students;
drop policy if exists "students teacher update" on students;
drop policy if exists "students teacher delete" on students;
drop policy if exists "textbooks read authenticated" on textbooks;
drop policy if exists "textbooks teacher insert" on textbooks;
drop policy if exists "textbooks teacher update" on textbooks;
drop policy if exists "textbooks teacher delete" on textbooks;
drop policy if exists "monthly read teacher or own" on monthly_tests;
drop policy if exists "monthly teacher insert" on monthly_tests;
drop policy if exists "monthly teacher update" on monthly_tests;
drop policy if exists "monthly teacher delete" on monthly_tests;
drop policy if exists "word tests read teacher or own" on word_tests;
drop policy if exists "word tests teacher insert" on word_tests;
drop policy if exists "word tests teacher update" on word_tests;
drop policy if exists "word tests teacher delete" on word_tests;
drop policy if exists "progress read teacher or own" on progress_logs;
drop policy if exists "progress teacher insert" on progress_logs;
drop policy if exists "progress teacher update" on progress_logs;
drop policy if exists "progress teacher delete" on progress_logs;
drop policy if exists "counseling teacher read" on counseling_records;
drop policy if exists "counseling teacher insert" on counseling_records;
drop policy if exists "counseling teacher update" on counseling_records;
drop policy if exists "counseling teacher delete" on counseling_records;
drop policy if exists "observations teacher read" on observations;
drop policy if exists "observations teacher insert" on observations;
drop policy if exists "observations teacher update" on observations;
drop policy if exists "observations teacher delete" on observations;
drop policy if exists "daily read teacher or own" on daily_statuses;
drop policy if exists "daily teacher insert" on daily_statuses;
drop policy if exists "daily teacher update" on daily_statuses;
drop policy if exists "daily teacher delete" on daily_statuses;
drop policy if exists "memory read teacher or own" on word_memory_checks;
drop policy if exists "memory insert teacher or own" on word_memory_checks;
drop policy if exists "memory update teacher or own" on word_memory_checks;
drop policy if exists "memory teacher delete" on word_memory_checks;

create policy "profiles can read own or teacher can read all" on profiles
  for select using (id = auth.uid() or is_teacher());
create policy "profiles can insert own" on profiles
  for insert with check (id = auth.uid() and role = 'student');
create policy "profiles can update own or teacher can update all" on profiles
  for update using (is_teacher())
  with check (is_teacher());

create policy "students read teacher or own" on students
  for select using (is_teacher() or id = own_student_id());
create policy "students teacher insert" on students
  for insert with check (is_teacher());
create policy "students teacher update" on students
  for update using (is_teacher()) with check (is_teacher());
create policy "students teacher delete" on students
  for delete using (is_teacher());

create policy "textbooks read authenticated" on textbooks
  for select using (auth.uid() is not null);
create policy "textbooks teacher insert" on textbooks
  for insert with check (is_teacher());
create policy "textbooks teacher update" on textbooks
  for update using (is_teacher()) with check (is_teacher());
create policy "textbooks teacher delete" on textbooks
  for delete using (is_teacher());

create policy "monthly read teacher or own" on monthly_tests
  for select using (is_teacher() or student_id = own_student_id());
create policy "monthly teacher insert" on monthly_tests
  for insert with check (is_teacher());
create policy "monthly teacher update" on monthly_tests
  for update using (is_teacher()) with check (is_teacher());
create policy "monthly teacher delete" on monthly_tests
  for delete using (is_teacher());

create policy "word tests read teacher or own" on word_tests
  for select using (is_teacher() or student_id = own_student_id());
create policy "word tests teacher insert" on word_tests
  for insert with check (is_teacher());
create policy "word tests teacher update" on word_tests
  for update using (is_teacher()) with check (is_teacher());
create policy "word tests teacher delete" on word_tests
  for delete using (is_teacher());

create policy "progress read teacher or own" on progress_logs
  for select using (is_teacher() or student_id = own_student_id());
create policy "progress teacher insert" on progress_logs
  for insert with check (is_teacher());
create policy "progress teacher update" on progress_logs
  for update using (is_teacher()) with check (is_teacher());
create policy "progress teacher delete" on progress_logs
  for delete using (is_teacher());

create policy "counseling teacher read" on counseling_records
  for select using (is_teacher());
create policy "counseling teacher insert" on counseling_records
  for insert with check (is_teacher());
create policy "counseling teacher update" on counseling_records
  for update using (is_teacher()) with check (is_teacher());
create policy "counseling teacher delete" on counseling_records
  for delete using (is_teacher());

create policy "observations teacher read" on observations
  for select using (is_teacher());
create policy "observations teacher insert" on observations
  for insert with check (is_teacher());
create policy "observations teacher update" on observations
  for update using (is_teacher()) with check (is_teacher());
create policy "observations teacher delete" on observations
  for delete using (is_teacher());

create policy "daily read teacher or own" on daily_statuses
  for select using (is_teacher() or student_id = own_student_id());
create policy "daily teacher insert" on daily_statuses
  for insert with check (is_teacher());
create policy "daily teacher update" on daily_statuses
  for update using (is_teacher()) with check (is_teacher());
create policy "daily teacher delete" on daily_statuses
  for delete using (is_teacher());

create policy "memory read teacher or own" on word_memory_checks
  for select using (is_teacher() or student_id = own_student_id());
create policy "memory insert teacher or own" on word_memory_checks
  for insert with check (is_teacher() or student_id = own_student_id());
create policy "memory update teacher or own" on word_memory_checks
  for update using (is_teacher() or student_id = own_student_id())
  with check (is_teacher() or student_id = own_student_id());
create policy "memory teacher delete" on word_memory_checks
  for delete using (is_teacher());
