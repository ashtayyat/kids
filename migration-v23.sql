-- اعتماد دفعة محددة من إنجازات طفل واحد، كوحدة ذرية.
begin;
create or replace function public.approve_child_achievements(p_child text,p_ids uuid[],p_note text) returns integer language plpgsql security definer set search_path='' as $$
declare m public.family_members;r public.point_requests;n integer:=0;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent account required' using errcode='42501';end if;
 if p_ids is null or cardinality(p_ids) not between 1 and 200 or p_note is null or length(p_note)>300 or (select count(distinct id) from unnest(p_ids) id)<>cardinality(p_ids) then raise exception 'Invalid batch';end if;
 perform 1 from public.family_state where owner_id=m.owner_id for update;
 if (select count(*) from public.point_requests where id=any(p_ids) and owner_id=m.owner_id and child_id=p_child and status='pending' and deleted_at is null)<>cardinality(p_ids) then raise sqlstate 'PT409' using message='Batch request changed';end if;
 for r in select * from public.point_requests where id=any(p_ids) and owner_id=m.owner_id and child_id=p_child order by created_at,id for update loop
  perform public.review_point_request(r.id,true,r.level,p_note);n:=n+1;
 end loop;
 return n;
end $$;
revoke all on function public.approve_child_achievements(text,uuid[],text) from public,anon;
grant execute on function public.approve_child_achievements(text,uuid[],text) to authenticated;
notify pgrst,'reload schema';
commit;
