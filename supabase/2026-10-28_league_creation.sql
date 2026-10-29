-- Combat: let players create and join their own Card Redraft leagues.
-- Additive only. The existing league row and its 10 teams are not changed.

alter table public.leagues
  add column if not exists format text not null default 'card_redraft',
  add column if not exists team_count int,
  add column if not exists fighters_per_team int,
  add column if not exists draft_type text not null default 'snake',
  add column if not exists waiver_type text not null default 'standard',
  add column if not exists faab_budget int not null default 200,
  add column if not exists join_code text,
  add column if not exists is_public boolean not null default false,
  add column if not exists draft_time timestamptz,
  add column if not exists status text not null default 'setup',
  add column if not exists pick_seconds int not null default 45;

create unique index if not exists leagues_join_code_key on public.leagues (join_code) where join_code is not null;

alter table public.leagues
  add constraint leagues_draft_type_chk check (draft_type in ('snake','3rr','linear','auction')),
  add constraint leagues_waiver_chk check (waiver_type in ('standard','faab')),
  add constraint leagues_status_chk check (status in ('setup','drafting','active','complete')),
  add constraint leagues_size_chk check (team_count is null or team_count in (4,6,8,10,12));

-- Signed-in players can create a league they commission.
create policy "users can create leagues they commission" on public.leagues
  for insert to authenticated with check (commissioner_user_id = auth.uid());

-- Commissioner can delete a league only while it is still being set up.
create policy "commissioner can delete a league in setup" on public.leagues
  for delete to authenticated using (commissioner_user_id = auth.uid() and status = 'setup');

-- Owner can leave, commissioner can remove a team, only while the league is in setup.
create policy "owner can leave a league in setup" on public.teams
  for delete to authenticated using (
    exists (select 1 from public.leagues l where l.id = teams.league_id and l.status = 'setup')
    and (owner_user_id = auth.uid()
         or exists (select 1 from public.leagues l where l.id = teams.league_id and l.commissioner_user_id = auth.uid()))
  );

-- One team per person per league.
create unique index if not exists teams_one_per_owner on public.teams (league_id, owner_user_id) where owner_user_id is not null;

-- Server-side cap: a league cannot take more teams than its size.
create or replace function public.enforce_league_capacity() returns trigger
language plpgsql security definer set search_path = public as $$
declare cap int; cur int;
begin
  select team_count into cap from public.leagues where id = new.league_id;
  if cap is not null then
    select count(*) into cur from public.teams where league_id = new.league_id;
    if cur >= cap then raise exception 'League is full'; end if;
  end if;
  return new;
end $$;
drop trigger if exists teams_capacity on public.teams;
create trigger teams_capacity before insert on public.teams for each row execute function public.enforce_league_capacity();
