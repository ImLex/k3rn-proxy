-- 0007_captures.sql — private per-member capture inbox.
--
-- The Oracle proxy no longer writes to the shared `players` tables. Instead each
-- opened target (/v1/user_victim) is upserted here, owned by the scanning member.
-- Members see ONLY their own captures (RLS). Promoting a capture into the shared
-- crew DB is an explicit member action in the app (reuses players insert/update),
-- never automatic.
--
-- Belongs in KDBWeb/supabase/migrations/ next to 0006_software.sql. Does not touch
-- players/audit_logs, so the bot + web + existing app keep working unchanged.

create table if not exists captures (
  id               uuid primary key default gen_random_uuid(),
  owner_user_id    uuid not null references auth.users(id) on delete cascade,
  owner_discord_id text not null,
  player_id        text,                          -- HackEx numeric id (as text)
  username         text not null,
  current_ip       text,
  level            int,
  firewall         int,
  reputation       int,
  crew             text,
  software         jsonb not null default '[]'::jsonb,   -- [{name,category,level}]
  captured_at      timestamptz not null default now(),
  uploaded_at      timestamptz,                   -- set when promoted to shared players
  unique (owner_user_id, player_id)               -- one row per player per member
);

create index if not exists idx_captures_owner on captures(owner_user_id);

alter table captures enable row level security;

-- Members read/manage ONLY their own captures. service_role (the proxy) bypasses
-- RLS entirely, so it can insert on any member's behalf.
drop policy if exists cap_own on captures;
create policy cap_own on captures
  for all
  using (owner_user_id = auth.uid())
  with check (owner_user_id = auth.uid());

-- NOTE: uploading a capture into the shared DB reuses the existing players
-- insert/update path (PlayerService.create/update). That already works for
-- members via the app's edit UI, so no players policy change is expected here.
-- If your base-schema players RLS restricts writes to admins only, add member
-- insert/update policies on `players` in this migration to match "members upload
-- without approval".
