-- ألعاب عائلية بمراحل ونقاط يومية محفوظة على الخادم. شغّل بعد v11.
begin;
create table if not exists public.family_game_settings(owner_id uuid primary key references auth.users(id) on delete cascade,daily_cap integer not null default 20 check(daily_cap between 0 and 100),max_difficulty integer not null default 3 check(max_difficulty between 1 and 3),enabled boolean not null default true);
create table if not exists public.family_game_sessions(id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id) on delete cascade,game text not null check(game in ('memory','space')),difficulty integer not null check(difficulty between 1 and 3),stage integer not null check(stage between 1 and 5),participants text[] not null,status text not null default 'active' check(status in ('active','completed','failed')),data jsonb not null,revision bigint not null default 0,created_at timestamptz not null default now());
create index if not exists game_sessions_family on public.family_game_sessions(owner_id,created_at desc);
create table if not exists public.family_game_completions(id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id) on delete cascade,child_id text not null,game text not null,difficulty integer not null,stage integer not null,day date not null,points integer not null check(points between 0 and 100),session_id uuid,created_at timestamptz not null default now(),unique(owner_id,child_id,game,difficulty,stage,day));
alter table public.family_game_settings enable row level security;
alter table public.family_game_sessions enable row level security;
alter table public.family_game_completions enable row level security;
revoke all on public.family_game_settings,public.family_game_sessions,public.family_game_completions from anon,authenticated;
-- Private session data includes the hidden deck and correct answers. Only filtered RPCs expose it.
create or replace function public.game_question(p_age integer,p_difficulty integer,p_stage integer,p_index integer) returns jsonb language plpgsql set search_path='' as $$
declare a integer;b integer;answer integer;label text;options jsonb;slot integer;
begin
 a:=1+floor(random()*(case when p_age<8 then 3+p_stage else 7+p_stage*3 end))::integer;
 b:=1+floor(random()*(case when p_age<8 then 3 else 5+p_stage end))::integer;
 if p_age>=8 and p_difficulty>=2 and p_index%2=0 then answer:=a*b;label:=a||' × '||b||' = ؟';
 elsif p_age>=8 and p_difficulty=3 then answer:=a+b;label:='ما العدد المفقود؟ '||a||' + ؟ = '||answer;answer:=b;
 else answer:=a+b;label:=a||' + '||b||' = ؟';end if;
 slot:=floor(random()*3)::integer;
 select jsonb_agg(case when n=slot then answer else answer+1+((n-slot+3)%3) end order by n) into options from generate_series(0,2) n;
 return jsonb_build_object('text',label,'options',options,'correct',slot);
end $$;
revoke all on function public.game_question(integer,integer,integer,integer) from public,anon,authenticated;

create or replace function public.game_overview() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg jsonb;roster jsonb;rooms jsonb;progress jsonb;v_day date:=(now() at time zone 'Asia/Amman')::date;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('daily_cap',daily_cap,'max_difficulty',max_difficulty,'enabled',enabled) into cfg from public.family_game_settings where owner_id=m.owner_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',c->>'id','name',c->>'name','age',c->'age')),'[]') into roster from public.family_state f,jsonb_array_elements(f.data->'children') c where f.owner_id=m.owner_id and (m.role='parent' or c->>'id'=m.child_id);
 select coalesce(jsonb_agg(r order by r->>'created_at' desc),'[]') into rooms from(select jsonb_build_object('id',id,'game',game,'difficulty',difficulty,'stage',stage,'status',status,'created_at',created_at) r from public.family_game_sessions where owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) order by created_at desc limit 15) x;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',last_day,'points',points)),'[]') into progress from(select child_id,game,difficulty,stage,max(day) as last_day,coalesce(sum(points) filter(where day=v_day),0) points from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) group by child_id,game,difficulty,stage) compact;
 return jsonb_build_object('settings',coalesce(cfg,'{"daily_cap":20,"max_difficulty":3,"enabled":true}'::jsonb),'children',roster,'sessions',rooms,'progress',progress,'day',v_day);
end $$;
revoke all on function public.game_overview() from public,anon;grant execute on function public.game_overview() to authenticated;

