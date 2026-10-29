-- Paused drafts (card lineup not fully announced) + tradeable draft picks.
-- Draft pauses when no undrafted fighter is left for the pick on the clock and resumes
-- by itself when new bouts are announced. Newly announced fighters are tagged in pool_new.

alter table public.draft_rooms add column if not exists pool_new jsonb not null default '[]'::jsonb;

create table if not exists public.cr_pick_owner (
  draft_room_id uuid not null references public.draft_rooms(id) on delete cascade,
  pick_number int not null,
  team_id uuid not null references public.teams(id) on delete cascade,
  primary key (draft_room_id, pick_number)
);
create table if not exists public.cr_pick_trades (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  draft_room_id uuid not null references public.draft_rooms(id) on delete cascade,
  from_team uuid not null references public.teams(id) on delete cascade,
  to_team uuid not null references public.teams(id) on delete cascade,
  send_fighter uuid references public.fighters(id),
  send_pick int,
  get_fighter uuid references public.fighters(id),
  get_pick int,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '2 days',
  check ((send_fighter is null) <> (send_pick is null)),
  check ((get_fighter is null) <> (get_pick is null)),
  check (send_pick is not null or get_pick is not null)
);
alter table public.cr_pick_owner enable row level security;
alter table public.cr_pick_trades enable row level security;
drop policy if exists "members read pick owner" on public.cr_pick_owner;
create policy "members read pick owner" on public.cr_pick_owner for select to authenticated
  using (exists (select 1 from public.draft_rooms r join public.teams t on t.league_id=r.league_id where r.id=cr_pick_owner.draft_room_id and t.owner_user_id=auth.uid()));
drop policy if exists "members read pick trades" on public.cr_pick_trades;
create policy "members read pick trades" on public.cr_pick_trades for select to authenticated
  using (exists (select 1 from public.teams t where t.league_id=cr_pick_trades.league_id and t.owner_user_id=auth.uid()));

-- Who owns a pick slot (a trade override, otherwise the draft order).
create or replace function public.cr_pick_team(p_room uuid, p_pick int) returns uuid
language sql stable security definer set search_path=public as $$
  select coalesce(
    (select o.team_id from public.cr_pick_owner o where o.draft_room_id=p_room and o.pick_number=p_pick),
    (select (r.team_order->>(public.cr_seat(r.draft_type, jsonb_array_length(r.team_order), p_pick)-1))::uuid from public.draft_rooms r where r.id=p_room)) $$;

-- Pull in bouts announced after the draft started (more bouts on a card, or the next card).
create or replace function public.cr_refresh_pool(p_room uuid) returns void
language plpgsql security definer set search_path=public as $$
declare r public.draft_rooms; cards jsonb; have int; lastd date; extra jsonb; ids uuid[]; old uuid[]; fresh uuid[];
begin
  select * into r from public.draft_rooms where id=p_room for update;
  if r.id is null or r.status not in ('live','paused') then return; end if;
  cards := r.block_cards; have := jsonb_array_length(cards);
  if have < 4 then
    select max((c->>'date')::date) into lastd from jsonb_array_elements(cards) c;
    select jsonb_agg(jsonb_build_object('event_name',event_name,'date',bout_date) order by bout_date) into extra from (
      select event_name, bout_date from public.bouts where bout_date > lastd and status not in ('completed','cancelled')
      group by event_name, bout_date order by bout_date limit 4-have) e;
    if extra is not null then cards := cards || extra; end if;
  end if;
  select array_agg(distinct f) into ids from (
    select b.fighter_a f from public.bouts b join jsonb_array_elements(cards) c on c->>'event_name'=b.event_name and (c->>'date')::date=b.bout_date where b.status not in ('completed','cancelled')
    union select b.fighter_b from public.bouts b join jsonb_array_elements(cards) c on c->>'event_name'=b.event_name and (c->>'date')::date=b.bout_date where b.status not in ('completed','cancelled')) s where f is not null;
  select coalesce(array_agg(x::uuid),'{}') into old from jsonb_array_elements_text(r.pool) x;
  select coalesce(array_agg(i),'{}') into fresh from unnest(coalesce(ids,'{}')) i where not (i = any(old));
  if cardinality(fresh) > 0 or cards is distinct from r.block_cards then
    update public.draft_rooms set block_cards=cards,
      pool = r.pool || to_jsonb(fresh),
      pool_new = r.pool_new || to_jsonb(fresh) where id=p_room;
  end if;
