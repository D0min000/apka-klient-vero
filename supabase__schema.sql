-- =====================================================================
-- Vero Studio: baza danych i uprawnienia (Supabase / Postgres)
--
-- Jak uruchomić: Supabase -> SQL Editor -> New query -> wklej całość -> Run.
-- Można uruchomić ponownie, nic się nie zdubluje.
--
-- WAŻNE: w linii oznaczonej "ZMIEŃ TU" wpisz adres Google właściciela,
-- czyli konto, którym Ty będziesz się logować do aplikacji.
-- =====================================================================

-- ---------- konfiguracja ----------
create table if not exists public.app_config (
  id int primary key default 1 check (id = 1),
  owner_email text not null
);
alter table public.app_config enable row level security;   -- bez polityk: nikt z zewnątrz tego nie czyta

insert into public.app_config (id, owner_email)
values (1, 'WPISZ_TU_SWOJ_ADRES@gmail.com')               -- <<< ZMIEŃ TU
on conflict (id) do nothing;

-- ---------- ludzie ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null default '',
  name text not null default '',
  avatar_url text,
  role text not null default 'worker' check (role in ('owner', 'worker')),
  approved boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.approved);
$$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'owner' and p.approved);
$$;

-- ---------- sesje, zapisy, wypłaty ----------
create table if not exists public.sessions (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 200),
  client text not null default '',
  event_date date not null,
  start_time text not null default '',
  location text not null default '',
  notes text not null default '',
  slots jsonb not null default '{}'::jsonb,
  inquiry_id uuid,
  created_at timestamptz not null default now()
);
alter table public.sessions enable row level security;

create table if not exists public.signups (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions (id) on delete cascade,
  role text not null check (role in ('photographer', 'videographer', 'photobooth')),
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (session_id, role, user_id)
);
alter table public.signups enable row level security;

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions (id) on delete cascade,
  role text not null check (role in ('photographer', 'videographer', 'photobooth')),
  user_id uuid not null references public.profiles (id) on delete cascade,
  amount numeric(10, 2) not null check (amount >= 0),
  paid_at timestamptz not null default now(),
  unique (session_id, role, user_id)
);
alter table public.payments enable row level security;

-- ---------- zapytania od klientów ----------
create table if not exists public.inquiries (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  status text not null default 'new' check (status in ('new', 'quoted', 'booked', 'declined')),
  source text not null default 'form',
  name text not null default '',
  email text not null default '',
  phone text not null default '',
  category text not null default 'inna',
  event_date date,
  start_time text not null default '',
  hours text not null default '',
  location text not null default '',
  guests text not null default '',
  services text[] not null default '{}',
  counts jsonb not null default '{}'::jsonb,
  details text not null default '',
  reply jsonb,
  session_id uuid references public.sessions (id) on delete set null
);
alter table public.inquiries enable row level security;
create index if not exists inquiries_email_created_idx on public.inquiries (lower(email), created_at);

-- ---------- uprawnienia do tabel ----------
-- Supabase domyślnie nadaje dostęp do nowych tabel, a ochronę zapewnia RLS.
-- Tu najpierw odbieramy wszystko, potem dajemy tylko to, co potrzebne.
revoke all on public.app_config, public.profiles, public.sessions, public.signups, public.payments, public.inquiries from anon, authenticated;

grant select (id, name, avatar_url, role, approved, created_at) on public.profiles to authenticated;
grant select on public.sessions, public.signups, public.payments to authenticated;
grant insert, update, delete on public.sessions to authenticated;
grant insert, delete on public.signups to authenticated;
grant insert, update, delete on public.payments to authenticated;
grant select, insert, update, delete on public.inquiries to authenticated;

-- ---------- polityki (RLS) ----------
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_approved());

drop policy if exists sessions_read on public.sessions;
create policy sessions_read on public.sessions for select to authenticated using (public.is_approved());
drop policy if exists sessions_write on public.sessions;
create policy sessions_write on public.sessions for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

drop policy if exists signups_read on public.signups;
create policy signups_read on public.signups for select to authenticated using (public.is_approved());
drop policy if exists signups_insert on public.signups;
create policy signups_insert on public.signups for insert to authenticated
  with check (
    public.is_approved()
    and user_id = auth.uid()
    and exists (select 1 from public.sessions s
                where s.id = session_id and s.event_date >= (now() at time zone 'Europe/Warsaw')::date)
  );
