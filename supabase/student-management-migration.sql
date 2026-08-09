alter table students add column if not exists status text not null default '재원생';
alter table students add column if not exists current_course text;
alter table students add column if not exists enrollment_date date;
