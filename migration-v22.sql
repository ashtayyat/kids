-- مؤقت مطلق بالدقائق يستمر بين الأجهزة.
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
 if coalesce(d->'submissionSettings'->>'expires_at','')<>'' and clock_timestamp()>=(d->'submissionSettings'->>'expires_at')::timestamptz then raise exception 'Achievement submission time ended' using errcode='42501';end if;
 if coalesce(c->>'submission_expires_at','')<>'' and clock_timestamp()>=(c->>'submission_expires_at')::timestamptz then raise exception 'Achievement submission time ended' using errcode='42501';end if;
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
create or replace function public.set_submission_timer(p_criterion text,p_minutes integer,p_action text,p_revision bigint) returns timestamptz language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;expiry timestamptz;timer jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent account required' using errcode='42501';end if;
 if p_action is null or p_action not in('start','stop','clear') or p_minutes is null or p_minutes not between 1 and 1440 then raise exception 'Invalid timer';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 expiry:=case when p_action='start' then clock_timestamp()+make_interval(mins=>p_minutes) when p_action='stop' then clock_timestamp() else null end;
 timer:=jsonb_build_object('expires_at',expiry,'minutes',p_minutes);
 if p_criterion is null then d:=jsonb_set(d,'{submissionSettings}',timer);
 else
  if not exists(select 1 from jsonb_array_elements(d->'criteria') c where c->>'id'=p_criterion and not coalesce((c->>'archived')::boolean,false)) then raise exception 'Unknown criterion';end if;
  d:=jsonb_set(d,'{criteria}',(select jsonb_agg(case when c->>'id'=p_criterion then (c-'submission_cutoff')||jsonb_build_object('submission_expires_at',expiry,'timer_minutes',p_minutes) else c end) from jsonb_array_elements(d->'criteria') c));
 end if;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تعديل مؤقت الإنجازات',null,coalesce(p_criterion,'جميع المعايير')||' · '||p_action||' · '||p_minutes::text);
 return expiry;
end $$;
revoke all on function public.set_submission_timer(text,integer,text,bigint) from public,anon;
grant execute on function public.set_submission_timer(text,integer,text,bigint) to authenticated;
notify pgrst,'reload schema';
commit;
