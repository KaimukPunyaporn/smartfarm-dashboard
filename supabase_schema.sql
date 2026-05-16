-- ══════════════════════════════════════════════════════════════════
-- SmartFarm · Kaimuk — Complete Supabase Schema
-- Run this in Supabase Dashboard → SQL Editor
-- ══════════════════════════════════════════════════════════════════

-- ── Extensions ──────────────────────────────────────────────────
create extension if not exists "uuid-ossp";
create extension if not exists "pg_cron";   -- optional, for scheduled jobs

-- ══════════════════════════════════════════════════════════════════
-- 1. PROFILES (linked to auth.users)
-- ══════════════════════════════════════════════════════════════════
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  full_name   text,
  avatar_url  text,
  role        text not null default 'Viewer'
                check (role in ('Owner','Admin','Manager','Farm Operator','Viewer')),
  phone       text,
  line_id     text,
  timezone    text default 'Asia/Bangkok',
  language    text default 'th',
  last_seen   timestamptz default now(),
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

alter table public.profiles enable row level security;

create policy "Users can view own profile"
  on public.profiles for select using (auth.uid() = id);
create policy "Users can update own profile"
  on public.profiles for update using (auth.uid() = id);
create policy "Admins can view all profiles"
  on public.profiles for select using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('Owner','Admin'))
  );
create policy "Admins can update all profiles"
  on public.profiles for update using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('Owner','Admin'))
  );
create policy "Admins can insert profiles"
  on public.profiles for insert with check (true);

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email,'@',1)),
    coalesce(new.raw_user_meta_data->>'avatar_url', new.raw_user_meta_data->>'picture'),
    'Viewer'
  )
  on conflict (id) do update set
    email      = excluded.email,
    full_name  = coalesce(excluded.full_name, profiles.full_name),
    avatar_url = coalesce(excluded.avatar_url, profiles.avatar_url),
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ══════════════════════════════════════════════════════════════════
-- 2. FARM ZONES
-- ══════════════════════════════════════════════════════════════════
create table if not exists public.farm_zones (
  id          text primary key,          -- 'A', 'B', 'C', 'D'
  name        text not null,
  crop        text,
  area        text,
  plant_date  date,
  harvest_date date,
  health_score int default 80,
  status      text default 'active' check (status in ('active','inactive','harvested')),
  created_at  timestamptz default now()
);

alter table public.farm_zones enable row level security;
create policy "All authenticated users can read zones"
  on public.farm_zones for select using (auth.role() = 'authenticated');
create policy "Admins can modify zones"
  on public.farm_zones for all using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('Owner','Admin'))
  );

-- Seed zones
insert into public.farm_zones (id, name, crop, area, plant_date, harvest_date, health_score) values
  ('A', 'โซน A — แปลงผักสลัด',        'Lettuce',       '1.2 ไร่', '2026-04-12', '2026-05-17', 92),
  ('B', 'โซน B — เมล่อนโรงเรือน',     'Melon',         '0.8 ไร่', '2026-03-20', '2026-06-25', 78),
  ('C', 'โซน C — มะเขือเทศเชอรี่',   'Cherry Tomato', '1.0 ไร่', '2026-04-01', '2026-06-10', 65),
  ('D', 'โซน D — ผักไฮโดรโปนิกส์', 'Hydroponics',   '0.5 ไร่', '2026-04-22', '2026-05-30', 88)
on conflict (id) do nothing;

-- ══════════════════════════════════════════════════════════════════
-- 3. SENSORS
-- ══════════════════════════════════════════════════════════════════
create table if not exists public.sensors (
  id          text primary key,           -- 'TMP-01'
  name        text not null,
  kind        text not null,              -- 'temperature','humidity','soil','ph','ec','light','co2','water'
  unit        text not null,
  zone_id     text references public.farm_zones(id),
  icon        text default 'Sensor',
  range_min   numeric,
  range_max   numeric,
  protocol    text default 'LoRa',
  gateway     text,
  is_online   boolean default true,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

alter table public.sensors enable row level security;
create policy "Authenticated users can read sensors"
  on public.sensors for select using (auth.role() = 'authenticated');
create policy "Admins can manage sensors"
  on public.sensors for all using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('Owner','Admin','Manager'))
  );

