-- 0014_wg_peers_unique_ip.sql — one active peer per tunnel IP.
--
-- Belongs in KDBWeb/supabase/migrations/ next to the wg_peers migration; renumber
-- to follow your latest. Both server agents (wg_sync_agent.py, k3rn_capture_addon.py)
-- and the provision-peer allocator assume a wg_ip maps to exactly one member.
--
-- Without this guard, a re-provision that fails to revoke the old row (or an
-- allocator race) leaves two non-revoked rows for the same 10.8.0.x. The capture
-- addon then attributes that IP's game traffic to whichever row REST returns last
-- — so a member intermittently sees the WRONG game account — and the wg-sync agent
-- flips the allowed-ip between peers. This partial unique index makes that state
-- impossible to insert. The agents already fail loud+safe on any duplicate that
-- predates this migration.
--
-- Assumes wg_peers has (id, wg_ip, created_at, revoked_at). Adjust the dedupe
-- columns below if your schema differs. NOTE: wg_ip must be stored consistently
-- (all bare "10.8.0.5" or all "10.8.0.5/32") for the index to catch collisions;
-- normalize on write in provision-peer if it currently mixes the two.

-- Duplicates already in the table must be cleared or the index build fails. Keep
-- the most-recent active row per IP and revoke the rest.
with ranked as (
  select id,
         row_number() over (partition by wg_ip
                            order by created_at desc, id desc) as rn
  from wg_peers
  where revoked_at is null
)
update wg_peers p
set revoked_at = now()
from ranked r
where p.id = r.id
  and r.rn > 1;

create unique index if not exists wg_peers_active_ip_uniq
  on wg_peers (wg_ip)
  where revoked_at is null;
