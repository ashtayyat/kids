-- قوائم المكافآت وبنود الخصم. شغّل بعد v10.
begin;
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
  if exists(select 1 from jsonb_array_elements(existing_data->'evaluations') old where not exists(select 1 from jsonb_array_elements(p_data->'evaluations') new where new->>'child'=old->>'child' and new->>'criterion'=old->>'criterion' and new->>'date'=old->>'date')) then raise exception 'Use delegated reset operation' using errcode='42501';end if;
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

create or replace function public.archive_catalog_item(p_kind text,p_id text,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;r jsonb;rev bigint;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_kind is null or p_kind not in ('rewards','deductionRules') then raise exception 'Invalid catalog';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 select entry into r from jsonb_array_elements(coalesce(d->p_kind,'[]')) entry where entry->>'id'=p_id and not coalesce((entry->>'archived')::boolean,false);
 if not found then raise exception 'Unknown item';end if;
 d:=jsonb_set(d,array[p_kind],(select jsonb_agg(case when entry->>'id'=p_id then entry||jsonb_build_object('archived',true) else entry end) from jsonb_array_elements(d->p_kind) entry));
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,case when p_kind='rewards' then 'حذف مكافأة' else 'حذف بند خصم' end,null,r->>'name');
end $$;
revoke all on function public.archive_catalog_item(text,text,bigint) from public,anon;grant execute on function public.archive_catalog_item(text,text,bigint) to authenticated;

create or replace function public.apply_deduction_rule(p_child text,p_rule text,p_note text,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;r jsonb;rev bigint;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';
 if not found or not public.has_family_permission(m.owner_id,'deduct_points') then raise exception 'Deduction permission required' using errcode='42501';end if;
 if p_note is null or length(trim(p_note)) not between 1 and 180 then raise exception 'A note is required';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 select entry into r from jsonb_array_elements(coalesce(d->'deductionRules','[]')) entry where entry->>'id'=p_rule and not coalesce((entry->>'archived')::boolean,false);
 if not found then raise exception 'Unknown deduction rule';end if;
 perform public.manage_points(p_child,'deduct',null,(r->>'points')::integer,r->>'name'||' — '||trim(p_note),p_revision);
end $$;
revoke all on function public.apply_deduction_rule(text,text,text,bigint) from public,anon;grant execute on function public.apply_deduction_rule(text,text,text,bigint) to authenticated;

create or replace function public.redeem_reward(p_child text,p_reward text,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;r jsonb;rev bigint;available numeric;cost integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 if not exists(select 1 from jsonb_array_elements(d->'children') c where c->>'id'=p_child) then raise exception 'Unknown child';end if;
 select entry into r from jsonb_array_elements(d->'rewards') entry where entry->>'id'=p_reward and not coalesce((entry->>'archived')::boolean,false);if not found then raise exception 'Unknown reward';end if;
 cost:=(r->>'cost')::integer;if cost<1 then raise exception 'Invalid reward';end if;
 select coalesce(sum((e->>'points')::numeric),0) into available from (select value e from jsonb_array_elements(d->'evaluations') union all select value from jsonb_array_elements(d->'attempts') union all select value from jsonb_array_elements(coalesce(d->'adjustments','[]'))) ledger where e->>'child'=p_child;
 available:=available-coalesce((select sum((x->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') x where x->>'child'=p_child),0);if available<cost then raise exception 'Insufficient balance';end if;
 d:=jsonb_set(d,'{redemptions}',(d->'redemptions')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',p_child,'reward',p_reward,'name',r->>'name','cost',cost,'date',(now() at time zone 'Asia/Amman')::date::text)));
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'استبدال مكافأة',p_child,r->>'name');
end $$;
revoke all on function public.redeem_reward(text,text,bigint) from public,anon;grant execute on function public.redeem_reward(text,text,bigint) to authenticated;

commit;