-- Seed sensors
insert into public.sensors (id, name, kind, unit, zone_id, icon, range_min, range_max, is_online) values
  ('TMP-01', 'Temperature',     'temperature', '°C',    'A', 'Temp',   22, 38, true),
  ('HUM-01', 'Humidity',        'humidity',    '%',     'A', 'Drop',   50, 90, true),
  ('WTR-01', 'Water Level',     'water',       '%',     'B', 'Wave',   20,100, true),
  ('SOL-01', 'Soil Moisture',   'soil',        '%',     'C', 'Leaf',   20, 80, true),
  ('PH-01',  'pH Value',        'ph',          'pH',    'D', 'Beaker', 5,  8,  true),
  ('EC-01',  'EC Value',        'ec',          'mS/cm', 'D', 'Beaker', 0.5,3,  true),
  ('LUX-01', 'Light Intensity', 'light',       'klx',   'A', 'Sun',    0,  60, true),
  ('CO2-01', 'CO₂ Level',       'co2',         'ppm',   'B', 'Cloud',  400,1200,true)
on conflict (id) do nothing;

-- ══════════════════════════════════════════════════════════════════
-- 4. SENSOR READINGS (time-series)
-- ══════════════════════════════════════════════════════════════════
create table if not exists public.sensor_readings (
  id          bigserial primary key,
  sensor_id   text not null references public.sensors(id) on delete cascade,
  value       numeric not null,
  recorded_at timestamptz not null default now()
);

-- Index for fast time-series queries
create index if not exists idx_sensor_readings_sensor_time
  on public.sensor_readings (sensor_id, recorded_at desc);

alter table public.sensor_readings enable row level security;
create policy "Authenticated users can read sensor data"
  on public.sensor_readings for select using (auth.role() = 'authenticated');
create policy "Admins and operators can insert readings"
  on public.sensor_readings for insert with check (auth.role() = 'authenticated');

-- Helper: get latest reading per sensor
create or replace view public.sensor_latest as
select distinct on (sensor_id)
  r.sensor_id,
  r.value,
  r.recorded_at,
  s.name, s.kind, s.unit, s.zone_id, s.icon, s.range_min, s.range_max, s.is_online
from public.sensor_readings r
join public.sensors s on s.id = r.sensor_id
order by sensor_id, recorded_at desc;

-- Seed with realistic initial readings
insert into public.sensor_readings (sensor_id, value, recorded_at)
select sensor_id, value, now() - (n || ' minutes')::interval
from (
  select 'TMP-01' as sensor_id, 24 + random()*12 as value
  union all select 'HUM-01', 60 + random()*25
  union all select 'WTR-01', 50 + random()*40
  union all select 'SOL-01', 25 + random()*45
  union all select 'PH-01',  5.8 + random()*1.5
  union all select 'EC-01',  0.8 + random()*1.8
  union all select 'LUX-01', 5 + random()*50
  union all select 'CO2-01', 420 + random()*600
) base
cross join generate_series(0, 1440, 30) as n
on conflict do nothing;