end $$;

create or replace function public.cr_advance(p_room uuid) returns void
language plpgsql security definer set search_path=public as $$
declare r public.draft_rooms; total int; n int; tid uuid; owner uuid; fid uuid; wc text; avail int;
begin
  perform public.cr_refresh_pool(p_room);
  loop
    select * into r from public.draft_rooms where id=p_room for update;
    exit when r.status not in ('live','paused');
    n := jsonb_array_length(r.team_order);
    total := n * r.rounds;
    if r.current_pick_number > total then
      update public.draft_rooms set status='complete', completed_at=now(), current_pick_deadline=null where id=p_room;
      delete from public.cr_rosters where block_no=r.block_no and team_id in (select (jsonb_array_elements_text(r.team_order))::uuid);
      insert into public.cr_rosters(team_id, block_no, fighter_id, division, round_number)
        select p.team_id, r.block_no, p.fighter_id, p.division, p.round_number from public.cr_picks p where p.draft_room_id=p_room;
      update public.leagues set status='active' where id=r.league_id;
      exit;
    end if;
    tid := public.cr_pick_team(p_room, r.current_pick_number);
    select count(*) into avail from public.fighters f
      where f.id in (select (jsonb_array_elements_text(r.pool))::uuid)
        and not exists (select 1 from public.cr_picks p where p.draft_room_id=p_room and p.fighter_id=f.id);
    if avail = 0 then
      if r.status = 'live' then update public.draft_rooms set status='paused', current_pick_deadline=null where id=p_room; end if;
      exit;
    end if;
    if r.status = 'paused' then
      select owner_user_id into owner from public.teams where id=tid;
      update public.draft_rooms set status='live',
        current_pick_deadline = now() + case when owner is null then interval '2 seconds' else make_interval(secs => r.pick_seconds) end where id=p_room;
      continue;
    end if;
    exit when r.current_pick_deadline is not null and now() < r.current_pick_deadline;
    select f.id, f.announced_weight_class into fid, wc
      from public.fighters f
      where f.id in (select (jsonb_array_elements_text(r.pool))::uuid)
        and not exists (select 1 from public.cr_picks p where p.draft_room_id=p_room and p.fighter_id=f.id)
      order by coalesce(f.current_rating,1500) desc, f.full_name limit 1;
    insert into public.cr_picks(draft_room_id,pick_number,round_number,team_id,division,fighter_id,is_autopick)
      values (p_room, r.current_pick_number, ((r.current_pick_number-1)/n)+1, tid, wc, fid, true);
    update public.draft_rooms set current_pick_number=current_pick_number+1,
      current_pick_deadline = now() + make_interval(secs => r.pick_seconds) where id=p_room;
    select * into r from public.draft_rooms where id=p_room;
    if r.current_pick_number <= total then
      select owner_user_id into owner from public.teams where id=public.cr_pick_team(p_room, r.current_pick_number);
      if owner is null then update public.draft_rooms set current_pick_deadline=now()+interval '2 seconds' where id=p_room; end if;
    end if;
  end loop;
end $$;

create or replace function public.cr_make_pick(p_room uuid, p_fighter uuid) returns void
language plpgsql security definer set search_path=public as $$
declare r public.draft_rooms; n int; tid uuid; owner uuid; wc text;
begin
  perform public.cr_advance(p_room);
  select * into r from public.draft_rooms where id=p_room for update;
  if r.status = 'paused' then raise exception 'The draft is paused until more bouts are announced'; end if;
  if r.status <> 'live' then raise exception 'The draft is not live'; end if;
  n := jsonb_array_length(r.team_order);
  tid := public.cr_pick_team(p_room, r.current_pick_number);
  select owner_user_id into owner from public.teams where id=tid;
  if owner is distinct from auth.uid() then raise exception 'It is not your pick'; end if;
  if not (r.pool @> to_jsonb(p_fighter::text)) then raise exception 'That fighter is not on this block'; end if;
  if exists (select 1 from public.cr_picks where draft_room_id=p_room and fighter_id=p_fighter) then raise exception 'That fighter was already picked'; end if;
  select announced_weight_class into wc from public.fighters where id=p_fighter;
  insert into public.cr_picks(draft_room_id,pick_number,round_number,team_id,division,fighter_id,is_autopick)
    values (p_room,r.current_pick_number,((r.current_pick_number-1)/n)+1,tid,wc,p_fighter,false);
  update public.draft_rooms set current_pick_number=current_pick_number+1, current_pick_deadline=now()+make_interval(secs=>r.pick_seconds) where id=p_room;
  if r.current_pick_number + 1 <= n * r.rounds then
    select owner_user_id into owner from public.teams where id=public.cr_pick_team(p_room, r.current_pick_number+1);
    if owner is null then update public.draft_rooms set current_pick_deadline=now()+interval '2 seconds' where id=p_room; end if;
  end if;
  perform public.cr_advance(p_room);
