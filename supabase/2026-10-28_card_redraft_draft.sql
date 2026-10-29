-- Card Redraft live draft: rooms, picks, server-side pick order, autopick, rosters.
alter table public.draft_rooms
  add column if not exists block_no int not null default 1,
  add column if not exists block_cards jsonb,
  add column if not exists draft_type text not null default 'snake',
  add column if not exists rounds int,
  add column if not exists pool jsonb;
create unique index if not exists draft_rooms_one_per_block on public.draft_rooms(league_id, block_no);
create unique index if not exists draft_picks_unique_pick on public.draft_picks(draft_room_id, pick_number);
create unique index if not exists draft_picks_unique_fighter on public.draft_picks(draft_room_id, fighter_id) where fighter_id is not null;

alter table public.draft_rooms enable row level security;
alter table public.draft_picks enable row level security;
drop policy if exists "league members read draft rooms" on public.draft_rooms;
create policy "league members read draft rooms" on public.draft_rooms for select to authenticated
  using (exists (select 1 from public.teams t where t.league_id = draft_rooms.league_id and t.owner_user_id = auth.uid()));
drop policy if exists "league members read draft picks" on public.draft_picks;
create policy "league members read draft picks" on public.draft_picks for select to authenticated
  using (exists (select 1 from public.draft_rooms r join public.teams t on t.league_id = r.league_id
                 where r.id = draft_picks.draft_room_id and t.owner_user_id = auth.uid()));

-- Which seat (1..n) is on the clock for a pick number.
create or replace function public.cr_seat(p_type text, p_n int, p_pick int) returns int
language sql immutable as $$
  with x as (select ((p_pick-1)/p_n)+1 as r, ((p_pick-1)%p_n)+1 as pos)
  select case
    when p_type='linear' then pos
    when p_type='3rr' then case when r=1 then pos when r=2 then p_n-pos+1 when (r-3)%2=0 then p_n-pos+1 else pos end
    else case when r%2=1 then pos else p_n-pos+1 end end
  from x $$;

create or replace function public.cr_advance(p_room uuid) returns void
language plpgsql security definer set search_path=public as $$
declare r public.draft_rooms; total int; n int; seat int; tid uuid; owner uuid; fid uuid; wc text;
begin
  loop
    select * into r from public.draft_rooms where id=p_room for update;
    exit when r.status <> 'live';
    n := jsonb_array_length(r.team_order);
    total := n * r.rounds;
    if r.current_pick_number > total then
      -- finished
      update public.draft_rooms set status='complete', completed_at=now(), current_pick_deadline=null where id=p_room;
      delete from public.rosters where team_id in (select (jsonb_array_elements_text(r.team_order))::uuid);
      insert into public.rosters(team_id, division, slot_type, fighter_id, role, role_slot_number)
        select p.team_id, coalesce(p.division,'NA'), 'fighter', p.fighter_id, 'fighter', p.round_number from public.draft_picks p where p.draft_room_id=p_room;
      update public.leagues set status='active' where id=r.league_id;
      exit;
    end if;
    seat := public.cr_seat(r.draft_type, n, r.current_pick_number);
    tid := (r.team_order->>(seat-1))::uuid;
    select owner_user_id into owner from public.teams where id=tid;
    -- act only if the clock ran out, or the team on the clock is a CPU team and its short wait is over
    exit when r.current_pick_deadline is not null and now() < r.current_pick_deadline;
    select f.id, f.announced_weight_class into fid, wc
      from public.fighters f
      where f.id in (select (jsonb_array_elements_text(r.pool))::uuid)
        and not exists (select 1 from public.draft_picks p where p.draft_room_id=p_room and p.fighter_id=f.id)
      order by coalesce(f.current_rating,1500) desc, f.full_name limit 1;
    insert into public.draft_picks(draft_room_id,pick_number,round_number,team_id,division,fighter_id,slot_type,role,role_slot_number,is_autopick,picked_at)
      values (p_room, r.current_pick_number, ((r.current_pick_number-1)/n)+1, tid, wc, fid, 'fighter','fighter', ((r.current_pick_number-1)/n)+1, true, now());
    update public.draft_rooms set current_pick_number=current_pick_number+1,
      current_pick_deadline = now() + make_interval(secs => r.pick_seconds) where id=p_room;
    -- if next team is a CPU team, shorten its clock
    select * into r from public.draft_rooms where id=p_room;
    if r.current_pick_number <= total then
      select owner_user_id into owner from public.teams where id=(r.team_order->>(public.cr_seat(r.draft_type,n,r.current_pick_number)-1))::uuid;
      if owner is null then update public.draft_rooms set current_pick_deadline=now()+interval '2 seconds' where id=p_room; end if;
    end if;
  end loop;
