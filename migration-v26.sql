-- السماح للخصومات المعتمدة بإنشاء رصيد سالب مع بقاء التحقق من الصلاحيات.
begin;
create or replace function public.manage_points(p_child text,p_action text,p_criterion text,p_amount integer,p_reason text,p_revision bigint) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb; rev bigint; amount_available numeric; k text; archived jsonb:='{}'; removed jsonb; kept jsonb; req_archive jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';
 if not found then raise exception 'Parent account required' using errcode='42501'; end if;
 if p_action is null or p_action not in ('deduct','reset') or p_reason is null or length(trim(p_reason))<1 or length(p_reason)>300 then raise exception 'Invalid operation'; end if;
 if not public.has_family_permission(m.owner_id,case when p_action='reset' then 'reset_points' else 'deduct_points' end) then raise exception 'Permission not granted' using errcode='42501';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict'; end if;
 if not exists(select 1 from jsonb_array_elements(d->'children') c where c->>'id'=p_child) then raise exception 'Unknown child'; end if;
 if p_criterion is not null and not exists(select 1 from jsonb_array_elements(d->'criteria') c where c->>'id'=p_criterion) then raise exception 'Unknown criterion'; end if;
 d:=d||jsonb_build_object('adjustments',coalesce(d->'adjustments','[]'),'resetArchive',coalesce(d->'resetArchive','[]'));
 if p_action='deduct' then
  if p_amount is null or p_amount<1 or p_amount>1000 then raise exception 'Invalid deduction'; end if;
  select coalesce(sum((e->>'points')::numeric),0) into amount_available from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e union all select e from jsonb_array_elements(d->'adjustments') e) t where e->>'child'=p_child;
  amount_available:=amount_available-coalesce((select sum((r->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') r where r->>'child'=p_child),0);
  -- الخصم مسموح حتى عند عدم كفاية الرصيد.
  d:=jsonb_set(d,'{adjustments}',(d->'adjustments')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',p_child,'criterion',p_criterion,'points',-p_amount,'name','خصم نقاط','note',trim(p_reason),'date',(now() at time zone 'Asia/Amman')::date::text)));
 else
  foreach k in array array['evaluations','attempts','redemptions','adjustments'] loop
   select coalesce(jsonb_agg(e) filter(where e->>'child'=p_child and (p_criterion is null or (k in ('evaluations','adjustments') and e->>'criterion'=p_criterion))),'[]'),coalesce(jsonb_agg(e) filter(where not(e->>'child'=p_child and (p_criterion is null or (k in ('evaluations','adjustments') and coalesce(e->>'criterion','')=p_criterion)))),'[]') into removed,kept from jsonb_array_elements(d->k) e;
   archived:=archived||jsonb_build_object(k,removed); d:=jsonb_set(d,array[k],kept);
  end loop;
  select coalesce(sum((e->>'points')::numeric),0) into amount_available from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e union all select e from jsonb_array_elements(d->'adjustments') e) t where e->>'child'=p_child;
  if amount_available<coalesce((select sum((r->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') r where r->>'child'=p_child),0) then raise exception 'Reset would reduce spent points'; end if;
  select coalesce(jsonb_agg(to_jsonb(r)),'[]') into req_archive from public.point_requests r where owner_id=m.owner_id and child_id=p_child and (p_criterion is null or criterion_id=p_criterion);
  archived:=archived||jsonb_build_object('requests',req_archive);
  d:=jsonb_set(d,'{resetArchive}',(d->'resetArchive')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',p_child,'criterion',p_criterion,'date',(now() at time zone 'Asia/Amman')::date::text,'note',trim(p_reason),'records',archived)));
  delete from public.point_requests where owner_id=m.owner_id and child_id=p_child and (p_criterion is null or criterion_id=p_criterion);
 end if;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large'; end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,case when p_action='deduct' then 'خصم نقاط' else 'تصفير نقاط' end,p_child,p_reason);
end $$;
revoke all on function public.manage_points(text,text,text,integer,text,bigint) from public,anon;
grant execute on function public.manage_points(text,text,text,integer,text,bigint) to authenticated;

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
 coalesce((select sum((e->>'points')::numeric) from (select e from jsonb_array_elements(p_data->'evaluations') e union all select e from jsonb_array_elements(p_data->'attempts') e) t where e->>'child'=c->>'id'),0)
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
notify pgrst,'reload schema';
commit;
