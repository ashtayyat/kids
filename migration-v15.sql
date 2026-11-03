-- صور أدلة اختيارية، تخصيص الطفل، وعبارات التشجيع. شغّل بعد v14.
begin;
alter table public.point_requests add column if not exists evidence text;
alter table public.point_requests drop constraint if exists point_request_evidence;
alter table public.point_requests add constraint point_request_evidence check(evidence is null or (length(evidence)<=100000 and evidence ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$'));
-- Separate RPC preserves the existing four-argument API and older clients.
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
 on conflict(owner_id,child_id,criterion_id,day) do update set level=excluded.level,note=excluded.note,evidence=excluded.evidence,status='pending',review_note='',reviewed_at=null
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
 if not found or r.status<>'pending' then raise sqlstate 'PT409' using message='Request already reviewed'; end if;
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
create or replace function public.save_child_customization(p_theme text,p_motion boolean,p_sound boolean,p_color text,p_avatar text,p_photo text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='child';if not found then raise exception 'Child required' using errcode='42501';end if;
 if p_theme is null or p_theme not in ('car','ladder','rocket') or p_motion is null or p_sound is null or p_color is null or p_color not in ('red','blue','green','purple','pink','gold') or p_avatar is null or p_avatar not in ('🦊','🐼','🦁','🐰','🐯','🦋','🐨','🌸') then raise exception 'Invalid preference';end if;
 if p_photo is not null and p_photo<>'' and (length(p_photo)>100000 or p_photo !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$') then raise exception 'Invalid photo';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 if not exists(select 1 from jsonb_array_elements(d->'children') c where c->>'id'=m.child_id) then raise exception 'Unknown child';end if;
 d:=jsonb_set(d,'{children}',(select jsonb_agg(case when c->>'id'=m.child_id then c||jsonb_build_object('theme',p_theme,'motion',p_motion,'sound',p_sound,'carColor',p_color,'avatar',p_avatar,'photo',coalesce(p_photo,'')) else c end) from jsonb_array_elements(d->'children') c));
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
end $$;
revoke all on function public.save_child_customization(text,boolean,boolean,text,text,text) from public,anon;
grant execute on function public.save_child_customization(text,boolean,boolean,text,text,text) to authenticated;
create table if not exists public.family_encouragement_phrases(id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id) on delete cascade,phrase text not null check(length(trim(phrase)) between 1 and 300),created_at timestamptz not null default now(),unique(owner_id,phrase));
alter table public.family_encouragement_phrases enable row level security;
revoke all on public.family_encouragement_phrases from anon,authenticated;
grant select on public.family_encouragement_phrases to authenticated;
drop policy if exists parent_phrases on public.family_encouragement_phrases;
create policy parent_phrases on public.family_encouragement_phrases for select to authenticated using(public.is_family_parent(owner_id));
create or replace function public.add_encouragement_phrase(p_phrase text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_phrase is null or length(trim(p_phrase)) not between 1 and 300 then raise exception 'Invalid phrase';end if;
 perform 1 from public.family_state where owner_id=m.owner_id for update;
 if exists(select 1 from public.family_encouragement_phrases where owner_id=m.owner_id and phrase=trim(p_phrase)) then return;end if;
 if(select count(*) from public.family_encouragement_phrases where owner_id=m.owner_id)>=50 then raise exception 'Phrase limit reached';end if;
 insert into public.family_encouragement_phrases(owner_id,phrase) values(m.owner_id,trim(p_phrase));
end $$;
revoke all on function public.add_encouragement_phrase(text) from public,anon;
grant execute on function public.add_encouragement_phrase(text) to authenticated;
notify pgrst,'reload schema';
commit;