end $$;

create or replace function public.cr_start_draft(p_league uuid) returns uuid
language plpgsql security definer set search_path=public as $$
declare L public.leagues; cards jsonb; pool jsonb; ids uuid[]; cnt int; i int; room uuid; first_date date; ord jsonb; first_owner uuid;
begin
  select * into L from public.leagues where id=p_league for update;
  if L.id is null then raise exception 'League not found'; end if;
  if L.commissioner_user_id <> auth.uid() then raise exception 'Only the commissioner can start the draft'; end if;
  if L.status <> 'setup' then raise exception 'The draft already started'; end if;
  if L.draft_type = 'auction' then raise exception 'Auction drafts are coming soon'; end if;
  -- the first upcoming card is skipped; the block is the next 4
  select jsonb_agg(jsonb_build_object('event_name',event_name,'date',bout_date) order by bout_date) into cards from (
    select event_name, bout_date from public.bouts where bout_date >= current_date and status not in ('completed','cancelled')
    group by event_name, bout_date order by bout_date offset 1 limit 4) c;
  if cards is null or jsonb_array_length(cards) < 4 then raise exception 'Waiting for the 4th card to be announced'; end if;
  select array_agg(distinct f) into ids from (
    select b.fighter_a f from public.bouts b join jsonb_array_elements(cards) c on c->>'event_name'=b.event_name and (c->>'date')::date=b.bout_date where b.status not in ('completed','cancelled')
    union select b.fighter_b from public.bouts b join jsonb_array_elements(cards) c on c->>'event_name'=b.event_name and (c->>'date')::date=b.bout_date where b.status not in ('completed','cancelled')) s where f is not null;
  if coalesce(array_length(ids,1),0) < L.team_count*L.fighters_per_team then raise exception 'Not enough fighters on these cards yet'; end if;
  -- fill empty seats with CPU teams
  select count(*) into cnt from public.teams where league_id=p_league;
  for i in cnt+1..L.team_count loop
    insert into public.teams(league_id,name) values (p_league,'CPU Team '||i);
  end loop;
  select jsonb_agg(id order by random()) into ord from public.teams where league_id=p_league;
  insert into public.draft_rooms(league_id,format,status,pick_seconds,team_order,current_pick_number,started_at,current_pick_deadline,block_no,block_cards,draft_type,rounds,pool)
    values (p_league,'card_redraft','live',L.pick_seconds,ord,1,now(),now()+make_interval(secs=>L.pick_seconds+10),1,cards,L.draft_type,L.fighters_per_team,to_jsonb(ids))
    returning id into room;
  select owner_user_id into first_owner from public.teams where id=(ord->>0)::uuid;
  if first_owner is null then update public.draft_rooms set current_pick_deadline=now()+interval '2 seconds' where id=room; end if;
  update public.leagues set status='drafting' where id=p_league;
  return room;
end $$;

create or replace function public.cr_make_pick(p_room uuid, p_fighter uuid) returns void
language plpgsql security definer set search_path=public as $$
declare r public.draft_rooms; n int; tid uuid; owner uuid; wc text;
begin
  perform public.cr_advance(p_room);
  select * into r from public.draft_rooms where id=p_room for update;
  if r.status <> 'live' then raise exception 'The draft is not live'; end if;
  n := jsonb_array_length(r.team_order);
  tid := (r.team_order->>(public.cr_seat(r.draft_type,n,r.current_pick_number)-1))::uuid;
  select owner_user_id into owner from public.teams where id=tid;
  if owner is distinct from auth.uid() then raise exception 'It is not your pick'; end if;
  if not (r.pool @> to_jsonb(p_fighter::text)) then raise exception 'That fighter is not on this block'; end if;
  if exists (select 1 from public.draft_picks where draft_room_id=p_room and fighter_id=p_fighter) then raise exception 'That fighter was already picked'; end if;
  select announced_weight_class into wc from public.fighters where id=p_fighter;
  insert into public.draft_picks(draft_room_id,pick_number,round_number,team_id,division,fighter_id,slot_type,role,role_slot_number,is_autopick,picked_at)
    values (p_room,r.current_pick_number,((r.current_pick_number-1)/n)+1,tid,wc,p_fighter,'fighter','fighter',((r.current_pick_number-1)/n)+1,false,now());
  update public.draft_rooms set current_pick_number=current_pick_number+1, current_pick_deadline=now()+make_interval(secs=>r.pick_seconds) where id=p_room;
  update public.draft_rooms set current_pick_deadline=now()+interval '2 seconds'
    where id=p_room and current_pick_number <= n*rounds
      and (select owner_user_id from public.teams where id=(team_order->>(public.cr_seat(draft_type,n,current_pick_number)-1))::uuid) is null;
  perform public.cr_advance(p_room);
