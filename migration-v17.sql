-- نقاط الألعاب تُعتمد من ولي الأمر، وتحويل الأمنية إلى بند خصم دون تطبيق الخصم.
begin;
-- Existing earned points remain approved; new completions explicitly start pending.
alter table public.family_game_completions add column if not exists approval_status text not null default 'approved' check(approval_status in ('pending','approved','rejected'));
alter table public.family_game_completions add column if not exists review_note text not null default '';
alter table public.family_game_completions add column if not exists reviewed_at timestamptz;
alter table public.family_game_completions add column if not exists reviewed_by uuid;
create or replace function public.game_overview() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg jsonb;roster jsonb;rooms jsonb;progress jsonb;requests jsonb;v_day date:=(now() at time zone 'Asia/Amman')::date;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('daily_cap',daily_cap,'max_difficulty',max_difficulty,'enabled',enabled) into cfg from public.family_game_settings where owner_id=m.owner_id;
 select coalesce(jsonb_agg(c),'[]') into roster from jsonb_array_elements(public.game_roster(m.owner_id)) c where m.role='parent' or c->>'id'=m.child_id;
 select coalesce(jsonb_agg(r order by r->>'created_at' desc),'[]') into rooms from(select jsonb_build_object('id',id,'game',game,'difficulty',difficulty,'stage',stage,'status',status,'created_at',created_at) r from public.family_game_sessions where owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) order by created_at desc limit 15) x;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',last_day,'points',points,'total_points',total_points,'daily_used',daily_used)),'[]') into progress from(select child_id,game,difficulty,stage,max(day) as last_day,coalesce(sum(points) filter(where reset_at is null and approval_status='approved'),0) total_points,coalesce(sum(points) filter(where day=v_day and reset_at is null and approval_status='approved'),0) points,coalesce(sum(points) filter(where day=v_day),0) daily_used from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) group by child_id,game,difficulty,stage) compact;
 select coalesce(jsonb_agg(r),'[]') into requests from(select jsonb_build_object('id',id,'child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',day,'points',points,'status',approval_status,'note',review_note,'reset',reset_at is not null) r from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) order by (approval_status='pending' and reset_at is null) desc,created_at desc limit 200) q;
 return jsonb_build_object('settings',coalesce(cfg,'{"daily_cap":20,"max_difficulty":3,"enabled":true}'::jsonb),'can_reset',public.has_family_permission(m.owner_id,'reset_points'),'revision',(select revision from public.family_state where owner_id=m.owner_id),'requests',requests,'children',roster,'sessions',rooms,'progress',progress,'day',v_day);
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
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'points',case when reset_at is null then points else 0 end,'reset',reset_at is not null,'status',approval_status)),'[]') into awards from public.family_game_completions where session_id=s.id and owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id);
 return jsonb_build_object('id',s.id,'game',s.game,'difficulty',s.difficulty,'stage',s.stage,'participants',s.participants,'status',s.status,'revision',s.revision,'data',d,'awards',awards);
end $$;
revoke all on function public.game_view(uuid) from public,anon;grant execute on function public.game_view(uuid) to authenticated;
create or replace function public.award_game(p_session uuid) returns void language plpgsql security definer set search_path='' as $$
declare s public.family_game_sessions;child text;cap integer;used integer;amount integer;cid uuid;
begin
 select * into s from public.family_game_sessions where id=p_session;if s.status<>'completed' then raise exception 'Game incomplete';end if;
 perform 1 from public.family_state where owner_id=s.owner_id for update;
 select daily_cap into cap from public.family_game_settings where owner_id=s.owner_id;cap:=coalesce(cap,20);
 foreach child in array s.participants loop
  select coalesce(sum(points),0) into used from public.family_game_completions where owner_id=s.owner_id and child_id=child and day=(now() at time zone 'Asia/Amman')::date;
  amount:=greatest(0,least(s.difficulty+s.stage,cap-used));cid:=null;
  insert into public.family_game_completions(owner_id,child_id,game,difficulty,stage,day,points,session_id,approval_status) values(s.owner_id,child,s.game,s.difficulty,s.stage,(now() at time zone 'Asia/Amman')::date,amount,s.id,'pending') on conflict(owner_id,child_id,game,difficulty,stage,day) do nothing returning id into cid;
  if cid is not null then perform public.log_family_event(s.owner_id,'طلب نقاط لعبة',child,s.game||' — مرحلة '||s.stage||' — '||amount||' نقطة بانتظار ولي الأمر');end if;
 end loop;
 update public.family_state set revision=revision+1,updated_at=now() where owner_id=s.owner_id;
