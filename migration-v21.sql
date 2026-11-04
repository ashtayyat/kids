-- مواعيد إرسال الإنجازات والتحكم بها وإدارة النقاط السريعة.
begin;
create or replace function public.submit_achievement(p_criterion text,p_day date,p_level integer,p_note text,p_evidence text,p_request uuid) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;c jsonb;r public.point_requests;used integer;max_count integer;slot integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='child';if not found then raise exception 'Child account required' using errcode='42501';end if;
 if p_day is null or p_day>(now() at time zone 'Asia/Amman')::date or p_level is null or p_level not between 0 and 2 or p_note is null or length(p_note)>300 then raise exception 'Invalid request';end if;
 if p_evidence is not null and (length(p_evidence)>100000 or p_evidence !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$') then raise exception 'Invalid evidence';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select value into c from jsonb_array_elements(d->'criteria') where value->>'id'=p_criterion and not coalesce((value->>'archived')::boolean,false) and (value->>'assigned_child' is null or value->>'assigned_child'=m.child_id);if not found then raise exception 'Unknown criterion';end if;
 if coalesce(c->'blocked_children','[]'::jsonb) ? m.child_id then raise exception 'Achievement blocked for child' using errcode='42501';end if;
 if coalesce(d->'submissionSettings'->>'cutoff','')<>'' and (clock_timestamp() at time zone 'Asia/Amman')::time >= (d->'submissionSettings'->>'cutoff')::time then raise exception 'Achievement submission time ended' using errcode='42501';end if;
 if coalesce(c->>'submission_cutoff','')<>'' and (clock_timestamp() at time zone 'Asia/Amman')::time >= (c->>'submission_cutoff')::time then raise exception 'Achievement submission time ended' using errcode='42501';end if;
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
create or replace function public.set_submission_control(p_criterion text,p_cutoff text,p_blocked text[],p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;c jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent account required' using errcode='42501';end if;
 if p_cutoff is null or (p_cutoff<>'' and p_cutoff!~'^([01][0-9]|2[0-3]):[0-5][0-9]$') or p_blocked is null or cardinality(p_blocked)>100 then raise exception 'Invalid submission settings';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 if exists(select 1 from unnest(p_blocked) id where not exists(select 1 from jsonb_array_elements(d->'children') x where x->>'id'=id)) then raise exception 'Unknown child';end if;
 if p_criterion is null then d:=jsonb_set(d,'{submissionSettings}',jsonb_build_object('cutoff',p_cutoff));
 else
  select value into c from jsonb_array_elements(d->'criteria') where value->>'id'=p_criterion and not coalesce((value->>'archived')::boolean,false);if c is null then raise exception 'Unknown criterion';end if;
  d:=jsonb_set(d,'{criteria}',(select jsonb_agg(case when x->>'id'=p_criterion then x||jsonb_build_object('submission_cutoff',p_cutoff,'blocked_children',to_jsonb(p_blocked)) else x end) from jsonb_array_elements(d->'criteria') x));
 end if;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تعديل وقت وصلاحية إرسال الإنجاز',null,coalesce(p_criterion,'جميع المعايير')||' · '||p_cutoff);
end $$;
revoke all on function public.set_submission_control(text,text,text[],bigint) from public,anon;
grant execute on function public.set_submission_control(text,text,text[],bigint) to authenticated;
create or replace function public.quick_points(p_child text,p_action text,p_criterion text,p_amount integer,p_reason text,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;entry_id text;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent account required' using errcode='42501';end if;
 if p_action is null or p_action not in('add','deduct','reset') or p_reason is null or length(trim(p_reason)) not between 1 and 300 then raise exception 'Invalid operation';end if;
 if p_action<>'add' then
  perform public.manage_points(p_child,p_action,p_criterion,p_amount,p_reason,p_revision);
  if p_action='reset' and p_criterion is null then
   update public.reward_requests set status='rejected',review_note='أُلغي الطلب عند تصفير النقاط',reviewed_at=now() where owner_id=m.owner_id and child_id=p_child and status='pending';
   update public.family_game_completions set reset_at=now(),approval_status=case when approval_status='pending' then 'rejected' else approval_status end where owner_id=m.owner_id and child_id=p_child and reset_at is null;
  end if;
  return;
 end if;
 if p_amount is null or p_amount not between 1 and 1000 then raise exception 'Invalid points';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 if not exists(select 1 from jsonb_array_elements(d->'children') x where x->>'id'=p_child) then raise exception 'Unknown child';end if;
 if p_criterion is not null and not exists(select 1 from jsonb_array_elements(d->'criteria') x where x->>'id'=p_criterion) then raise exception 'Unknown criterion';end if;
 entry_id:=gen_random_uuid()::text;
 d:=jsonb_set(d,'{attempts}',(d->'attempts')||jsonb_build_array(jsonb_build_object('id',entry_id,'quiz','bonus_'||entry_id,'kind','bonus','child',p_child,'criterion',p_criterion,'name','نقاط تشجيعية','points',p_amount,'correct',0,'total',0,'note',trim(p_reason),'date',(now() at time zone 'Asia/Amman')::date::text)));
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'إضافة نقاط تشجيعية',p_child,p_amount::text||' · '||trim(p_reason));
end $$;
revoke all on function public.quick_points(text,text,text,integer,text,bigint) from public,anon;
grant execute on function public.quick_points(text,text,text,integer,text,bigint) to authenticated;
notify pgrst,'reload schema';
commit;