create or replace function public.configure_games(p_cap integer,p_max integer,p_enabled boolean) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_cap is null or p_cap not between 0 and 100 or p_max is null or p_max not between 1 and 3 or p_enabled is null then raise exception 'Invalid settings';end if;
 insert into public.family_game_settings(owner_id,daily_cap,max_difficulty,enabled) values(m.owner_id,p_cap,p_max,p_enabled) on conflict(owner_id) do update set daily_cap=excluded.daily_cap,max_difficulty=excluded.max_difficulty,enabled=excluded.enabled;
 perform public.log_family_event(m.owner_id,'إعدادات الألعاب',null,'الحد اليومي: '||p_cap||'، أعلى صعوبة: '||p_max);
end $$;
revoke all on function public.configure_games(integer,integer,boolean) from public,anon;grant execute on function public.configure_games(integer,integer,boolean) to authenticated;

create or replace function public.start_game(p_game text,p_difficulty integer,p_stage integer,p_children text[]) returns uuid language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg public.family_game_settings;f jsonb;d jsonb;deck jsonb;players jsonb:='[]';questions jsonb;child text;c jsonb;i integer;pairs integer;sid uuid;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 if p_game is null or p_game not in ('memory','space') or p_difficulty is null or p_difficulty not between 1 and 3 or p_stage is null or p_stage not between 1 and 5 then raise exception 'Invalid stage';end if;
 select data into f from public.family_state where owner_id=m.owner_id for update;
 select * into cfg from public.family_game_settings where owner_id=m.owner_id;
 if coalesce(cfg.enabled,true)=false or p_difficulty>coalesce(cfg.max_difficulty,3) then raise exception 'Game disabled or difficulty restricted';end if;
 if p_children is null or cardinality(p_children) is null or cardinality(p_children) not between 1 and 6 or array_ndims(p_children)<>1 or exists(select 1 from unnest(p_children) id where id is null) or (select count(distinct id) from unnest(p_children) id)<>cardinality(p_children) then raise exception 'Select players';end if;
 if m.role='child' and (p_game<>'memory' or cardinality(p_children)<>1 or p_children[1]<>m.child_id) then raise exception 'Own memory game only; a parent starts team missions' using errcode='42501';end if;
 if (p_game='memory' and cardinality(p_children)<>1) or (p_game='space' and cardinality(p_children)<2) then raise exception 'Invalid crew size';end if;
 foreach child in array p_children loop
  select value into c from jsonb_array_elements(f->'children') where value->>'id'=child;if not found then raise exception 'Unknown child';end if;
  if p_stage>1 and not exists(select 1 from public.family_game_completions where owner_id=m.owner_id and child_id=child and game=p_game and difficulty=p_difficulty and stage=p_stage-1) then raise exception 'Finish previous stage for every player first';end if;
 end loop;
 update public.family_game_sessions set status='failed' where owner_id=m.owner_id and status='active' and created_at<now()-interval '4 hours';
 if p_game='memory' then update public.family_game_sessions set status='failed' where owner_id=m.owner_id and game='memory' and status='active' and participants=p_children;end if;
 if(select count(*) from public.family_game_sessions where owner_id=m.owner_id and status='active')>=10 then raise exception 'Too many active games';end if;
 if p_game='memory' then
  pairs:=p_stage+p_difficulty+1;
  select jsonb_agg(v order by random()) into deck from(select n v from generate_series(0,pairs-1) n cross join generate_series(1,2) dup) cards;
  d:=jsonb_build_object('deck',deck,'matched','[]'::jsonb,'open','[]'::jsonb,'moves',0,'limit',case when p_difficulty=1 then 0 when p_difficulty=2 then pairs*4 else pairs*3 end);
 else
  foreach child in array p_children loop
   select value into c from jsonb_array_elements(f->'children') where value->>'id'=child;questions:='[]';
   for i in 1..(2+p_stage) loop questions:=questions||jsonb_build_array(public.game_question((c->>'age')::integer,p_difficulty,p_stage,i));end loop;
   players:=players||jsonb_build_array(jsonb_build_object('child',child,'name',c->>'name','index',0,'questions',questions));
  end loop;
  d:=jsonb_build_object('players',players);
 end if;
 insert into public.family_game_sessions(owner_id,game,difficulty,stage,participants,data) values(m.owner_id,p_game,p_difficulty,p_stage,p_children,d) returning id into sid;return sid;
end $$;
revoke all on function public.start_game(text,integer,integer,text[]) from public,anon;grant execute on function public.start_game(text,integer,integer,text[]) to authenticated;

