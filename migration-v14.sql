-- تصفير نقاط الألعاب دون حذف المراحل أو تجاوز حد مكافآت اليوم. شغّل بعد v13.
begin;
alter table public.family_game_completions add column if not exists reset_at timestamptz;
create or replace function public.game_overview() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg jsonb;roster jsonb;rooms jsonb;progress jsonb;v_day date:=(now() at time zone 'Asia/Amman')::date;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('daily_cap',daily_cap,'max_difficulty',max_difficulty,'enabled',enabled) into cfg from public.family_game_settings where owner_id=m.owner_id;
 select coalesce(jsonb_agg(c),'[]') into roster from jsonb_array_elements(public.game_roster(m.owner_id)) c where m.role='parent' or c->>'id'=m.child_id;
 select coalesce(jsonb_agg(r order by r->>'created_at' desc),'[]') into rooms from(select jsonb_build_object('id',id,'game',game,'difficulty',difficulty,'stage',stage,'status',status,'created_at',created_at) r from public.family_game_sessions where owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) order by created_at desc limit 15) x;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',last_day,'points',points,'total_points',total_points,'daily_used',daily_used)),'[]') into progress from(select child_id,game,difficulty,stage,max(day) as last_day,coalesce(sum(points) filter(where reset_at is null),0) total_points,coalesce(sum(points) filter(where day=v_day and reset_at is null),0) points,coalesce(sum(points) filter(where day=v_day),0) daily_used from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) group by child_id,game,difficulty,stage) compact;
 return jsonb_build_object('settings',coalesce(cfg,'{"daily_cap":20,"max_difficulty":3,"enabled":true}'::jsonb),'can_reset',public.has_family_permission(m.owner_id,'reset_points'),'revision',(select revision from public.family_state where owner_id=m.owner_id),'children',roster,'sessions',rooms,'progress',progress,'day',v_day);
end $$;
revoke all on function public.game_overview() from public,anon;grant execute on function public.game_overview() to authenticated;
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
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'points',case when reset_at is null then points else 0 end,'reset',reset_at is not null)),'[]') into awards from public.family_game_completions where session_id=s.id and owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id);
 return jsonb_build_object('id',s.id,'game',s.game,'difficulty',s.difficulty,'stage',s.stage,'participants',s.participants,'status',s.status,'revision',s.revision,'data',d,'awards',awards);
end $$;
revoke all on function public.game_view(uuid) from public,anon;grant execute on function public.game_view(uuid) to authenticated;
create or replace function public.reset_game_points(p_player text,p_reason text,p_revision bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;removed jsonb;kept jsonb;entries jsonb;c jsonb;child text;available numeric;spent numeric;affected integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';
 if not found or not public.has_family_permission(m.owner_id,'reset_points') then raise exception 'Permission not granted' using errcode='42501';end if;
 if p_reason is null or length(trim(p_reason)) not between 1 and 300 then raise exception 'Invalid reason';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 if p_player is not null and not exists(select 1 from jsonb_array_elements(public.game_roster(m.owner_id)) r where r->>'id'=p_player) then raise exception 'Unknown player';end if;
 select coalesce(jsonb_agg(e) filter(where coalesce(e->>'kind','')='game' and (p_player is null or e->>'child'=p_player)),'[]'),
 coalesce(jsonb_agg(e) filter(where not(coalesce(e->>'kind','')='game' and (p_player is null or e->>'child'=p_player))),'[]') into removed,kept from jsonb_array_elements(d->'attempts') e;
 -- Check every affected child's remaining balance before changing any ledger or game record.
 for c in select value from jsonb_array_elements(d->'children') where p_player is null or value->>'id'=p_player loop
  child:=c->>'id';
  select coalesce(sum((e->>'points')::numeric),0) into available from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(kept) e union all select e from jsonb_array_elements(coalesce(d->'adjustments','[]')) e) ledger where e->>'child'=child;
  select coalesce(sum((r->>'cost')::numeric),0) into spent from jsonb_array_elements(d->'redemptions') r where r->>'child'=child;
  if available<spent then raise exception 'Game reset would reduce spent points';end if;
 end loop;
 d:=jsonb_set(d,'{attempts}',kept);
 for child in select distinct e->>'child' from jsonb_array_elements(removed) e loop
  select jsonb_agg(e) into entries from jsonb_array_elements(removed) e where e->>'child'=child;
  d:=jsonb_set(d,'{resetArchive}',coalesce(d->'resetArchive','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',child,'date',(now() at time zone 'Asia/Amman')::date::text,'kind','game_reset','note',trim(p_reason),'records',jsonb_build_object('attempts',entries))));
 end loop;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 -- Keep original awarded points for the daily cap and keep rows for unlocked stages / deduplication.
 update public.family_game_completions set reset_at=now() where owner_id=m.owner_id and reset_at is null and (p_player is null or child_id=p_player);
 get diagnostics affected=row_count;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تصفير نقاط الألعاب',p_player,case when p_player is null then 'جميع المشاركين' else p_player end||' — '||trim(p_reason)||' — سجلات: '||affected);
 return jsonb_build_object('reset_records',affected,'archived_attempts',jsonb_array_length(removed));
end $$;
revoke all on function public.reset_game_points(text,text,bigint) from public,anon;
grant execute on function public.reset_game_points(text,text,bigint) to authenticated;

commit;