end $$;

-- Start with at least 2 announced cards; the draft pauses when the announced fighters run out.
create or replace function public.cr_start_draft(p_league uuid) returns uuid
language plpgsql security definer set search_path=public as $$
declare L public.leagues; cards jsonb; ids uuid[]; cnt int; i int; room uuid; ord jsonb; first_owner uuid;
begin
  select * into L from public.leagues where id=p_league for update;
  if L.id is null then raise exception 'League not found'; end if;
  if L.commissioner_user_id <> auth.uid() then raise exception 'Only the commissioner can start the draft'; end if;
  if L.status <> 'setup' then raise exception 'The draft already started'; end if;
  if L.draft_type = 'auction' then raise exception 'Auction drafts are coming soon'; end if;
  select jsonb_agg(jsonb_build_object('event_name',event_name,'date',bout_date) order by bout_date) into cards from (
    select event_name, bout_date from public.bouts where bout_date >= current_date and status not in ('completed','cancelled')
    group by event_name, bout_date order by bout_date offset 1 limit 4) c;
  if cards is null or jsonb_array_length(cards) < 2 then raise exception 'Waiting for more cards to be announced'; end if;
  select array_agg(distinct f) into ids from (
    select b.fighter_a f from public.bouts b join jsonb_array_elements(cards) c on c->>'event_name'=b.event_name and (c->>'date')::date=b.bout_date where b.status not in ('completed','cancelled')
    union select b.fighter_b from public.bouts b join jsonb_array_elements(cards) c on c->>'event_name'=b.event_name and (c->>'date')::date=b.bout_date where b.status not in ('completed','cancelled')) s where f is not null;
  if jsonb_array_length(cards) >= 4 and coalesce(array_length(ids,1),0) < L.team_count*L.fighters_per_team then raise exception 'Not enough fighters on these cards yet'; end if;
  if coalesce(array_length(ids,1),0) < L.team_count then raise exception 'Not enough fighters announced yet'; end if;
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

create or replace function public.cr_start_next_draft(p_league uuid) returns uuid
language plpgsql security definer set search_path=public as $$
declare L public.leagues; prev public.draft_rooms; last_date date; cards jsonb; ids uuid[]; room uuid; ord jsonb; first_owner uuid; unfinished int; regs int;
begin
  select * into L from public.leagues where id=p_league for update;
  if L.id is null then raise exception 'League not found'; end if;
  if L.commissioner_user_id <> auth.uid() then raise exception 'Only the commissioner can start the draft'; end if;
  select * into prev from public.draft_rooms where league_id=p_league order by block_no desc limit 1;
  if prev.id is null or prev.status <> 'complete' then raise exception 'Finish the current draft first'; end if;
  regs := case when L.team_count in (12,10,6) then 7 else 8 end;
  if prev.block_no >= regs then raise exception 'The regular season is over. Playoff drafts come with the playoff bracket'; end if;
  select count(*) into unfinished from public.bouts b join jsonb_array_elements(prev.block_cards) c on c->>'event_name'=b.event_name and (c->>'date')::date=b.bout_date
    where b.status not in ('completed','cancelled');
  if unfinished > 0 then raise exception 'Block % is not finished yet', prev.block_no; end if;
  select max((c->>'date')::date) into last_date from jsonb_array_elements(prev.block_cards) c;
  select jsonb_agg(jsonb_build_object('event_name',event_name,'date',bout_date) order by bout_date) into cards from (
    select event_name, bout_date from public.bouts where bout_date > last_date and status not in ('completed','cancelled')
    group by event_name, bout_date order by bout_date limit 4) c;
  if cards is null or jsonb_array_length(cards) < 2 then raise exception 'Waiting for more cards to be announced'; end if;
  select array_agg(distinct f) into ids from (
    select b.fighter_a f from public.bouts b join jsonb_array_elements(cards) c on c->>'event_name'=b.event_name and (c->>'date')::date=b.bout_date where b.status not in ('completed','cancelled')
    union select b.fighter_b from public.bouts b join jsonb_array_elements(cards) c on c->>'event_name'=b.event_name and (c->>'date')::date=b.bout_date where b.status not in ('completed','cancelled')) s where f is not null;
  if jsonb_array_length(cards) >= 4 and coalesce(array_length(ids,1),0) < L.team_count*L.fighters_per_team then raise exception 'Not enough fighters on these cards yet'; end if;
  if coalesce(array_length(ids,1),0) < L.team_count then raise exception 'Not enough fighters announced yet'; end if;
  select jsonb_agg(id order by random()) into ord from public.teams where league_id=p_league;
  insert into public.draft_rooms(league_id,format,status,pick_seconds,team_order,current_pick_number,started_at,current_pick_deadline,block_no,block_cards,draft_type,rounds,pool)
    values (p_league,'card_redraft','live',L.pick_seconds,ord,1,now(),now()+make_interval(secs=>L.pick_seconds+10),prev.block_no+1,cards,L.draft_type,L.fighters_per_team,to_jsonb(ids))
    returning id into room;
  select owner_user_id into first_owner from public.teams where id=(ord->>0)::uuid;
  if first_owner is null then update public.draft_rooms set current_pick_deadline=now()+interval '2 seconds' where id=room; end if;
  return room;
