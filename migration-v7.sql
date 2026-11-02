-- إصلاح تعديل الاسم بصورة مستقلة عن دالة إنشاء المستخدمين. شغّل بعد v6.
begin;
create or replace function public.rename_family_member(p_user uuid,p_name text) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members;t public.family_members;d jsonb;new_name text;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent' and user_id=owner_id;
 if not found then raise exception 'Primary admin required' using errcode='42501';end if;
 new_name:=trim(p_name);
 if new_name is null or length(new_name) not between 1 and 80 then raise exception 'Invalid display name';end if;
 -- Lock the family first, matching the ledger operations; never overwrite a stale document.
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select * into t from public.family_members where user_id=p_user and owner_id=m.owner_id for update;
 if not found then raise exception 'Family member required' using errcode='42501';end if;
 update public.family_members set display_name=new_name where user_id=t.user_id;
 if t.role='child' and d is not null then
  d:=jsonb_set(d,'{children}',coalesce((select jsonb_agg(case when c->>'id'=t.child_id then jsonb_set(c,'{name}',to_jsonb(new_name)) else c end) from jsonb_array_elements(d->'children') c),'[]'));
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 perform public.log_family_event(m.owner_id,'تعديل اسم حساب',t.child_id,new_name);
end $$;
revoke all on function public.rename_family_member(uuid,text) from public,anon;
grant execute on function public.rename_family_member(uuid,text) to authenticated;
commit;
