-- إنجاز واحد يوميًا افتراضيًا، تكرار مضبوط، تحويل المعايير، وتصفير الألعاب القديمة.
begin;
alter table public.point_requests add column if not exists occurrence integer not null default 1 check(occurrence>0);
alter table public.point_requests drop constraint if exists point_requests_owner_id_child_id_criterion_id_day_key;
create unique index if not exists point_request_occurrence on public.point_requests(owner_id,child_id,criterion_id,day,occurrence);
create or replace function public.submit_achievement(p_criterion text,p_day date,p_level integer,p_note text,p_evidence text,p_request uuid) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;c jsonb;r public.point_requests;used integer;max_count integer;slot integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='child';if not found then raise exception 'Child account required' using errcode='42501';end if;
 if p_day is null or p_day>(now() at time zone 'Asia/Amman')::date or p_level is null or p_level not between 0 and 2 or p_note is null or length(p_note)>300 then raise exception 'Invalid request';end if;
 if p_evidence is not null and (length(p_evidence)>100000 or p_evidence !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$') then raise exception 'Invalid evidence';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select value into c from jsonb_array_elements(d->'criteria') where value->>'id'=p_criterion and not coalesce((value->>'archived')::boolean,false) and (value->>'assigned_child' is null or value->>'assigned_child'=m.child_id);if not found then raise exception 'Unknown criterion';end if;
 if p_request is not null then
  select * into r from public.point_requests where id=p_request and owner_id=m.owner_id and requester=m.user_id and child_id=m.child_id and criterion_id=p_criterion and day=p_day for update;
  if not found or r.deleted_at is not null or r.status<>'rejected' then raise sqlstate 'PT409' using message='Only returned achievement may be corrected';end if;
  update public.point_requests set level=p_level,note=p_note,evidence=p_evidence,status='pending',review_note='',reviewed_at=null where id=r.id;return;
 end if;
 max_count:=case when coalesce((c->>'allow_repeat')::boolean,false) then least(20,greatest(2,coalesce((c->>'max_per_day')::integer,3))) else 1 end;
 -- Count each submitted/approved occurrence once, including direct parent evaluations.
 select count(*) into used from(select occurrence from public.point_requests where owner_id=m.owner_id and child_id=m.child_id and criterion_id=p_criterion and day=p_day and deleted_at is null union select coalesce((e->>'occurrence')::integer,1) from jsonb_array_elements(d->'evaluations') e where e->>'child'=m.child_id and e->>'criterion'=p_criterion and e->>'date'=p_day::text) q;
 if used>=max_count then raise sqlstate 'PT409' using message='Achievement daily limit reached';end if;
 select coalesce(max(n),0)+1 into slot from(select occurrence n from public.point_requests where owner_id=m.owner_id and child_id=m.child_id and criterion_id=p_criterion and day=p_day union all select coalesce((e->>'occurrence')::integer,1) from jsonb_array_elements(d->'evaluations') e where e->>'child'=m.child_id and e->>'criterion'=p_criterion and e->>'date'=p_day::text) q;
 insert into public.point_requests(owner_id,requester,child_id,criterion_id,day,level,note,evidence,occurrence) values(m.owner_id,m.user_id,m.child_id,p_criterion,p_day,p_level,p_note,p_evidence,slot);
end $$;
revoke all on function public.submit_achievement(text,date,integer,text,text,uuid) from public,anon;
grant execute on function public.submit_achievement(text,date,integer,text,text,uuid) to authenticated;
create or replace function public.submit_point_request(p_criterion text,p_day date,p_level integer,p_note text) returns void language plpgsql security definer set search_path='' as $$
begin perform public.submit_achievement(p_criterion,p_day,p_level,p_note,null,null);end $$;
revoke all on function public.submit_point_request(text,date,integer,text) from public,anon;grant execute on function public.submit_point_request(text,date,integer,text) to authenticated;
create or replace function public.submit_point_request_with_evidence(p_criterion text,p_day date,p_level integer,p_note text,p_evidence text) returns void language plpgsql security definer set search_path='' as $$
begin perform public.submit_achievement(p_criterion,p_day,p_level,p_note,p_evidence,null);end $$;
revoke all on function public.submit_point_request_with_evidence(text,date,integer,text,text) from public,anon;grant execute on function public.submit_point_request_with_evidence(text,date,integer,text,text) to authenticated;
create or replace function public.review_point_request(p_id uuid,p_approve boolean,p_level integer,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; r public.point_requests; d jsonb; c jsonb; row_data jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';
 if not found then raise exception 'Parent account required' using errcode='42501'; end if;
 if p_approve is null or p_note is null or length(p_note)>300 or (p_approve and (p_level is null or p_level not between 0 and 2)) then raise exception 'Invalid review'; end if;
 -- Lock family first, the same order used by submissions and parent edits.
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select * into r from public.point_requests where id=p_id and owner_id=m.owner_id for update;
 if not found or r.status<>'pending' or r.deleted_at is not null then raise sqlstate 'PT409' using message='Request already reviewed'; end if;
 if p_approve then
  select value into c from jsonb_array_elements(d->'criteria') where value->>'id'=r.criterion_id;
  if c is null or coalesce((c->>'archived')::boolean,false) or not exists(select 1 from jsonb_array_elements(d->'children') x where x->>'id'=r.child_id) then raise exception 'Missing criterion or child'; end if;
  row_data:=jsonb_build_object('child',r.child_id,'criterion',r.criterion_id,'date',r.day::text,'level',p_level,'points',(c->'points'->>p_level)::integer,'note',r.note,'occurrence',r.occurrence,'request_id',r.id,'evidence',r.evidence);
  d:=jsonb_set(d,'{evaluations}',coalesce((select jsonb_agg(e) from jsonb_array_elements(d->'evaluations') e where not(e->>'child'=r.child_id and e->>'criterion'=r.criterion_id and e->>'date'=r.day::text and coalesce((e->>'occurrence')::integer,1)=r.occurrence)),'[]')||jsonb_build_array(row_data));
  if coalesce((select sum((e->>'points')::numeric) from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e union all select e from jsonb_array_elements(coalesce(d->'adjustments','[]')) e) t where e->>'child'=r.child_id),0)<coalesce((select sum((x->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') x where x->>'child'=r.child_id),0) then raise exception 'Cannot reduce spent points'; end if;
  if length(trim(p_note))>0 then d:=jsonb_set(d,'{encouragements}',coalesce(d->'encouragements','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',r.child_id,'note',trim(p_note),'date',(now() at time zone 'Asia/Amman')::date::text,'occurrence',r.occurrence,'request_id',r.id)));end if;
  if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 update public.point_requests set status=case when p_approve then 'approved' else 'rejected' end,review_note=p_note,reviewed_at=now() where id=r.id;
 perform public.log_family_event(m.owner_id,case when p_approve then 'اعتماد إنجاز' else 'إعادة إنجاز للمراجعة' end,r.child_id,p_note);
end $$;
revoke all on function public.review_point_request(uuid,boolean,integer,text) from public,anon;
grant execute on function public.review_point_request(uuid,boolean,integer,text) to authenticated;
create or replace function public.save_family(p_data jsonb,p_revision bigint) returns bigint
language plpgsql security definer set search_path='' as $$
declare actor uuid; current_revision bigint; k text; existing_data jsonb; merged jsonb; main_parent boolean; catalog_data jsonb;
begin
 select owner_id into actor from public.family_members where user_id=auth.uid() and active and role='parent';
 if actor is null then raise exception 'Authentication required' using errcode='42501'; end if;
 select data into catalog_data from public.family_state where owner_id=actor for update;
 p_data:=p_data||jsonb_build_object('deductionRules',coalesce(p_data->'deductionRules',catalog_data->'deductionRules','[]'::jsonb));
 main_parent:=public.is_family_admin(actor);
 if not main_parent then
  select data,revision into existing_data,current_revision from public.family_state where owner_id=actor for update;
  if existing_data is null then raise exception 'Initialize family first';end if;
  if current_revision is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
  if coalesce(p_data->'adjustments','[]') is distinct from coalesce(existing_data->'adjustments','[]') or (p_data ? 'resetArchive' and p_data->'resetArchive' is distinct from coalesce(existing_data->'resetArchive','[]')) then raise exception 'Use delegated points operation' using errcode='42501';end if;
  if exists(select 1 from jsonb_array_elements(existing_data->'children') old where not exists(select 1 from jsonb_array_elements(p_data->'children') new where new->>'id'=old->>'id')) then raise exception 'Child deletion is administrative' using errcode='42501';end if;
  if exists(select 1 from jsonb_array_elements(existing_data->'evaluations') old where not exists(select 1 from jsonb_array_elements(p_data->'evaluations') new where new->>'child'=old->>'child' and new->>'criterion'=old->>'criterion' and new->>'date'=old->>'date' and coalesce((new->>'occurrence')::integer,1)=coalesce((old->>'occurrence')::integer,1))) then raise exception 'Use delegated reset operation' using errcode='42501';end if;
  foreach k in array array['attempts','redemptions'] loop
   if exists(select 1 from jsonb_array_elements(existing_data->k) old where not exists(select 1 from jsonb_array_elements(p_data->k) new where new=old)) then raise exception 'Existing ledger entry is protected' using errcode='42501';end if;
  end loop;
  merged:=existing_data;
  foreach k in array array['children','criteria','evaluations','rewards','redemptions','quizzes','attempts','deductionRules'] loop
   if jsonb_typeof(p_data->k) is distinct from 'array' then raise exception 'Invalid collection';end if;
   merged:=jsonb_set(merged,array[k],p_data->k);
  end loop;
  p_data:=merged;
 end if;

 p_data:=p_data||jsonb_build_object('adjustments',coalesce(p_data->'adjustments','[]'),'resetArchive',coalesce(p_data->'resetArchive','[]'));
 if jsonb_typeof(p_data->'adjustments') is distinct from 'array' or jsonb_typeof(p_data->'resetArchive') is distinct from 'array' then raise exception 'Invalid ledger'; end if;
 if exists(select 1 from jsonb_array_elements(p_data->'adjustments') a where (a->>'points')::numeric>=0 or (a->>'points')::numeric<>trunc((a->>'points')::numeric) or not exists(select 1 from jsonb_array_elements(p_data->'children') c where c->>'id'=a->>'child')) then raise exception 'Invalid deduction'; end if;
 if p_data->>'version' is distinct from '1' or octet_length(p_data::text)>2000000 then raise exception 'Invalid data'; end if;
 foreach k in array array['children','criteria','evaluations','rewards','redemptions','quizzes','attempts','deductionRules'] loop
  if jsonb_typeof(p_data->k) is distinct from 'array' then raise exception 'Invalid collection'; end if;
 end loop;
 if jsonb_array_length(p_data->'deductionRules')>1000 or exists(select 1 from jsonb_array_elements(p_data->'deductionRules') r where coalesce(r->>'id','')!~'^[-a-zA-Z0-9_]{1,80}$' or length(trim(coalesce(r->>'name',''))) not between 1 and 100 or coalesce(r->>'points','')!~'^[0-9]+$' or (r->>'points')::numeric not between 1 and 1000 or length(coalesce(r->>'description',''))>300) or exists(select 1 from jsonb_array_elements(p_data->'deductionRules') r group by r->>'id' having count(*)>1) then raise exception 'Invalid deduction rules';end if;
 if exists(select 1 from jsonb_array_elements(p_data->'criteria') c where (c ? 'allow_repeat' and jsonb_typeof(c->'allow_repeat')<>'boolean') or (c ? 'max_per_day' and (coalesce(c->>'max_per_day','')!~'^[0-9]+$' or (c->>'max_per_day')::numeric not between 1 and 20))) then raise exception 'Invalid repeat settings';end if;
 if exists(select 1 from jsonb_array_elements(p_data->'evaluations') e where e ? 'occurrence' and (coalesce(e->>'occurrence','')!~'^[1-9][0-9]*$')) then raise exception 'Invalid occurrence';end if;
 if exists(select 1 from jsonb_array_elements(p_data->'evaluations') e group by e->>'child',e->>'criterion',e->>'date',coalesce((e->>'occurrence')::integer,1) having count(*)>1) then raise exception 'Duplicate daily evaluation'; end if;
 if exists(select 1 from jsonb_array_elements(p_data->'attempts') e group by e->>'child',e->>'quiz',e->>'date' having count(*)>1) then raise exception 'Duplicate quiz attempt'; end if;
 if exists(select 1 from (select e from jsonb_array_elements(p_data->'evaluations') e union all select e from jsonb_array_elements(p_data->'attempts') e) t where (e->>'points')::numeric < 0) then raise exception 'Invalid points'; end if;
 if exists(select 1 from jsonb_array_elements(p_data->'redemptions') r where (r->>'cost')::numeric<=0) then raise exception 'Invalid redemption'; end if;
 if exists(select 1 from jsonb_array_elements(p_data->'children') c where
 coalesce((select sum((e->>'points')::numeric) from (select e from jsonb_array_elements(p_data->'evaluations') e union all select e from jsonb_array_elements(p_data->'attempts') e union all select e from jsonb_array_elements(p_data->'adjustments') e) t where e->>'child'=c->>'id'),0)
 < coalesce((select sum((r->>'cost')::numeric) from jsonb_array_elements(p_data->'redemptions') r where r->>'child'=c->>'id'),0)) then raise exception 'Insufficient balance'; end if;
 if exists(select 1 from public.family_members m where m.owner_id=actor and m.role='child' and not exists(select 1 from jsonb_array_elements(p_data->'children') c where c->>'id'=m.child_id)) then raise exception 'Cannot remove child linked to account'; end if;
 select revision into current_revision from public.family_state where owner_id=actor for update;
 if not found then
  if p_revision<>0 then raise sqlstate 'PT409' using message='Revision conflict'; end if;
  begin
   insert into public.family_state(owner_id,data,revision) values(actor,p_data,1);
  exception when unique_violation then raise sqlstate 'PT409' using message='Revision conflict'; end;
  perform public.log_family_event(actor,'إنشاء بيانات الأسرة',null,'');
  return 1;
 end if;
 if current_revision<>p_revision then raise sqlstate 'PT409' using message='Revision conflict'; end if;
 update public.family_state set data=p_data,revision=revision+1,updated_at=now() where owner_id=actor;
 perform public.log_family_event(actor,'تعديل بيانات الأسرة',null,'');
 return current_revision+1;
end $$;

revoke all on function public.save_family(jsonb,bigint) from public,anon;
grant execute on function public.save_family(jsonb,bigint) to authenticated;
create or replace function public.cleanup_trial(p_child text,p_keys text[],p_reason text,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;k text;prefix text;removed jsonb;kept jsonb;snapshot jsonb:='{}';amount_available numeric;reqs jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent' and user_id=owner_id;if not found then raise exception 'Admin only' using errcode='42501';end if;
 if p_keys is null or cardinality(p_keys) not between 1 and 500 or p_reason is null or length(trim(p_reason)) not between 1 and 300 then raise exception 'Invalid cleanup';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 foreach k in array array['evaluations','adjustments','attempts','redemptions'] loop
  prefix:=case k when 'evaluations' then 'e' when 'adjustments' then 'a' when 'attempts' then 'q' else 'r' end;
  select coalesce(jsonb_agg(e) filter(where e->>'child'=p_child and (case when k='evaluations' then 'e|'||(e->>'criterion')||'|'||(e->>'date')||case when coalesce((e->>'occurrence')::integer,1)>1 then '|'||(e->>'occurrence') else '' end else prefix||'|'||(e->>'id') end)=any(p_keys)),'[]'),coalesce(jsonb_agg(e) filter(where not(e->>'child'=p_child and coalesce((case when k='evaluations' then 'e|'||(e->>'criterion')||'|'||(e->>'date')||case when coalesce((e->>'occurrence')::integer,1)>1 then '|'||(e->>'occurrence') else '' end else prefix||'|'||(e->>'id') end)=any(p_keys),false))),'[]') into removed,kept from jsonb_array_elements(coalesce(d->k,'[]')) e;
  snapshot:=snapshot||jsonb_build_object(k,removed);d:=jsonb_set(d,array[k],kept);
 end loop;
 select coalesce(sum((e->>'points')::numeric),0) into amount_available from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e union all select e from jsonb_array_elements(d->'adjustments') e) t where e->>'child'=p_child;
 if amount_available<coalesce((select sum((r->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') r where r->>'child'=p_child),0) then raise exception 'Reset would reduce spent points';end if;
 select coalesce(jsonb_agg(to_jsonb(r)),'[]') into reqs from public.point_requests r where owner_id=m.owner_id and child_id=p_child and ('e|'||criterion_id||'|'||day::text||case when occurrence>1 then '|'||occurrence::text else '' end)=any(p_keys);
 delete from public.point_requests where owner_id=m.owner_id and child_id=p_child and ('e|'||criterion_id||'|'||day::text||case when occurrence>1 then '|'||occurrence::text else '' end)=any(p_keys);
 snapshot:=snapshot||jsonb_build_object('requests',reqs);
 d:=jsonb_set(d,'{resetArchive}',coalesce(d->'resetArchive','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',p_child,'date',(now() at time zone 'Asia/Amman')::date::text,'note',p_reason,'records',snapshot)));
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تنظيف سجلات تجربة',p_child,p_reason);
end $$;
revoke all on function public.cleanup_trial(text,text[],text,bigint) from public,anon;grant execute on function public.cleanup_trial(text,text[],text,bigint) to authenticated;
-- Reject account creation by an old Edge Function that does not identify the verified primary admin.
alter table public.family_members add column if not exists created_by uuid;
create or replace function public.is_game_attempt(e jsonb) returns boolean language sql immutable set search_path='' as $$
 select coalesce(e->>'kind','')='game' or coalesce(e->>'quiz','') ~ '^game_(memory|space)_' or (not(e ? 'kind') and coalesce(e->>'name','') ~ '^(ذاكرة الصور|مهمة الفضاء).*مرحلة.*صعوبة')
$$;
revoke all on function public.is_game_attempt(jsonb) from public,anon,authenticated;

create or replace function public.reset_game_points(p_player text,p_reason text,p_revision bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;removed jsonb;kept jsonb;entries jsonb;c jsonb;child text;available numeric;spent numeric;affected integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';
 if not found or not public.has_family_permission(m.owner_id,'reset_points') then raise exception 'Permission not granted' using errcode='42501';end if;
 if p_reason is null or length(trim(p_reason)) not between 1 and 300 then raise exception 'Invalid reason';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 if p_player is not null and not exists(select 1 from jsonb_array_elements(public.game_roster(m.owner_id)) r where r->>'id'=p_player) then raise exception 'Unknown player';end if;
 select coalesce(jsonb_agg(e) filter(where public.is_game_attempt(e) and (p_player is null or e->>'child'=p_player)),'[]'),
 coalesce(jsonb_agg(e) filter(where not(public.is_game_attempt(e) and (p_player is null or e->>'child'=p_player))),'[]') into removed,kept from jsonb_array_elements(d->'attempts') e;
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
create or replace function public.game_overview() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg jsonb;roster jsonb;rooms jsonb;progress jsonb;requests jsonb;legacy jsonb;v_day date:=(now() at time zone 'Asia/Amman')::date;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('daily_cap',daily_cap,'max_difficulty',max_difficulty,'enabled',enabled) into cfg from public.family_game_settings where owner_id=m.owner_id;
 select coalesce(jsonb_agg(c),'[]') into roster from jsonb_array_elements(public.game_roster(m.owner_id)) c where m.role='parent' or c->>'id'=m.child_id;
 select coalesce(jsonb_agg(r order by r->>'created_at' desc),'[]') into rooms from(select jsonb_build_object('id',id,'game',game,'difficulty',difficulty,'stage',stage,'status',status,'created_at',created_at) r from public.family_game_sessions where owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) order by created_at desc limit 15) x;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',last_day,'points',points,'total_points',total_points,'daily_used',daily_used)),'[]') into progress from(select child_id,game,difficulty,stage,max(day) as last_day,coalesce(sum(points) filter(where reset_at is null and approval_status='approved'),0) total_points,coalesce(sum(points) filter(where day=v_day and reset_at is null and approval_status='approved'),0) points,coalesce(sum(points) filter(where day=v_day),0) daily_used from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) group by child_id,game,difficulty,stage) compact;
 select coalesce(jsonb_agg(r),'[]') into requests from(select jsonb_build_object('id',id,'child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',day,'points',points,'status',approval_status,'note',review_note,'reset',reset_at is not null) r from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) order by (approval_status='pending' and reset_at is null) desc,created_at desc limit 200) q;
 select coalesce(jsonb_agg(e),'[]') into legacy from public.family_state f,jsonb_array_elements(f.data->'attempts') e where f.owner_id=m.owner_id and public.is_game_attempt(e) and (m.role='parent' or e->>'child'=m.child_id) and not exists(select 1 from public.family_game_completions g where g.owner_id=m.owner_id and g.id::text=e->>'id');
 return jsonb_build_object('settings',coalesce(cfg,'{"daily_cap":20,"max_difficulty":3,"enabled":true}'::jsonb),'can_reset',public.has_family_permission(m.owner_id,'reset_points'),'revision',(select revision from public.family_state where owner_id=m.owner_id),'legacy_attempts',legacy,'requests',requests,'children',roster,'sessions',rooms,'progress',progress,'day',v_day);
end $$;
revoke all on function public.game_overview() from public,anon;grant execute on function public.game_overview() to authenticated;
create or replace function public.criterion_to_deduction(p_criterion text,p_name text,p_description text,p_points integer,p_archive boolean,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;c jsonb;rev bigint;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_name is null or length(trim(p_name)) not between 1 and 100 or p_description is null or length(p_description)>300 or p_points is null or p_points not between 1 and 1000 or p_archive is null then raise exception 'Invalid deduction';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 select value into c from jsonb_array_elements(d->'criteria') where value->>'id'=p_criterion and not coalesce((value->>'archived')::boolean,false);if not found then raise exception 'Unknown criterion';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(d->'deductionRules','[]')) r where r->>'source_criterion'=p_criterion and not coalesce((r->>'archived')::boolean,false)) then raise exception 'Criterion already linked to deduction';end if;
 d:=jsonb_set(d,'{deductionRules}',coalesce(d->'deductionRules','[]')||jsonb_build_array(jsonb_build_object('id',replace(gen_random_uuid()::text,'-',''),'name',trim(p_name),'description',p_description,'points',p_points,'source_criterion',p_criterion)));
 if p_archive then
  d:=jsonb_set(d,'{criteria}',(select jsonb_agg(case when x->>'id'=p_criterion then x||'{"archived":true}'::jsonb else x end) from jsonb_array_elements(d->'criteria') x));
  update public.point_requests set status='rejected',review_note='تم تحويل المعيار إلى بند خصم',reviewed_at=now() where owner_id=m.owner_id and criterion_id=p_criterion and status='pending';
 end if;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تحويل معيار إلى بند خصم',null,trim(p_name)||' — '||p_points||' نقطة، دون خصم تلقائي');
end $$;
revoke all on function public.criterion_to_deduction(text,text,text,integer,boolean,bigint) from public,anon;
grant execute on function public.criterion_to_deduction(text,text,text,integer,boolean,bigint) to authenticated;

notify pgrst,'reload schema';
commit;
