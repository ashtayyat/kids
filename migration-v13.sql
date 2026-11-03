-- مشاركة أولياء الأمر بحساباتهم الحالية، دون إنشاء ملفات أطفال لهم.
begin;
-- Private roster: parent IDs use a namespace rejected by child-profile validation.
create or replace function public.game_roster(p_owner uuid) returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(player order by player->>'role',player->>'name'),'[]'::jsonb) from (
 select jsonb_build_object('id',c->>'id','name',c->>'name','age',c->'age','role','child') player
 from public.family_state f,jsonb_array_elements(f.data->'children') c where f.owner_id=p_owner
 union all
 select jsonb_build_object('id','parent:'||user_id::text,'name',display_name,'age',30,'role','parent')
 from public.family_members where owner_id=p_owner and role='parent' and active
 ) roster;
$$;
revoke all on function public.game_roster(uuid) from public,anon,authenticated;
create or replace function public.game_overview() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg jsonb;roster jsonb;rooms jsonb;progress jsonb;v_day date:=(now() at time zone 'Asia/Amman')::date;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('daily_cap',daily_cap,'max_difficulty',max_difficulty,'enabled',enabled) into cfg from public.family_game_settings where owner_id=m.owner_id;
 select coalesce(jsonb_agg(c),'[]') into roster from jsonb_array_elements(public.game_roster(m.owner_id)) c where m.role='parent' or c->>'id'=m.child_id;
 select coalesce(jsonb_agg(r order by r->>'created_at' desc),'[]') into rooms from(select jsonb_build_object('id',id,'game',game,'difficulty',difficulty,'stage',stage,'status',status,'created_at',created_at) r from public.family_game_sessions where owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) order by created_at desc limit 15) x;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',last_day,'points',points,'total_points',total_points)),'[]') into progress from(select child_id,game,difficulty,stage,max(day) as last_day,sum(points) total_points,coalesce(sum(points) filter(where day=v_day),0) points from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) group by child_id,game,difficulty,stage) compact;
 return jsonb_build_object('settings',coalesce(cfg,'{"daily_cap":20,"max_difficulty":3,"enabled":true}'::jsonb),'children',roster,'sessions',rooms,'progress',progress,'day',v_day);
end $$;
revoke all on function public.game_overview() from public,anon;grant execute on function public.game_overview() to authenticated;

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
  select value into c from jsonb_array_elements(public.game_roster(m.owner_id)) where value->>'id'=child;if not found then raise exception 'Unknown player';end if;
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
   select value into c from jsonb_array_elements(public.game_roster(m.owner_id)) where value->>'id'=child;questions:='[]';
   for i in 1..(2+p_stage) loop questions:=questions||jsonb_build_array(public.game_question((c->>'age')::integer,p_difficulty,p_stage,i));end loop;
   players:=players||jsonb_build_array(jsonb_build_object('child',child,'name',c->>'name','index',0,'questions',questions));
  end loop;
  d:=jsonb_build_object('players',players);
 end if;
 insert into public.family_game_sessions(owner_id,game,difficulty,stage,participants,data) values(m.owner_id,p_game,p_difficulty,p_stage,p_children,d) returning id into sid;return sid;
end $$;
revoke all on function public.start_game(text,integer,integer,text[]) from public,anon;grant execute on function public.start_game(text,integer,integer,text[]) to authenticated;

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
   if child not like 'parent:%' then
   d:=jsonb_set(d,'{attempts}',(d->'attempts')||jsonb_build_array(jsonb_build_object('id',cid,'child',child,'quiz','game_'||s.game||'_'||s.difficulty||'_'||s.stage,'kind','game','name',title,'date',v_day::text,'correct',total,'total',total,'points',amount)));
   end if;
   perform public.log_family_event(s.owner_id,'إكمال مرحلة لعبة',child,title||' — '||amount||' نقطة');
  end if;
 end loop;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=s.owner_id;
end $$;
revoke all on function public.award_game(uuid) from public,anon,authenticated;

create or replace function public.on_family_auth_delete() returns trigger language plpgsql security definer set search_path='' as $$
declare m public.family_members;player_id text;
begin
 select * into m from public.family_members where user_id=old.id;
 if found then
  if m.role='child' then perform public.purge_child_data(m.owner_id,m.child_id);
  else
   player_id:='parent:'||old.id::text;
   perform 1 from public.family_state where owner_id=m.owner_id for update;
   delete from public.family_game_completions where owner_id=m.owner_id and child_id=player_id;
   delete from public.family_game_sessions where owner_id=m.owner_id and player_id=any(participants);
  end if;
 end if;
 return old;
end $$;
revoke all on function public.on_family_auth_delete() from public,anon,authenticated;

commit;