end $$;

-- Anyone in the league can nudge the clock (autopicks expired turns and CPU turns).
create or replace function public.cr_tick(p_room uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not exists (select 1 from public.draft_rooms r join public.teams t on t.league_id=r.league_id where r.id=p_room and t.owner_user_id=auth.uid()) then
    raise exception 'Not in this league'; end if;
  perform public.cr_advance(p_room);
end $$;

revoke all on function public.cr_advance(uuid) from public, anon, authenticated;
revoke all on function public.cr_start_draft(uuid), public.cr_make_pick(uuid,uuid), public.cr_tick(uuid) from public, anon;
grant execute on function public.cr_start_draft(uuid), public.cr_make_pick(uuid,uuid), public.cr_tick(uuid) to authenticated;

-- ===== Follow-up migration "card_redraft_own_tables" (applied after the above) =====
-- The dynasty draft_picks/rosters tables have role/slot checks that don't fit Card Redraft,
-- so Card Redraft uses its own tables cr_picks / cr_rosters, and cr_advance / cr_make_pick
-- were redefined to write to them. See the live database for the final function bodies.
-- cr_picks(draft_room_id, pick_number, round_number, team_id, fighter_id, division, is_autopick, picked_at)
-- cr_rosters(team_id, block_no, fighter_id, division, round_number)

-- ===== Migration "card_redraft_season" =====
-- cr_matchups (head-to-head pairings per block, scores, winner, final flag) with member read policy;
-- cr_make_schedule (circle-method round robin, blocks 1-7 for 12/10/6 teams, 1-8 for 8/4 teams),
-- trigger cr_draft_complete (builds the schedule when the block 1 draft completes),
-- cr_refresh_scores(league) (sums performances.fantasy_points for rostered fighters on the block's cards, finalizes when all cards are done).

-- ===== Migrations "card_redraft_waivers_trades" (+ order fix, trade fix) =====
-- cr_claims (waiver claims: add/drop, FAAB bid, priority, status), cr_trades (1-for-1 offers, 2 day expiry),
-- cr_locked(league, block, fighter), cr_my_team(league),
-- cr_submit_claim / cr_cancel_claim, cr_process_waivers (runs claims placed before the latest Tuesday 12 AM Eastern;
-- standard = worst record first, FAAB = highest bid first, ties by waiver order), cr_propose_trade, cr_respond_trade (accept/decline/cancel).

-- ===== Migration "card_redraft_next_block_draft" =====
-- cr_start_next_draft(league): commissioner starts the next block's redraft once the current block's cards are all finished
-- and the next 4 cards are announced (fresh random order, everyone redrafts; earlier blocks' rosters are kept).

-- ===== Migration "card_redraft_test_draft" =====
-- leagues.is_test + cr_start_test_draft(league): commissioner can start a draft now using the next 4 upcoming cards
-- (including the imminent one), with CPU teams filling empty seats. The league is marked is_test.

-- ===== Migration "paused_draft_pick_trades" (see supabase/2026-10-29_paused_draft_pick_trades.sql) =====
-- Drafts start with at least 2 announced cards, pause when the pool runs out, resume when bouts are added (cr_refresh_pool). NEW fighters tracked in draft_rooms.pool_new.
-- Draft pick trades: cr_pick_owner, cr_pick_trades, cr_propose_pick_trade, cr_respond_pick_trade (pick-for-pick or pick-for-fighter). Waivers now process Tuesday 12 AM ET.
