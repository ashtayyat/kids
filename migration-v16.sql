-- رفض واضح وإعادة المقترحات وتعديل نصوصها مع منع الكتابة فوق تعديل أحدث.
begin;
alter table public.family_suggestions add column if not exists revision bigint not null default 0;
alter table public.family_suggestions drop constraint if exists family_suggestions_status_check;
alter table public.family_suggestions add constraint family_suggestions_status_check check(status in ('pending','approved','rejected','returned'));
create or replace function public.edit_family_suggestion(p_id uuid,p_title text,p_description text,p_amount integer,p_resubmit boolean,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_suggestions;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 if p_title is null or length(trim(p_title)) not between 1 and 100 or p_description is null or length(p_description)>500 or p_amount is null or p_amount not between 0 and 10000 or p_resubmit is null then raise exception 'Invalid suggestion';end if;
 perform 1 from public.family_state where owner_id=m.owner_id for update;
 select * into s from public.family_suggestions where id=p_id and owner_id=m.owner_id for update;
 if not found or (m.role='child' and s.requester<>m.user_id) then raise exception 'Suggestion access denied' using errcode='42501';end if;
 if s.status='approved' then raise exception 'Approved suggestion cannot be edited';end if;
 if s.revision is distinct from p_revision then raise sqlstate 'PT409' using message='Suggestion changed';end if;
 if s.kind='deduction' and not public.has_family_permission(m.owner_id,'deduct_points') then raise exception 'Deduction permission required' using errcode='42501';end if;
 if p_resubmit and s.status<>'pending' and (select count(*) from public.family_suggestions where requester=s.requester and status='pending')>=50 then raise exception 'Too many pending suggestions';end if;
 update public.family_suggestions set title=trim(p_title),description=p_description,amount=p_amount,status=case when p_resubmit then 'pending' else status end,revision=revision+1 where id=s.id;
 perform public.log_family_event(m.owner_id,'تعديل اقتراح',s.child_id,trim(p_title));
end $$;
revoke all on function public.edit_family_suggestion(uuid,text,text,integer,boolean,bigint) from public,anon;
grant execute on function public.edit_family_suggestion(uuid,text,text,integer,boolean,bigint) to authenticated;
create or replace function public.review_family_suggestion(p_id uuid,p_decision text,p_title text,p_description text,p_amount integer,p_note text,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_suggestions;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_decision is null or p_decision not in ('approve','return','reject') or p_title is null or length(trim(p_title)) not between 1 and 100 or p_description is null or length(p_description)>500 or p_amount is null or p_amount not between 0 and 10000 or p_note is null or length(p_note)>300 then raise exception 'Invalid review';end if;
 perform 1 from public.family_state where owner_id=m.owner_id for update;
 select * into s from public.family_suggestions where id=p_id and owner_id=m.owner_id for update;
 if not found or s.status<>'pending' then raise sqlstate 'PT409' using message='Request already reviewed';end if;
 if s.revision is distinct from p_revision then raise sqlstate 'PT409' using message='Suggestion changed';end if;
 if s.kind='deduction' and not public.has_family_permission(m.owner_id,'deduct_points') then raise exception 'Deduction permission required' using errcode='42501';end if;
 update public.family_suggestions set title=trim(p_title),description=p_description,revision=revision+1 where id=s.id;
 -- Existing approval code creates rewards/tasks and enforces the delegated deduction permission.
 perform public.review_suggestion(s.id,p_decision='approve',p_amount,p_note);
 if p_decision='return' then update public.family_suggestions set status='returned' where id=s.id;end if;
 if p_decision='reject' then perform public.log_family_event(m.owner_id,'رفض اقتراح',s.child_id,trim(p_title)||' — '||p_note);end if;
end $$;
revoke all on function public.review_family_suggestion(uuid,text,text,text,integer,text,bigint) from public,anon;
grant execute on function public.review_family_suggestion(uuid,text,text,text,integer,text,bigint) to authenticated;
notify pgrst,'reload schema';
commit;
