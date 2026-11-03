-- العمل اليومي مشترك بين وليي الأمر. شغّل بعد v7.
begin;
create or replace function public.save_family(p_data jsonb,p_revision bigint) returns bigint
language plpgsql security definer set search_path='' as $$
declare actor uuid; current_revision bigint; k text; existing_data jsonb; merged jsonb; main_parent boolean;
begin
 select owner_id into actor from public.family_members where user_id=auth.uid() and active and role='parent';
 if actor is null then raise exception 'Authentication required' using errcode='42501'; end if;
 main_parent:=public.is_family_admin(actor);
 if not main_parent then
  select data,revision into existing_data,current_revision from public.family_state where owner_id=actor for update;
  if existing_data is null then raise exception 'Initialize family first';end if;
  if current_revision is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
  if coalesce(p_data->'adjustments','[]') is distinct from coalesce(existing_data->'adjustments','[]') or (p_data ? 'resetArchive' and p_data->'resetArchive' is distinct from coalesce(existing_data->'resetArchive','[]')) then raise exception 'Use delegated points operation' using errcode='42501';end if;
  if exists(select 1 from jsonb_array_elements(existing_data->'children') old where not exists(select 1 from jsonb_array_elements(p_data->'children') new where new->>'id'=old->>'id')) then raise exception 'Child deletion is administrative' using errcode='42501';end if;
  if exists(select 1 from jsonb_array_elements(existing_data->'evaluations') old where not exists(select 1 from jsonb_array_elements(p_data->'evaluations') new where new->>'child'=old->>'child' and new->>'criterion'=old->>'criterion' and new->>'date'=old->>'date')) then raise exception 'Use delegated reset operation' using errcode='42501';end if;
  foreach k in array array['attempts','redemptions'] loop
   if exists(select 1 from jsonb_array_elements(existing_data->k) old where not exists(select 1 from jsonb_array_elements(p_data->k) new where new=old)) then raise exception 'Existing ledger entry is protected' using errcode='42501';end if;
  end loop;
  merged:=existing_data;
  foreach k in array array['children','criteria','evaluations','rewards','redemptions','quizzes','attempts'] loop
   if jsonb_typeof(p_data->k) is distinct from 'array' then raise exception 'Invalid collection';end if;
   merged:=jsonb_set(merged,array[k],p_data->k);
  end loop;
  p_data:=merged;
 end if;

 p_data:=p_data||jsonb_build_object('adjustments',coalesce(p_data->'adjustments','[]'),'resetArchive',coalesce(p_data->'resetArchive','[]'));
 if jsonb_typeof(p_data->'adjustments') is distinct from 'array' or jsonb_typeof(p_data->'resetArchive') is distinct from 'array' then raise exception 'Invalid ledger'; end if;
 if exists(select 1 from jsonb_array_elements(p_data->'adjustments') a where (a->>'points')::numeric>=0 or (a->>'points')::numeric<>trunc((a->>'points')::numeric) or not exists(select 1 from jsonb_array_elements(p_data->'children') c where c->>'id'=a->>'child')) then raise exception 'Invalid deduction'; end if;
 if p_data->>'version' is distinct from '1' or octet_length(p_data::text)>2000000 then raise exception 'Invalid data'; end if;
 foreach k in array array['children','criteria','evaluations','rewards','redemptions','quizzes','attempts'] loop
  if jsonb_typeof(p_data->k) is distinct from 'array' then raise exception 'Invalid collection'; end if;
 end loop;
 if exists(select 1 from jsonb_array_elements(p_data->'evaluations') e group by e->>'child',e->>'criterion',e->>'date' having count(*)>1) then raise exception 'Duplicate daily evaluation'; end if;
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

create or replace function public.review_suggestion(p_id uuid,p_approve boolean,p_amount integer,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_suggestions;d jsonb;rev bigint;newid text;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Admin only' using errcode='42501';end if;
 if p_approve is null or p_amount is null or p_amount not between 0 and 10000 or p_note is null or length(p_note)>300 then raise exception 'Invalid review';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 select * into s from public.family_suggestions where id=p_id and owner_id=m.owner_id for update;if not found or s.status<>'pending' then raise sqlstate 'PT409' using message='Request already reviewed';end if;
 if s.kind='deduction' and not public.has_family_permission(m.owner_id,'deduct_points') then raise exception 'Deduction permission required' using errcode='42501';end if;
 if p_approve then
  newid:=replace(gen_random_uuid()::text,'-','');
  if s.kind='reward' then
   if p_amount<1 then raise exception 'Cost required';end if;
   d:=jsonb_set(d,'{rewards}',(d->'rewards')||jsonb_build_array(jsonb_build_object('id',newid,'name',s.title,'description',s.description,'cost',p_amount,'suggested_by',s.child_id)));
  elsif s.kind='task' then
   if p_amount>1000 then raise exception 'Points limit';end if;
   d:=jsonb_set(d,'{criteria}',(d->'criteria')||jsonb_build_array(jsonb_build_object('id','bonus_'||newid,'name',s.title,'points',jsonb_build_array(0,p_amount/2,p_amount),'assigned_child',s.child_id)));
  elsif s.kind='deduction' then
   perform public.manage_points(s.child_id,'deduct',null,p_amount,s.title||': '||s.description,rev);
   select data into d from public.family_state where owner_id=m.owner_id;
  end if;
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 update public.family_suggestions set status=case when p_approve then 'approved' else 'rejected' end,review_note=p_note,amount=p_amount where id=s.id;
 perform public.log_family_event(m.owner_id,case when p_approve then 'اعتماد اقتراح' else 'إعادة اقتراح' end,s.child_id,s.title||' — '||p_note);
end $$;
revoke all on function public.review_suggestion(uuid,boolean,integer,text) from public,anon;grant execute on function public.review_suggestion(uuid,boolean,integer,text) to authenticated;

commit;