-- ══════════════════════════════════════════════════════════════════
-- 5. DEVICES
-- ══════════════════════════════════════════════════════════════════
create table if not exists public.devices (
  id          text primary key,
  name        text not null,
  kind        text not null check (kind in ('pump','fan','light','mist','valve','feeder','camera','sensor')),
  icon        text default 'Device',
  zone_id     text references public.farm_zones(id),
  is_on       boolean default false,
  power_kw    numeric default 0,
  flow_info   text,
  protocol    text default 'MQTT',
  ip_address  text,
  port        text,
  uptime_sec  int default 0,
  last_toggled_at timestamptz,
  last_toggled_by uuid references public.profiles(id),
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

alter table public.devices enable row level security;
create policy "Authenticated users can read devices"
  on public.devices for select using (auth.role() = 'authenticated');
create policy "Operators and above can toggle devices"
  on public.devices for update using (
    exists (select 1 from public.profiles p where p.id = auth.uid()
            and p.role in ('Owner','Admin','Manager','Farm Operator'))
  );
create policy "Admins can manage devices"
  on public.devices for all using (
    exists (select 1 from public.profiles p where p.id = auth.uid()
            and p.role in ('Owner','Admin'))
  );

insert into public.devices (id, name, kind, icon, zone_id, is_on, power_kw, flow_info, protocol) values
  ('PMP-01', 'ปั๊มน้ำหลัก #1',        'pump',  'Pump', 'A', true,  1.2, '12.4 L/min',     'MQTT'),
  ('PMP-02', 'ปั๊มน้ำสำรอง #2',       'pump',  'Pump', 'B', false, 0,   '0 L/min',        'MQTT'),
  ('FAN-01', 'พัดลมระบายอากาศ A',      'fan',   'Fan',  'A', true,  0.4, 'Mid speed',      'MQTT'),
  ('FAN-02', 'พัดลมระบายอากาศ B',      'fan',   'Fan',  'B', true,  0.2, 'Low speed',      'MQTT'),
  ('LGT-01', 'ไฟ Grow Light #1',       'light', 'Bulb', 'D', false, 0,   'Spectrum: full', 'MQTT'),
  ('LGT-02', 'ไฟ Grow Light #2',       'light', 'Bulb', 'D', true,  0.3, 'Spectrum: red',  'MQTT')
on conflict (id) do nothing;

-- ══════════════════════════════════════════════════════════════════
-- 6. DEVICE LOGS (audit trail for every toggle)
-- ══════════════════════════════════════════════════════════════════
create table if not exists public.device_logs (
  id          bigserial primary key,
  device_id   text references public.devices(id) on delete cascade,
  action      text not null,       -- 'ON', 'OFF', 'EMERGENCY_STOP'
  triggered_by uuid references public.profiles(id),
  note        text,
  logged_at   timestamptz default now()
);

create index if not exists idx_device_logs_device on public.device_logs(device_id, logged_at desc);
alter table public.device_logs enable row level security;
create policy "Authenticated can read device logs"
  on public.device_logs for select using (auth.role() = 'authenticated');
create policy "Authenticated can insert device logs"
  on public.device_logs for insert with check (auth.role() = 'authenticated');

-- ══════════════════════════════════════════════════════════════════
-- 7. ALERTS / NOTIFICATIONS
-- ══════════════════════════════════════════════════════════════════
create table if not exists public.alerts (
  id          bigserial primary key,
  severity    text not null check (severity in ('critical','danger','warning','info')),
  title       text not null,
  message     text,
  sensor_id   text references public.sensors(id),
  device_id   text references public.devices(id),
  zone_id     text references public.farm_zones(id),
  farm_name   text default 'Kaimuk Farm',
  is_read     boolean default false,
  read_by     uuid references public.profiles(id),
  read_at     timestamptz,
  created_at  timestamptz default now()
);

create index if not exists idx_alerts_created on public.alerts(created_at desc);
create index if not exists idx_alerts_unread  on public.alerts(is_read) where not is_read;
alter table public.alerts enable row level security;
create policy "Authenticated can read alerts"
  on public.alerts for select using (auth.role() = 'authenticated');
create policy "Authenticated can update alerts (mark read)"
  on public.alerts for update using (auth.role() = 'authenticated');
create policy "System can insert alerts"
  on public.alerts for insert with check (auth.role() = 'authenticated');

-- Seed initial alerts
insert into public.alerts (severity, title, message, sensor_id, zone_id, created_at) values
  ('danger',  'Soil moisture ต่ำกว่าเกณฑ์ — โซน C', 'SOL-03 · 24% · ต่ำกว่า 30%',          'SOL-01', 'C', now() - interval '2 minutes'),
  ('warning', 'อุณหภูมิสูง — โซน B โรงเรือน',        'TMP-02 · 36.8°C',                      'TMP-01', 'B', now() - interval '12 minutes'),
  ('warning', 'Sensor offline — PH-02',               'ไม่มีสัญญาณ 8 นาที',                    'PH-01',  'D', now() - interval '18 minutes'),
  ('info',    'Auto-watering ทำงาน — โซน A',          'ทำงาน 6 นาที · ใช้น้ำ 74 L',          null,     'A', now() - interval '32 minutes'),
  ('info',    'AI ตรวจพบใบเหลืองที่ CAM-01',          'ความมั่นใจ 87% · แนะนำตรวจสอบ',      null,     'A', now() - interval '1 hour'),
  ('info',    'รายงานประจำวันพร้อมแล้ว',              'Daily Report 11 พ.ค. 2026 สร้างแล้ว', null,     null, now() - interval '6 hours')
on conflict do nothing;

-- ══════════════════════════════════════════════════════════════════
-- 8. AUTOMATION RULES
-- ══════════════════════════════════════════════════════════════════
create table if not exists public.automation_rules (
  id          bigserial primary key,
  name        text not null,
  is_active   boolean default true,
  condition   text not null,
  action      text not null,
  zone_id     text references public.farm_zones(id),
  runs_today  int default 0,
  last_run_at timestamptz,
  created_by  uuid references public.profiles(id),
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

alter table public.automation_rules enable row level security;
create policy "Authenticated can read rules"
  on public.automation_rules for select using (auth.role() = 'authenticated');
create policy "Admins can manage rules"
  on public.automation_rules for all using (
    exists (select 1 from public.profiles p where p.id = auth.uid()
            and p.role in ('Owner','Admin','Manager'))
  );

insert into public.automation_rules (name, is_active, condition, action, runs_today) values
  ('Auto Watering — โซน A', true,  'ถ้า Soil Moisture < 30%',              'เปิดปั๊มน้ำ PMP-01 เป็นเวลา 6 นาที',        14),
  ('Cool Down — โรงเรือน B', true, 'ถ้า Temperature > 38°C',               'เปิดพัดลม FAN-02 + พ่นหมอก MIST-01',        7),
  ('Sensor Offline Alert',  true,  'ถ้า Sensor ไม่ส่งข้อมูล > 5 นาที',    'แจ้งเตือนทาง LINE และ Telegram',             3),
  ('Grow Light Schedule',   true,  'ทุกวัน 18:00 – 22:00',                 'เปิดไฟ LGT-01 และ LGT-02 (สเปกตรัมแดง)',   26),
  ('Water Leakage Stop',    false, 'ถ้าตรวจพบน้ำรั่วที่ท่อหลัก',           'ปิดปั๊มทั้งหมด + แจ้งเตือนฉุกเฉิน',         0)
on conflict do nothing;

-- ══════════════════════════════════════════════════════════════════
-- 9. REPORTS
-- ══════════════════════════════════════════════════════════════════
create table if not exists public.reports (
  id          text primary key,
  name        text not null,
  kind        text not null check (kind in ('Daily','Weekly','Monthly','AI Summary','Custom')),
  file_size   text,
  created_by  uuid references public.profiles(id),
  created_by_name text,
  zones       text[],
  format      text default 'PDF',
  created_at  timestamptz default now()
);

alter table public.reports enable row level security;
create policy "Authenticated can read reports"
  on public.reports for select using (auth.role() = 'authenticated');
create policy "Admins and managers can create reports"
  on public.reports for insert with check (
    exists (select 1 from public.profiles p where p.id = auth.uid()
            and p.role in ('Owner','Admin','Manager'))
  );

insert into public.reports (id, name, kind, file_size, created_by_name, zones, created_at) values
  ('RPT-2026-0511-DAILY',  'รายงานประจำวัน — 11 พ.ค. 2026',  'Daily',      '284 KB', 'ระบบอัตโนมัติ', '{A,B,C,D}', now() - interval '5 hours'),
  ('RPT-2026-W19-WEEKLY',  'รายงานประจำสัปดาห์ที่ 19',        'Weekly',     '1.4 MB', 'อรุณี ศรีสุข',  '{A,B,C,D}', now() - interval '1 day'),
  ('RPT-2026-04-MONTHLY',  'รายงานเดือนเมษายน 2026',          'Monthly',    '3.8 MB', 'ไชยวัฒน์ บุญเรือง', '{A,B,C,D}', now() - interval '10 days'),
  ('RPT-AI-DISEASE-052',   'AI: สรุปการตรวจโรคพืช Q2',        'AI Summary', '920 KB', 'AI Engine',     '{A,B,C}', now() - interval '6 days'),
  ('RPT-WATER-USAGE-019',  'การใช้น้ำ — โซน A,B,C',           'Custom',     '612 KB', 'อรุณี ศรีสุข',  '{A,B,C}', now() - interval '8 days')
on conflict (id) do nothing;

-- ══════════════════════════════════════════════════════════════════
-- 10. FARM SETTINGS (singleton per farm)
-- ══════════════════════════════════════════════════════════════════
create table if not exists public.farm_settings (
  id              int primary key default 1 check (id = 1), -- singleton
  farm_name       text default 'Kaimuk Smart Farm — แม่ริม',
  farm_reg        text default 'KMK-2024-CMI-0142',
  farm_area       text default '3.5 ไร่',
  farm_address    text default 'ต.แม่ริม อ.แม่ริม จ.เชียงใหม่',
  latitude        numeric default 18.7234,
  longitude       numeric default 98.9482,
  notify_line     boolean default true,
  notify_email    boolean default true,
  notify_push     boolean default false,
  notify_sms      boolean default false,
  alert_critical  boolean default true,
  alert_warning   boolean default true,
  alert_info      boolean default false,
  updated_at      timestamptz default now()
);

alter table public.farm_settings enable row level security;
create policy "Authenticated can read farm settings"
  on public.farm_settings for select using (auth.role() = 'authenticated');
create policy "Admins can update farm settings"
  on public.farm_settings for all using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('Owner','Admin'))
  );

insert into public.farm_settings (id) values (1) on conflict (id) do nothing;

-- ══════════════════════════════════════════════════════════════════
-- 11. REALTIME SUBSCRIPTIONS (enable for key tables)
-- ══════════════════════════════════════════════════════════════════
-- Run these in Supabase Dashboard → Database → Replication
-- or via the Replication tab:
--   Enable realtime for: sensor_readings, alerts, devices, automation_rules

-- Enable publication for realtime
alter publication supabase_realtime add table public.sensor_readings;
alter publication supabase_realtime add table public.alerts;
alter publication supabase_realtime add table public.devices;
alter publication supabase_realtime add table public.automation_rules;

-- ══════════════════════════════════════════════════════════════════
-- DONE. Tables created:
--   profiles, farm_zones, sensors, sensor_readings, sensor_latest (view)
--   devices, device_logs, alerts, automation_rules, reports, farm_settings
-- ══════════════════════════════════════════════════════════════════
