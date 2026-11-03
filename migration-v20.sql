-- طلب الطفل استبدال المكافأة، واعتماد ولي الأمر قبل الخصم.
begin;
create table if not exists public.reward_requests(
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 requester uuid not null references auth.users(id) on delete cascade,
 child_id text not null,reward_id text not null,reward_name text not null,
 cost integer not null check(cost>0),note text not null default '' check(length(note)<=300),
 status text not null default 'pending' check(status in('pending','approved','rejected')),
 review_note text not null default '' check(length(review_note)<=300),
 created_at timestamptz not null default now(),reviewed_at timestamptz
);
create unique index if not exists reward_request_pending on public.reward_requests(owner_id,child_id,reward_id) where status='pending';
alter table public.reward_requests enable row level security;
revoke all on public.reward_requests from public,anon,authenticated;
grant select on public.reward_requests to authenticated;
drop policy if exists reward_request_read on public.reward_requests;
create policy reward_request_read on public.reward_requests for select to authenticated using(
 exists(select 1 from public.family_members m where m.user_id=auth.uid() and m.active and m.owner_id=reward_requests.owner_id and (m.role='parent' or (m.role='child' and m.child_id=reward_requests.child_id and reward_requests.requester=auth.uid())))
);
create or replace function public.request_reward(p_reward text,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;r jsonb;available numeric;request_id uuid;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='child';if not found then raise exception 'Child account required' using errcode='42501';end if;
 if p_note is null or length(p_note)>300 then raise exception 'Invalid request';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 if not exists(select 1 from jsonb_array_elements(d->'children') c where c->>'id'=m.child_id) then raise exception 'Unknown child';end if;
 select value into r from jsonb_array_elements(d->'rewards') where value->>'id'=p_reward and not coalesce((value->>'archived')::boolean,false);if r is null then raise exception 'Unknown reward';end if;
 if exists(select 1 from public.reward_requests where owner_id=m.owner_id and child_id=m.child_id and reward_id=p_reward and status='pending') then raise sqlstate 'PT409' using message='Reward request pending';end if;
 select coalesce(sum((e->>'points')::numeric),0) into available from (select value e from jsonb_array_elements(d->'evaluations') union all select value from jsonb_array_elements(d->'attempts') union all select value from jsonb_array_elements(coalesce(d->'adjustments','[]'))) ledger where e->>'child'=m.child_id;
 available:=available-coalesce((select sum((x->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') x where x->>'child'=m.child_id),0);
 if available<(r->>'cost')::integer then raise exception 'Reward balance insufficient';end if;
 insert into public.reward_requests(owner_id,requester,child_id,reward_id,reward_name,cost,note) values(m.owner_id,m.user_id,m.child_id,p_reward,r->>'name',(r->>'cost')::integer,trim(p_note)) returning id into request_id;
 perform public.log_family_event(m.owner_id,'طلب استبدال مكافأة',m.child_id,r->>'name');
 return request_id;
end $$;
create or replace function public.review_reward_request(p_id uuid,p_approve boolean,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;r public.reward_requests;d jsonb;reward jsonb;available numeric;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent account required' using errcode='42501';end if;
 if p_approve is null or p_note is null or length(p_note)>300 then raise exception 'Invalid review';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select * into r from public.reward_requests where id=p_id and owner_id=m.owner_id for update;
 if not found or r.status<>'pending' then raise sqlstate 'PT409' using message='Reward request already reviewed';end if;
 if p_approve then
  if not exists(select 1 from public.family_members where user_id=r.requester and owner_id=m.owner_id and active and role='child' and child_id=r.child_id) or not exists(select 1 from jsonb_array_elements(d->'children') c where c->>'id'=r.child_id) then raise exception 'Reward child unavailable';end if;
  select value into reward from jsonb_array_elements(d->'rewards') where value->>'id'=r.reward_id and not coalesce((value->>'archived')::boolean,false);
  if reward is null then raise exception 'Unknown reward';end if;
  if (reward->>'cost')::integer<>r.cost then raise sqlstate 'PT409' using message='Reward cost changed';end if;
  select coalesce(sum((e->>'points')::numeric),0) into available from (select value e from jsonb_array_elements(d->'evaluations') union all select value from jsonb_array_elements(d->'attempts') union all select value from jsonb_array_elements(coalesce(d->'adjustments','[]'))) ledger where e->>'child'=r.child_id;
  available:=available-coalesce((select sum((x->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') x where x->>'child'=r.child_id),0);
  if available<r.cost then raise exception 'Reward balance insufficient';end if;
  d:=jsonb_set(d,'{redemptions}',(d->'redemptions')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',r.child_id,'reward',r.reward_id,'name',r.reward_name,'cost',r.cost,'date',(now() at time zone 'Asia/Amman')::date::text,'request_id',r.id)));
  if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 update public.reward_requests set status=case when p_approve then 'approved' else 'rejected' end,review_note=trim(p_note),reviewed_at=now() where id=r.id;
 perform public.log_family_event(m.owner_id,case when p_approve then 'اعتماد استبدال مكافأة' else 'رفض استبدال مكافأة' end,r.child_id,r.reward_name||' · '||trim(p_note));
end $$;
revoke all on function public.request_reward(text,text) from public,anon;
revoke all on function public.review_reward_request(uuid,boolean,text) from public,anon;
grant execute on function public.request_reward(text,text) to authenticated;
grant execute on function public.review_reward_request(uuid,boolean,text) to authenticated;
notify pgrst,'reload schema';
commit;
