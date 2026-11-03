-- إخفاء طلب الإنجاز المرفوض بعد التأكيد، مع حفظ النقاط المعتمدة والسجل الإداري.
begin;
alter table public.point_requests add column if not exists deleted_at timestamptz;
alter table public.point_requests add column if not exists deleted_by uuid;
drop policy if exists request_read on public.point_requests;
create policy request_read on public.point_requests for select to authenticated using(deleted_at is null and ((requester=auth.uid() and public.has_active_membership()) or public.is_family_parent(owner_id)));
create or replace function public.delete_rejected_point_request(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;r public.point_requests;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;
 if not found then raise exception 'Membership required' using errcode='42501';end if;
 perform 1 from public.family_state where owner_id=m.owner_id for update;
 select * into r from public.point_requests where id=p_id and owner_id=m.owner_id for update;
 if not found or (m.role='child' and (r.requester<>m.user_id or r.child_id<>m.child_id)) then raise exception 'Request access denied' using errcode='42501';end if;
 if r.deleted_at is not null or r.status<>'rejected' then raise sqlstate 'PT409' using message='Only rejected requests can be deleted';end if;
 update public.point_requests set deleted_at=now(),deleted_by=m.user_id where id=r.id;
 perform public.log_family_event(m.owner_id,'حذف طلب إنجاز مرفوض',r.child_id,r.criterion_id||' — '||r.day::text);
end $$;
revoke all on function public.delete_rejected_point_request(uuid) from public,anon;
grant execute on function public.delete_rejected_point_request(uuid) to authenticated;
create or replace function public.submit_point_request(p_criterion text,p_day date,p_level integer,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='child';
 if not found then raise exception 'Child account required' using errcode='42501'; end if;
 if p_day is null or p_day> (now() at time zone 'Asia/Amman')::date or p_level is null or p_level not between 0 and 2 or p_note is null or length(p_note)>300 then raise exception 'Invalid request'; end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 if not exists(select 1 from jsonb_array_elements(d->'criteria') c where c->>'id'=p_criterion and not coalesce((c->>'archived')::boolean,false) and (c->>'assigned_child' is null or c->>'assigned_child'=m.child_id)) then raise exception 'Unknown criterion'; end if;
 insert into public.point_requests(owner_id,requester,child_id,criterion_id,day,level,note)
 values(m.owner_id,m.user_id,m.child_id,p_criterion,p_day,p_level,p_note)
 on conflict(owner_id,child_id,criterion_id,day) do update set deleted_at=null,deleted_by=null,level=excluded.level,note=excluded.note,status='pending',review_note='',reviewed_at=null
 where point_requests.requester=excluded.requester;
 if not found then raise sqlstate 'PT409' using message='Already approved'; end if;
end $$;
revoke all on function public.submit_point_request(text,date,integer,text) from public,anon;
grant execute on function public.submit_point_request(text,date,integer,text) to authenticated;
create or replace function public.submit_point_request_with_evidence(p_criterion text,p_day date,p_level integer,p_note text,p_evidence text) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='child';
 if not found then raise exception 'Child account required' using errcode='42501'; end if;
 if p_day is null or p_day> (now() at time zone 'Asia/Amman')::date or p_level is null or p_level not between 0 and 2 or p_note is null or length(p_note)>300 then raise exception 'Invalid request'; end if;
 if p_evidence is not null and (length(p_evidence)>100000 or p_evidence !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$') then raise exception 'Invalid evidence';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 if not exists(select 1 from jsonb_array_elements(d->'criteria') c where c->>'id'=p_criterion and not coalesce((c->>'archived')::boolean,false) and (c->>'assigned_child' is null or c->>'assigned_child'=m.child_id)) then raise exception 'Unknown criterion'; end if;
 insert into public.point_requests(owner_id,requester,child_id,criterion_id,day,level,note,evidence)
 values(m.owner_id,m.user_id,m.child_id,p_criterion,p_day,p_level,p_note,p_evidence)
 on conflict(owner_id,child_id,criterion_id,day) do update set deleted_at=null,deleted_by=null,level=excluded.level,note=excluded.note,evidence=excluded.evidence,status='pending',review_note='',reviewed_at=null
 where point_requests.requester=excluded.requester;
 if not found then raise sqlstate 'PT409' using message='Already approved'; end if;
end $$;
revoke all on function public.submit_point_request_with_evidence(text,date,integer,text,text) from public,anon;
grant execute on function public.submit_point_request_with_evidence(text,date,integer,text,text) to authenticated;
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
  row_data:=jsonb_build_object('child',r.child_id,'criterion',r.criterion_id,'date',r.day::text,'level',p_level,'points',(c->'points'->>p_level)::integer,'note',r.note,'request_id',r.id,'evidence',r.evidence);
  d:=jsonb_set(d,'{evaluations}',coalesce((select jsonb_agg(e) from jsonb_array_elements(d->'evaluations') e where not(e->>'child'=r.child_id and e->>'criterion'=r.criterion_id and e->>'date'=r.day::text)),'[]')||jsonb_build_array(row_data));
  if coalesce((select sum((e->>'points')::numeric) from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e union all select e from jsonb_array_elements(coalesce(d->'adjustments','[]')) e) t where e->>'child'=r.child_id),0)<coalesce((select sum((x->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') x where x->>'child'=r.child_id),0) then raise exception 'Cannot reduce spent points'; end if;
  if length(trim(p_note))>0 then d:=jsonb_set(d,'{encouragements}',coalesce(d->'encouragements','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',r.child_id,'note',trim(p_note),'date',(now() at time zone 'Asia/Amman')::date::text,'request_id',r.id)));end if;
  if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 update public.point_requests set status=case when p_approve then 'approved' else 'rejected' end,review_note=p_note,reviewed_at=now() where id=r.id;
 perform public.log_family_event(m.owner_id,case when p_approve then 'اعتماد إنجاز' else 'إعادة إنجاز للمراجعة' end,r.child_id,p_note);
end $$;
revoke all on function public.review_point_request(uuid,boolean,integer,text) from public,anon;
grant execute on function public.review_point_request(uuid,boolean,integer,text) to authenticated;
notify pgrst,'reload schema';
commit;