end $$;
revoke all on function public.award_game(uuid) from public,anon,authenticated;

create or replace function public.review_game_points(p_id uuid,p_approve boolean,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;r public.family_game_completions;d jsonb;total integer;title text;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_approve is null or p_note is null or length(p_note)>300 then raise exception 'Invalid review';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select * into r from public.family_game_completions where id=p_id and owner_id=m.owner_id for update;
 if not found or r.approval_status<>'pending' or r.reset_at is not null then raise sqlstate 'PT409' using message='Request already reviewed';end if;
 if not exists(select 1 from jsonb_array_elements(public.game_roster(m.owner_id)) c where c->>'id'=r.child_id) then raise exception 'Unknown player';end if;
 title:=case when r.game='memory' then 'ذاكرة الصور' else 'مهمة الفضاء' end||' — مرحلة '||r.stage||' — صعوبة '||r.difficulty;
 if p_approve and r.child_id not like 'parent:%' then
  total:=case when r.game='memory' then r.stage+r.difficulty+1 else 2+r.stage end;
  d:=jsonb_set(d,'{attempts}',coalesce(d->'attempts','[]')||jsonb_build_array(jsonb_build_object('id',r.id,'child',r.child_id,'quiz','game_'||r.game||'_'||r.difficulty||'_'||r.stage,'kind','game','name',title,'date',r.day::text,'correct',total,'total',total,'points',r.points,'note',trim(p_note))));
 end if;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_game_completions set approval_status=case when p_approve then 'approved' else 'rejected' end,review_note=trim(p_note),reviewed_at=now(),reviewed_by=m.user_id where id=r.id;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,case when p_approve then 'اعتماد نقاط لعبة' else 'رفض نقاط لعبة' end,r.child_id,title||' — '||r.points||' — '||trim(p_note));
end $$;
revoke all on function public.review_game_points(uuid,boolean,text) from public,anon;
grant execute on function public.review_game_points(uuid,boolean,text) to authenticated;

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
 update public.family_game_completions set reset_at=now(),approval_status=case when approval_status='pending' then 'rejected' else approval_status end where owner_id=m.owner_id and reset_at is null and (p_player is null or child_id=p_player);
 get diagnostics affected=row_count;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تصفير نقاط الألعاب',p_player,case when p_player is null then 'جميع المشاركين' else p_player end||' — '||trim(p_reason)||' — سجلات: '||affected);
 return jsonb_build_object('reset_records',affected,'archived_attempts',jsonb_array_length(removed));
end $$;
revoke all on function public.reset_game_points(text,text,bigint) from public,anon;
grant execute on function public.reset_game_points(text,text,bigint) to authenticated;
create or replace function public.suggestion_to_deduction(p_id uuid,p_name text,p_description text,p_points integer,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_suggestions;d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_name is null or length(trim(p_name)) not between 1 and 100 or p_description is null or length(p_description)>500 or p_points is null or p_points not between 1 and 1000 then raise exception 'Invalid deduction';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select * into s from public.family_suggestions where id=p_id and owner_id=m.owner_id and kind='reward' for update;
 if not found then raise exception 'Suggestion access denied' using errcode='42501';end if;
 if s.revision is distinct from p_revision then raise sqlstate 'PT409' using message='Suggestion changed';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(d->'deductionRules','[]')) r where r->>'source_suggestion'=s.id::text and not coalesce((r->>'archived')::boolean,false)) then raise exception 'Suggestion already linked to deduction';end if;
 d:=jsonb_set(d,'{deductionRules}',coalesce(d->'deductionRules','[]')||jsonb_build_array(jsonb_build_object('id',replace(gen_random_uuid()::text,'-',''),'name',trim(p_name),'description',p_description,'points',p_points,'source_suggestion',s.id::text)));
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'إضافة أمنية إلى بنود الخصم',s.child_id,trim(p_name)||' — '||p_points||' نقطة؛ دون خصم فعلي');
end $$;
revoke all on function public.suggestion_to_deduction(uuid,text,text,integer,bigint) from public,anon;
grant execute on function public.suggestion_to_deduction(uuid,text,text,integer,bigint) to authenticated;

notify pgrst,'reload schema';
commit;