drop policy if exists signups_delete on public.signups;
create policy signups_delete on public.signups for delete to authenticated
  using (
    public.is_owner()
    or (public.is_approved()
        and user_id = auth.uid()
        and exists (select 1 from public.sessions s
                    where s.id = session_id and s.event_date >= (now() at time zone 'Europe/Warsaw')::date))
  );

drop policy if exists payments_read on public.payments;
create policy payments_read on public.payments for select to authenticated
  using (public.is_owner() or (public.is_approved() and user_id = auth.uid()));
drop policy if exists payments_write on public.payments;
create policy payments_write on public.payments for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

drop policy if exists inquiries_owner on public.inquiries;
create policy inquiries_owner on public.inquiries for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- ---------- funkcje wywoływane przez aplikację ----------

-- Tworzy profil po pierwszym logowaniu. Konto właściciela dostaje dostęp od razu,
-- reszta czeka na zatwierdzenie.
create or replace function public.ensure_profile() returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  mail text := lower(coalesce(auth.jwt() ->> 'email', ''));
  meta jsonb := coalesce(auth.jwt() -> 'user_metadata', '{}'::jsonb);
  owner_mail text;
  is_own boolean;
  result public.profiles;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  select lower(owner_email) into owner_mail from public.app_config where id = 1;
  is_own := mail <> '' and mail = owner_mail;

  insert into public.profiles (id, email, name, avatar_url, role, approved)
  values (
    uid, mail,
    coalesce(nullif(meta ->> 'full_name', ''), nullif(meta ->> 'name', ''), nullif(split_part(mail, '@', 1), ''), 'Pracownik'),
    nullif(meta ->> 'avatar_url', ''),
    case when is_own then 'owner' else 'worker' end,
    is_own
  )
  on conflict (id) do update set
    email = excluded.email,
    name = coalesce(nullif(excluded.name, ''), public.profiles.name),
    avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url)
  returning * into result;

  if is_own and (result.role <> 'owner' or not result.approved) then
    update public.profiles set role = 'owner', approved = true where id = uid returning * into result;
  end if;
  return result;
end $$;

