-- تفويض صلاحيات النقاط لولي الأمر الثاني. شغّل بعد v5.
begin;
alter table public.family_members add column if not exists permissions text[] not null default '{}';
create or replace function public.has_family_permission(p_owner uuid,p_permission text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.family_members where user_id=auth.uid() and owner_id=p_owner and active and role='parent' and (user_id=owner_id or (p_permission in ('reset_points','deduct_points') and p_permission=any(permissions))))
$$;
revoke all on function public.has_family_permission(uuid,text) from public,anon;
grant execute on function public.has_family_permission(uuid,text) to authenticated;
-- Changing a role never carries previously delegated rights into the new role.
create or replace function public.normalize_member_permissions() returns trigger language plpgsql set search_path='' as $$
begin
 if new.role<>'parent' or new.user_id=new.owner_id then new.permissions:='{}';
 elsif TG_OP='UPDATE' then if old.role is distinct from new.role then new.permissions:='{}';end if;end if;
 if new.permissions is null or not(new.permissions <@ array['reset_points','deduct_points']::text[]) then raise exception 'Invalid permissions';end if;
 return new;
end $$;
revoke all on function public.normalize_member_permissions() from public,anon,authenticated;
drop trigger if exists member_permission_normalize on public.family_members;
create trigger member_permission_normalize before insert or update on public.family_members for each row execute function public.normalize_member_permissions();
create or replace function public.set_parent_permissions(p_user uuid,p_permissions text[]) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;t public.family_members;chosen text[];
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent' and user_id=owner_id;
 if not found then raise exception 'Primary admin only' using errcode='42501';end if;
 if p_permissions is null or cardinality(p_permissions)>2 or exists(select 1 from unnest(p_permissions) p where p is null or p not in ('reset_points','deduct_points')) then raise exception 'Invalid permissions';end if;
 select * into t from public.family_members where user_id=p_user and owner_id=m.owner_id and role='parent' and user_id<>owner_id for update;
 if not found then raise exception 'Secondary parent from your family required' using errcode='42501';end if;
 select coalesce(array_agg(distinct p order by p),'{}'::text[]) into chosen from unnest(p_permissions) p;
 update public.family_members set permissions=chosen where user_id=t.user_id;
 perform public.log_family_event(m.owner_id,'تعديل صلاحيات ولي الأمر',null,t.display_name||' — تصفير: '||case when 'reset_points'=any(chosen) then 'نعم' else 'لا' end||'، خصم: '||case when 'deduct_points'=any(chosen) then 'نعم' else 'لا' end);
end $$;
revoke all on function public.set_parent_permissions(uuid,text[]) from public,anon;
grant execute on function public.set_parent_permissions(uuid,text[]) to authenticated;

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
  if amount_available<p_amount then raise exception 'Insufficient balance'; end if;
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

commit;