end $$;

-- Can this pick still be traded? It must be in the future (or on hold while the draft is paused).
create or replace function public.cr_pick_open(r public.draft_rooms, p_pick int) returns boolean
language sql immutable as $$
  select r.status in ('live','paused') and p_pick between 1 and jsonb_array_length(r.team_order)*r.rounds
    and (p_pick > r.current_pick_number or (p_pick = r.current_pick_number and r.status = 'paused')) $$;

create or replace function public.cr_propose_pick_trade(p_room uuid, p_to uuid, p_send_fighter uuid, p_send_pick int, p_get_fighter uuid, p_get_pick int) returns uuid
language plpgsql security definer set search_path=public as $$
declare r public.draft_rooms; me uuid; new_id uuid;
begin
  select * into r from public.draft_rooms where id=p_room;
  if r.id is null or r.status not in ('live','paused') then raise exception 'There is no draft in progress'; end if;
  me := public.cr_my_team(r.league_id);
  if me is null then raise exception 'Not in this league'; end if;
  if p_to = me or not exists (select 1 from public.teams t where t.id=p_to and t.league_id=r.league_id) then raise exception 'Pick another team'; end if;
  if exists (select 1 from public.teams where id=p_to and owner_user_id is null) then raise exception 'CPU teams do not trade'; end if;
  if (p_send_fighter is null) = (p_send_pick is null) or (p_get_fighter is null) = (p_get_pick is null) then raise exception 'Pick one fighter or one pick for each side'; end if;
  if p_send_pick is null and p_get_pick is null then raise exception 'At least one side must be a draft pick'; end if;
  if p_send_pick is not null and not (public.cr_pick_open(r,p_send_pick) and public.cr_pick_team(p_room,p_send_pick)=me) then raise exception 'You cannot trade that pick'; end if;
  if p_get_pick is not null and not (public.cr_pick_open(r,p_get_pick) and public.cr_pick_team(p_room,p_get_pick)=p_to) then raise exception 'They cannot trade that pick'; end if;
  if p_send_fighter is not null and not exists (select 1 from public.cr_picks where draft_room_id=p_room and team_id=me and fighter_id=p_send_fighter) then raise exception 'You do not own that fighter'; end if;
  if p_get_fighter is not null and not exists (select 1 from public.cr_picks where draft_room_id=p_room and team_id=p_to and fighter_id=p_get_fighter) then raise exception 'They do not own that fighter'; end if;
  if (p_send_fighter is not null and public.cr_locked(r.league_id,r.block_no,p_send_fighter)) or (p_get_fighter is not null and public.cr_locked(r.league_id,r.block_no,p_get_fighter)) then raise exception 'A fighter in this trade is locked'; end if;
  insert into public.cr_pick_trades(league_id,draft_room_id,from_team,to_team,send_fighter,send_pick,get_fighter,get_pick)
    values (r.league_id,p_room,me,p_to,p_send_fighter,p_send_pick,p_get_fighter,p_get_pick) returning cr_pick_trades.id into new_id;
  return new_id;
