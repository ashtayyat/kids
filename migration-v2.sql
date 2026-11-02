-- شغّل schema.sql أولًا عند التثبيت الجديد، ثم هذا الملف. يحافظ على بيانات النسخة الأولى.
begin;
create table if not exists public.family_members(
 user_id uuid primary key references auth.users(id) on delete cascade,
 owner_id uuid not null references auth.users(id) on delete cascade,
 username text unique,
 display_name text not null,
 role text not null check(role in ('parent','child')),
 child_id text,
 check((role='parent' and child_id is null) or (role='child' and child_id is not null)),
 unique(owner_id,child_id)
);
create table if not exists public.point_requests(
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 requester uuid not null references auth.users(id) on delete cascade,
 child_id text not null,criterion_id text not null,day date not null,
 level integer not null check(level between 0 and 2),note text not null default '' check(length(note)<=300),
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 review_note text not null default '' check(length(review_note)<=300),
 created_at timestamptz not null default now(), reviewed_at timestamptz,
 unique(owner_id,child_id,criterion_id,day)
);
alter table public.family_members enable row level security;
alter table public.point_requests enable row level security;
revoke all on public.family_members,public.point_requests from anon,authenticated;
grant select on public.family_members,public.point_requests to authenticated;
-- Helper does not accept arbitrary user IDs; exposes caller's family only.
create or replace function public.is_family_parent(p_owner uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.family_members where user_id=auth.uid() and owner_id=p_owner and role='parent');
$$;
revoke all on function public.is_family_parent(uuid) from public,anon;
grant execute on function public.is_family_parent(uuid) to authenticated;
drop policy if exists member_read on public.family_members;
create policy member_read on public.family_members for select to authenticated using(user_id=auth.uid() or public.is_family_parent(owner_id));
drop policy if exists request_read on public.point_requests;
create policy request_read on public.point_requests for select to authenticated using(requester=auth.uid() or public.is_family_parent(owner_id));
drop policy if exists own_family_read on public.family_state;
create policy own_family_read on public.family_state for select to authenticated using(public.is_family_parent(owner_id));
-- Existing account created by the project owner can bootstrap its OWN family only.
-- Managed child/parent accounts cannot self-promote when their membership is absent.
create or replace function public.my_membership() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members; actor uuid:=auth.uid();
begin
 if actor is null then raise exception 'Authentication required' using errcode='42501'; end if;
 select * into m from public.family_members where user_id=actor;
 if not found then
  if exists(select 1 from auth.users where id=actor and coalesce((raw_app_meta_data->>'managed_family_account')::boolean,false)) then raise exception 'Membership missing' using errcode='42501'; end if;
  insert into public.family_members(user_id,owner_id,display_name,role) values(actor,actor,'ولي الأمر','parent') on conflict(user_id) do nothing;
  select * into m from public.family_members where user_id=actor;
 end if;
 return to_jsonb(m);
end $$;
revoke all on function public.my_membership() from public,anon;
grant execute on function public.my_membership() to authenticated;
-- Child receives only its own records, never the complete family document.
create or replace function public.load_family() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb; rev bigint; k text;
begin
 select * into m from public.family_members where user_id=auth.uid();
 if not found then raise exception 'Membership required' using errcode='42501'; end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id;
 if d is null then return jsonb_build_object('data',null,'revision',0); end if;
 if m.role='child' then
  d:=jsonb_set(d,'{children}',coalesce((select jsonb_agg(c) from jsonb_array_elements(d->'children') c where c->>'id'=m.child_id),'[]'));
  foreach k in array array['evaluations','attempts','redemptions'] loop
   d:=jsonb_set(d,array[k],coalesce((select jsonb_agg(e) from jsonb_array_elements(d->k) e where e->>'child'=m.child_id),'[]'));
  end loop;
 end if;
 return jsonb_build_object('data',d,'revision',rev);
end $$;
revoke all on function public.load_family() from public,anon;
grant execute on function public.load_family() to authenticated;