-- Jedyna droga, którą klient (bez logowania) może zapisać zapytanie.
create or replace function public.submit_inquiry(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_name text := btrim(coalesce(p ->> 'name', ''));
  v_email text := lower(btrim(coalesce(p ->> 'email', '')));
  v_phone text := btrim(coalesce(p ->> 'phone', ''));
  v_cat text := coalesce(p ->> 'category', '');
  v_start text := btrim(coalesce(p ->> 'start', ''));
  v_hours text := btrim(coalesce(p ->> 'hours', ''));
  v_loc text := btrim(coalesce(p ->> 'location', ''));
  v_guests text := btrim(coalesce(p ->> 'guests', ''));
  v_details text := btrim(coalesce(p ->> 'details', ''));
  v_date date;
  v_services text[];
  v_counts jsonb := '{}'::jsonb;
  v_key text;
  v_n int;
  v_id uuid;
begin
  -- pole-pułapka dla botów: człowiek go nie widzi
  if coalesce(p ->> 'website', '') <> '' then
    return gen_random_uuid();
  end if;

  if char_length(v_name) not between 1 and 120 then raise exception 'invalid_input:name'; end if;
  if char_length(v_email) > 200 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid_input:email'; end if;
  if char_length(v_phone) > 40 then raise exception 'invalid_input:phone'; end if;
  if v_cat not in ('wesele', 'osiemnastka', 'rodzinna', 'prywatna', 'firmowa', 'inna') then raise exception 'invalid_input:category'; end if;
  if v_start <> '' and v_start !~ '^\d{2}:\d{2}$' then raise exception 'invalid_input:start'; end if;
  if char_length(v_hours) > 60 then raise exception 'invalid_input:hours'; end if;
  if char_length(v_loc) not between 1 and 200 then raise exception 'invalid_input:location'; end if;
  if char_length(v_guests) > 40 then raise exception 'invalid_input:guests'; end if;
  if char_length(v_details) > 3000 then raise exception 'invalid_input:details'; end if;

  begin
    v_date := (p ->> 'date')::date;
  exception when others then
    raise exception 'invalid_input:date';
  end;
  if v_date is null or v_date < (now() at time zone 'Europe/Warsaw')::date - 1 or v_date > (now() at time zone 'Europe/Warsaw')::date + 1100 then
    raise exception 'invalid_input:date';
  end if;

  if jsonb_typeof(p -> 'services') is distinct from 'array' then raise exception 'invalid_input:services'; end if;
  select array_agg(distinct s order by s) into v_services from jsonb_array_elements_text(p -> 'services') s;
  if v_services is null or cardinality(v_services) not between 1 and 3
     or exists (select 1 from unnest(v_services) s where s not in ('photographer', 'videographer', 'photobooth')) then
    raise exception 'invalid_input:services';
  end if;

  if jsonb_typeof(p -> 'counts') = 'object' then
    for v_key in select jsonb_object_keys(p -> 'counts') loop
      if v_key not in ('photographer', 'videographer', 'photobooth') or not (v_key = any (v_services)) then
        raise exception 'invalid_input:counts';
      end if;
      begin
        v_n := (p -> 'counts' ->> v_key)::int;
      exception when others then
        raise exception 'invalid_input:counts';
      end;
      if v_n not between 1 and 9 then raise exception 'invalid_input:counts'; end if;
      v_counts := v_counts || jsonb_build_object(v_key, v_n);
    end loop;
  end if;

  if (select count(*) from public.inquiries where lower(email) = v_email and created_at > now() - interval '1 hour') >= 5
     or (select count(*) from public.inquiries where created_at > now() - interval '1 hour') >= 80 then
    raise exception 'rate_limited';
  end if;

  insert into public.inquiries (source, name, email, phone, category, event_date, start_time, hours, location, guests, services, counts, details)
  values ('form', v_name, v_email, v_phone, v_cat, v_date, v_start, v_hours, v_loc, v_guests, v_services, v_counts, v_details)
  returning id into v_id;
  return v_id;
end $$;

-- Właściciel: tworzy sesję z potwierdzonego zapytania i oznacza zapytanie jako zarezerwowane.
create or replace function public.create_session_from_inquiry(p_inquiry uuid, p_session jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_owner() then raise exception 'not_owner' using errcode = '42501'; end if;
  if not exists (select 1 from public.inquiries where id = p_inquiry) then raise exception 'inquiry_not_found'; end if;
  insert into public.sessions (title, client, event_date, start_time, location, notes, slots, inquiry_id)
  values (
    btrim(coalesce(p_session ->> 'title', '')),
    coalesce(p_session ->> 'client', ''),
    (p_session ->> 'date')::date,
    coalesce(p_session ->> 'time', ''),
    coalesce(p_session ->> 'location', ''),
    coalesce(p_session ->> 'notes', ''),
    coalesce(p_session -> 'slots', '{}'::jsonb),
    p_inquiry
  ) returning id into v_id;
  update public.inquiries set status = 'booked', session_id = v_id where id = p_inquiry;
  return v_id;
end $$;

-- Właściciel: lista wszystkich kont (z adresami e-mail) do zatwierdzania.
create or replace function public.owner_people()
returns table (id uuid, email text, name text, avatar_url text, role text, approved boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'not_owner' using errcode = '42501'; end if;
  return query select p.id, p.email, p.name, p.avatar_url, p.role, p.approved, p.created_at
               from public.profiles p order by p.approved, p.created_at;
end $$;

-- Właściciel: zatwierdza albo odbiera dostęp (konta właściciela nie da się zablokować).
create or replace function public.set_approved(p_user uuid, p_approved boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'not_owner' using errcode = '42501'; end if;
  update public.profiles set approved = p_approved where id = p_user and role <> 'owner';
end $$;

-- Funkcje: domyślnie Supabase pozwala je wywołać każdemu. Zawężamy.
revoke execute on function public.ensure_profile() from public, anon;
revoke execute on function public.submit_inquiry(jsonb) from public;
revoke execute on function public.create_session_from_inquiry(uuid, jsonb) from public, anon;
revoke execute on function public.owner_people() from public, anon;
revoke execute on function public.set_approved(uuid, boolean) from public, anon;
revoke execute on function public.is_owner() from public, anon;
revoke execute on function public.is_approved() from public, anon;
grant execute on function public.ensure_profile() to authenticated;
grant execute on function public.submit_inquiry(jsonb) to anon, authenticated;
grant execute on function public.create_session_from_inquiry(uuid, jsonb) to authenticated;
grant execute on function public.owner_people() to authenticated;
grant execute on function public.set_approved(uuid, boolean) to authenticated;
grant execute on function public.is_owner() to authenticated;
grant execute on function public.is_approved() to authenticated;