end $$;

create or replace function public.cr_respond_pick_trade(p_trade uuid, p_action text) returns void
language plpgsql security definer set search_path=public as $$
declare t public.cr_pick_trades; r public.draft_rooms;
begin
  select * into t from public.cr_pick_trades where id=p_trade for update;
  if t.id is null or t.status <> 'pending' then raise exception 'That trade is no longer open'; end if;
  if p_action='cancel' then
    if not exists (select 1 from public.teams where id=t.from_team and owner_user_id=auth.uid()) then raise exception 'Not your trade'; end if;
    update public.cr_pick_trades set status='cancelled' where id=p_trade; return;
  end if;
  if not exists (select 1 from public.teams where id=t.to_team and owner_user_id=auth.uid()) then raise exception 'Not your trade'; end if;
  if p_action='decline' then update public.cr_pick_trades set status='declined' where id=p_trade; return; end if;
  if p_action<>'accept' then raise exception 'Unknown action'; end if;
  if t.expires_at < now() then update public.cr_pick_trades set status='expired' where id=p_trade; raise exception 'That offer expired'; end if;
  perform public.cr_advance(t.draft_room_id);
  select * into r from public.draft_rooms where id=t.draft_room_id for update;
  if (t.send_pick is not null and not (public.cr_pick_open(r,t.send_pick) and public.cr_pick_team(r.id,t.send_pick)=t.from_team))
     or (t.get_pick is not null and not (public.cr_pick_open(r,t.get_pick) and public.cr_pick_team(r.id,t.get_pick)=t.to_team))
     or (t.send_fighter is not null and not exists (select 1 from public.cr_picks where draft_room_id=r.id and team_id=t.from_team and fighter_id=t.send_fighter))
     or (t.get_fighter is not null and not exists (select 1 from public.cr_picks where draft_room_id=r.id and team_id=t.to_team and fighter_id=t.get_fighter)) then
    update public.cr_pick_trades set status='cancelled' where id=p_trade; raise exception 'Something in this trade moved, the offer was cancelled'; end if;
  if (t.send_fighter is not null and public.cr_locked(t.league_id,r.block_no,t.send_fighter)) or (t.get_fighter is not null and public.cr_locked(t.league_id,r.block_no,t.get_fighter)) then
    raise exception 'A fighter in this trade is locked'; end if;
  if t.send_pick is not null then
    insert into public.cr_pick_owner(draft_room_id,pick_number,team_id) values (r.id,t.send_pick,t.to_team)
      on conflict (draft_room_id,pick_number) do update set team_id=excluded.team_id; end if;
  if t.get_pick is not null then
    insert into public.cr_pick_owner(draft_room_id,pick_number,team_id) values (r.id,t.get_pick,t.from_team)
      on conflict (draft_room_id,pick_number) do update set team_id=excluded.team_id; end if;
  if t.send_fighter is not null then update public.cr_picks set team_id=t.to_team where draft_room_id=r.id and fighter_id=t.send_fighter; end if;
  if t.get_fighter is not null then update public.cr_picks set team_id=t.from_team where draft_room_id=r.id and fighter_id=t.get_fighter; end if;
  update public.cr_pick_trades set status='accepted' where id=p_trade;
  -- the pick on hold may now belong to a CPU team; let the draft move on
  perform public.cr_advance(r.id);
end $$;

revoke all on function public.cr_refresh_pool(uuid), public.cr_advance(uuid) from public, anon, authenticated;
revoke all on function public.cr_make_pick(uuid,uuid), public.cr_start_draft(uuid), public.cr_start_next_draft(uuid),
  public.cr_propose_pick_trade(uuid,uuid,uuid,int,uuid,int), public.cr_respond_pick_trade(uuid,text), public.cr_pick_team(uuid,int) from public, anon;
grant execute on function public.cr_make_pick(uuid,uuid), public.cr_start_draft(uuid), public.cr_start_next_draft(uuid),
  public.cr_propose_pick_trade(uuid,uuid,uuid,int,uuid,int), public.cr_respond_pick_trade(uuid,text), public.cr_pick_team(uuid,int) to authenticated;