create or replace function public.game_view(p_session uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_game_sessions;d jsonb;cards jsonb;players jsonb;awards jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select * into s from public.family_game_sessions where id=p_session and owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants));if not found then raise exception 'Game access denied' using errcode='42501';end if;
 if s.game='memory' then
  select jsonb_agg(case when s.data->'matched' @> jsonb_build_array(idx-1) or s.data->'open' @> jsonb_build_array(idx-1) then val else 'null'::jsonb end order by idx) into cards from jsonb_array_elements(s.data->'deck') with ordinality t(val,idx);
  d:=jsonb_build_object('cards',cards,'matched',s.data->'matched','open',s.data->'open','moves',s.data->'moves','limit',s.data->'limit');
 else
  select jsonb_agg(jsonb_build_object('child',p->>'child','name',p->>'name','index',p->'index','total',jsonb_array_length(p->'questions'),'question',case when m.role='parent' or p->>'child'=m.child_id then (p->'questions'->((p->>'index')::integer))-'correct' else null end)) into players from jsonb_array_elements(s.data->'players') p;
  d:=jsonb_build_object('players',players);
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'points',points)),'[]') into awards from public.family_game_completions where session_id=s.id and owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id);
 return jsonb_build_object('id',s.id,'game',s.game,'difficulty',s.difficulty,'stage',s.stage,'participants',s.participants,'status',s.status,'revision',s.revision,'data',d,'awards',awards);
end $$;
revoke all on function public.game_view(uuid) from public,anon;grant execute on function public.game_view(uuid) to authenticated;

-- Only validated server completion can call this award helper. It is not a public API.
create or replace function public.award_game(p_session uuid) returns void language plpgsql security definer set search_path='' as $$
declare s public.family_game_sessions;d jsonb;child text;cap integer;used integer;amount integer;score integer;total integer;cid uuid;v_day date:=(now() at time zone 'Asia/Amman')::date;title text;
begin
 select * into s from public.family_game_sessions where id=p_session;if s.status<>'completed' then raise exception 'Game incomplete';end if;
 select data into d from public.family_state where owner_id=s.owner_id for update;
 select daily_cap into cap from public.family_game_settings where owner_id=s.owner_id;cap:=coalesce(cap,20);score:=s.difficulty+s.stage;
 title:=case when s.game='memory' then 'ذاكرة الصور' else 'مهمة الفضاء' end||' — مرحلة '||s.stage||' — صعوبة '||s.difficulty;
 foreach child in array s.participants loop
  select coalesce(sum(points),0) into used from public.family_game_completions where owner_id=s.owner_id and child_id=child and day=v_day;
  amount:=greatest(0,least(score,cap-used));cid:=null;
  insert into public.family_game_completions(owner_id,child_id,game,difficulty,stage,day,points,session_id) values(s.owner_id,child,s.game,s.difficulty,s.stage,v_day,amount,s.id) on conflict(owner_id,child_id,game,difficulty,stage,day) do nothing returning id into cid;
  if cid is not null then
   total:=case when s.game='memory' then jsonb_array_length(s.data->'deck')/2 else 2+s.stage end;
   d:=jsonb_set(d,'{attempts}',(d->'attempts')||jsonb_build_array(jsonb_build_object('id',cid,'child',child,'quiz','game_'||s.game||'_'||s.difficulty||'_'||s.stage,'kind','game','name',title,'date',v_day::text,'correct',total,'total',total,'points',amount)));
   perform public.log_family_event(s.owner_id,'إكمال مرحلة لعبة',child,title||' — '||amount||' نقطة');
  end if;
 end loop;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=s.owner_id;
end $$;
revoke all on function public.award_game(uuid) from public,anon,authenticated;