create or replace function public.submit_point_request(p_criterion text,p_day date,p_level integer,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and role='child';
 if not found then raise exception 'Child account required' using errcode='42501'; end if;
 if p_day is null or p_day> (now() at time zone 'Asia/Amman')::date or p_level is null or p_level not between 0 and 2 or p_note is null or length(p_note)>300 then raise exception 'Invalid request'; end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 if not exists(select 1 from jsonb_array_elements(d->'criteria') c where c->>'id'=p_criterion) then raise exception 'Unknown criterion'; end if;
 if exists(select 1 from jsonb_array_elements(d->'evaluations') e where e->>'child'=m.child_id and e->>'criterion'=p_criterion and e->>'date'=p_day::text) then raise sqlstate 'PT409' using message='Already evaluated'; end if;
 insert into public.point_requests(owner_id,requester,child_id,criterion_id,day,level,note)
 values(m.owner_id,m.user_id,m.child_id,p_criterion,p_day,p_level,p_note)
 on conflict(owner_id,child_id,criterion_id,day) do update set level=excluded.level,note=excluded.note,status='pending',review_note='',reviewed_at=null
 where point_requests.requester=excluded.requester and point_requests.status<>'approved';
 if not found then raise sqlstate 'PT409' using message='Already approved'; end if;
end $$;
revoke all on function public.submit_point_request(text,date,integer,text) from public,anon;
grant execute on function public.submit_point_request(text,date,integer,text) to authenticated;

create or replace function public.review_point_request(p_id uuid,p_approve boolean,p_level integer,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; r public.point_requests; d jsonb; c jsonb; row_data jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and role='parent';
 if not found then raise exception 'Parent account required' using errcode='42501'; end if;
 if p_approve is null or p_note is null or length(p_note)>300 or (p_approve and (p_level is null or p_level not between 0 and 2)) then raise exception 'Invalid review'; end if;
 -- Lock family first, the same order used by submissions and parent edits.
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select * into r from public.point_requests where id=p_id and owner_id=m.owner_id for update;
 if not found or r.status<>'pending' then raise sqlstate 'PT409' using message='Request already reviewed'; end if;
 if p_approve then
  select value into c from jsonb_array_elements(d->'criteria') where value->>'id'=r.criterion_id;
  if c is null or not exists(select 1 from jsonb_array_elements(d->'children') x where x->>'id'=r.child_id) then raise exception 'Missing criterion or child'; end if;
  if exists(select 1 from jsonb_array_elements(d->'evaluations') e where e->>'child'=r.child_id and e->>'criterion'=r.criterion_id and e->>'date'=r.day::text) then raise sqlstate 'PT409' using message='Already evaluated'; end if;
  row_data:=jsonb_build_object('child',r.child_id,'criterion',r.criterion_id,'date',r.day::text,'level',p_level,'points',(c->'points'->>p_level)::integer,'note',r.note,'request_id',r.id);
  d:=jsonb_set(d,'{evaluations}',(d->'evaluations')||jsonb_build_array(row_data));
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 update public.point_requests set status=case when p_approve then 'approved' else 'rejected' end,review_note=p_note,reviewed_at=now() where id=r.id;
end $$;
revoke all on function public.review_point_request(uuid,boolean,integer,text) from public,anon;
grant execute on function public.review_point_request(uuid,boolean,integer,text) to authenticated;

-- Parent-only replacement; children cannot write the family document.
create or replace function public.save_family(p_data jsonb,p_revision bigint) returns bigint
language plpgsql security definer set search_path='' as $$
declare actor uuid; current_revision bigint; k text;
begin
 select owner_id into actor from public.family_members where user_id=auth.uid() and role='parent';
 if actor is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if p_data->>'version' is distinct from '1' or octet_length(p_data::text)>2000000 then raise exception 'Invalid data'; end if;
 foreach k in array array['children','criteria','evaluations','rewards','redemptions','quizzes','attempts'] loop
  if jsonb_typeof(p_data->k) is distinct from 'array' then raise exception 'Invalid collection'; end if;
 end loop;
 if exists(select 1 from jsonb_array_elements(p_data->'evaluations') e group by e->>'child',e->>'criterion',e->>'date' having count(*)>1) then raise exception 'Duplicate daily evaluation'; end if;
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
  return 1;
 end if;
 if current_revision<>p_revision then raise sqlstate 'PT409' using message='Revision conflict'; end if;
 update public.family_state set data=p_data,revision=revision+1,updated_at=now() where owner_id=actor;
 return current_revision+1;
end $$;

revoke all on function public.save_family(jsonb,bigint) from public,anon;
grant execute on function public.save_family(jsonb,bigint) to authenticated;
commit;
