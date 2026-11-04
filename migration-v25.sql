-- قبول أو رفض دفعة من طلبات الألعاب أو الاستبدال.
begin;
create or replace function public.review_pending_batch(p_kind text,p_ids uuid[],p_approve boolean,p_note text) returns integer language plpgsql security definer set search_path='' as $$
declare m public.family_members;rid uuid;found_count integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent account required' using errcode='42501';end if;
 if p_kind is null or p_kind not in('game','reward') or p_approve is null or p_note is null or length(p_note)>300 or p_ids is null or cardinality(p_ids) not between 1 and 200 or (select count(distinct id) from unnest(p_ids) id)<>cardinality(p_ids) then raise exception 'Invalid batch';end if;
 perform 1 from public.family_state where owner_id=m.owner_id for update;
 if p_kind='reward' then select count(*) into found_count from public.reward_requests where owner_id=m.owner_id and id=any(p_ids) and status='pending';
 else select count(*) into found_count from public.family_game_completions where owner_id=m.owner_id and id=any(p_ids) and approval_status='pending' and reset_at is null;end if;
 if found_count<>cardinality(p_ids) then raise sqlstate 'PT409' using message='Batch request changed';end if;
 for rid in select x from unnest(p_ids) x order by x loop
  if p_kind='reward' then perform public.review_reward_request(rid,p_approve,p_note);else perform public.review_game_points(rid,p_approve,p_note);end if;
 end loop;
 return found_count;
end $$;
revoke all on function public.review_pending_batch(text,uuid[],boolean,text) from public,anon;
grant execute on function public.review_pending_batch(text,uuid[],boolean,text) to authenticated;
notify pgrst,'reload schema';
commit;