create or replace function public.game_step(p_session uuid,p_child text,p_choice integer,p_revision bigint,p_question integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_game_sessions;d jsonb;open_cards jsonb;matched jsonb;first_card integer;moves integer;limit_moves integer;players jsonb:='[]';player jsonb;question jsonb;target text;correct_answer boolean:=false;complete boolean:=false;new_status text:='active';
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 -- Serialize family writes before the game lock, same order as starts/deletions/ledger writes.
 perform 1 from public.family_state where owner_id=m.owner_id for update;
 select * into s from public.family_game_sessions where id=p_session and owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) for update;
 if not found then raise exception 'Game access denied' using errcode='42501';end if;
 if s.status<>'active' then raise sqlstate 'PT409' using message='Game no longer active';end if;
 if s.created_at<now()-interval '4 hours' then raise exception 'Game expired; start again';end if;
 if exists(select 1 from public.family_game_settings where owner_id=m.owner_id and (not enabled or max_difficulty<s.difficulty)) then raise exception 'Game disabled';end if;
 d:=s.data;
 if s.game='memory' then
  if s.revision is distinct from p_revision then raise sqlstate 'PT409' using message='Game revision conflict';end if;
  if p_choice is null or p_choice<0 or p_choice>=jsonb_array_length(d->'deck') then raise exception 'Invalid card';end if;
  open_cards:=d->'open';matched:=d->'matched';moves:=(d->>'moves')::integer;limit_moves:=(d->>'limit')::integer;
  if jsonb_array_length(open_cards)=2 then open_cards:='[]';end if;
  if matched @> jsonb_build_array(p_choice) or open_cards @> jsonb_build_array(p_choice) then raise exception 'Card already open';end if;
  open_cards:=open_cards||jsonb_build_array(p_choice);
  if jsonb_array_length(open_cards)=2 then
   moves:=moves+1;first_card:=(open_cards->>0)::integer;
   if d->'deck'->first_card=d->'deck'->p_choice then matched:=matched||open_cards;open_cards:='[]';end if;
   complete:=jsonb_array_length(matched)=jsonb_array_length(d->'deck');
   if not complete and limit_moves>0 and moves>=limit_moves then new_status:='failed';end if;
  end if;
  d:=d||jsonb_build_object('open',open_cards,'matched',matched,'moves',moves);
 else
  target:=case when m.role='child' then m.child_id else p_child end;
  if target is null or not(target=any(s.participants)) or (m.role='child' and p_child is not null and p_child<>m.child_id) then raise exception 'Own question only' using errcode='42501';end if;
  if p_choice is null or p_choice not between 0 and 2 then raise exception 'Invalid answer';end if;
  for player in select value from jsonb_array_elements(d->'players') loop
   if player->>'child'=target then
    if (player->>'index')::integer is distinct from p_question then raise sqlstate 'PT409' using message='Question already changed';end if;
    question:=player->'questions'->p_question;if question is null then raise exception 'Player completed';end if;
    correct_answer:=p_choice=(question->>'correct')::integer;
    if correct_answer then player:=jsonb_set(player,'{index}',to_jsonb(p_question+1));end if;
   end if;
   players:=players||jsonb_build_array(player);
  end loop;
  d:=jsonb_set(d,'{players}',players);
  complete:=not exists(select 1 from jsonb_array_elements(players) p where (p->>'index')::integer<jsonb_array_length(p->'questions'));
 end if;
 if complete then new_status:='completed';end if;
 update public.family_game_sessions set data=d,status=new_status,revision=revision+1 where id=s.id;
 if complete then perform public.award_game(s.id);end if;
 return jsonb_build_object('correct',correct_answer,'view',public.game_view(s.id));
end $$;
revoke all on function public.game_step(uuid,text,integer,bigint,integer) from public,anon;grant execute on function public.game_step(uuid,text,integer,bigint,integer) to authenticated;

create or replace function public.purge_child_data(p_owner uuid,p_child text) returns void language plpgsql security definer set search_path='' as $$
declare d jsonb;k text;
begin
 select data into d from public.family_state where owner_id=p_owner for update;if d is null then return;end if;
 d:=jsonb_set(d,'{children}',coalesce((select jsonb_agg(c) from jsonb_array_elements(d->'children') c where c->>'id'<>p_child),'[]'));
 foreach k in array array['evaluations','attempts','redemptions','adjustments','resetArchive','encouragements'] loop
  d:=jsonb_set(d,array[k],coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(d->k,'[]')) e where e->>'child' is distinct from p_child),'[]'));
 end loop;
 d:=jsonb_set(d,'{criteria}',coalesce((select jsonb_agg(c) from jsonb_array_elements(d->'criteria') c where c->>'assigned_child' is distinct from p_child),'[]'));
 delete from public.family_game_completions where owner_id=p_owner and child_id=p_child;
 delete from public.family_game_sessions where owner_id=p_owner and p_child=any(participants);
 delete from public.point_requests where owner_id=p_owner and child_id=p_child;
 delete from public.family_suggestions where owner_id=p_owner and child_id=p_child;
 delete from public.family_audit where owner_id=p_owner and child_id=p_child;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=p_owner;
end $$;
revoke all on function public.purge_child_data(uuid,text) from public,anon,authenticated;

commit;
