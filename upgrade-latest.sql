-- تحديث شامل حتى v7. شغّل كامل الملف في SQL Editor. يحافظ على البيانات الحالية.
begin;
-- schema.sql
-- شغّل هذا الملف مرة واحدة في Supabase SQL Editor.
create table if not exists public.family_state (
 owner_id uuid primary key references auth.users(id) on delete cascade,
 data jsonb not null,
 revision bigint not null default 1,
 updated_at timestamptz not null default now()
);
alter table public.family_state enable row level security;
drop policy if exists own_family_read on public.family_state;
create policy own_family_read on public.family_state for select to authenticated using ((select auth.uid())=owner_id);
revoke all on public.family_state from anon, authenticated;
grant select on public.family_state to authenticated;
-- جميع الكتابات عبر دالة واحدة تتحقق من هوية الحساب وإصدار البيانات.
create or replace function public.save_family(p_data jsonb,p_revision bigint) returns bigint
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); current_revision bigint; k text;
begin
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

-- migration-v2.sql
-- شغّل schema.sql أولًا عند التثبيت الجديد، ثم هذا الملف. يحافظ على بيانات النسخة الأولى.

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

-- migration-v3.sql
-- تفعيل طلب تعديل التقييم المعتمد مع الحفاظ على سجل واحد ونقاط غير مكررة.
-- شغّل مرة واحدة بعد migration-v2.sql.

create or replace function public.submit_point_request(p_criterion text,p_day date,p_level integer,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and role='child';
 if not found then raise exception 'Child account required' using errcode='42501'; end if;
 if p_day is null or p_day> (now() at time zone 'Asia/Amman')::date or p_level is null or p_level not between 0 and 2 or p_note is null or length(p_note)>300 then raise exception 'Invalid request'; end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 if not exists(select 1 from jsonb_array_elements(d->'criteria') c where c->>'id'=p_criterion) then raise exception 'Unknown criterion'; end if;
 insert into public.point_requests(owner_id,requester,child_id,criterion_id,day,level,note)
 values(m.owner_id,m.user_id,m.child_id,p_criterion,p_day,p_level,p_note)
 on conflict(owner_id,child_id,criterion_id,day) do update set level=excluded.level,note=excluded.note,status='pending',review_note='',reviewed_at=null
 where point_requests.requester=excluded.requester;
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
  row_data:=jsonb_build_object('child',r.child_id,'criterion',r.criterion_id,'date',r.day::text,'level',p_level,'points',(c->'points'->>p_level)::integer,'note',r.note,'request_id',r.id);
  d:=jsonb_set(d,'{evaluations}',coalesce((select jsonb_agg(e) from jsonb_array_elements(d->'evaluations') e where not(e->>'child'=r.child_id and e->>'criterion'=r.criterion_id and e->>'date'=r.day::text)),'[]')||jsonb_build_array(row_data));
  if coalesce((select sum((e->>'points')::numeric) from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e) t where e->>'child'=r.child_id),0)<coalesce((select sum((x->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') x where x->>'child'=r.child_id),0) then raise exception 'Cannot reduce spent points'; end if;
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 update public.point_requests set status=case when p_approve then 'approved' else 'rejected' end,review_note=p_note,reviewed_at=now() where id=r.id;
end $$;
revoke all on function public.review_point_request(uuid,boolean,integer,text) from public,anon;
grant execute on function public.review_point_request(uuid,boolean,integer,text) to authenticated;

-- migration-v4.sql
-- خصم النقاط وتصفير نقاط التجربة. شغّله بعد migration-v3.sql.

create or replace function public.manage_points(p_child text,p_action text,p_criterion text,p_amount integer,p_reason text,p_revision bigint) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb; rev bigint; amount_available numeric; k text; archived jsonb:='{}'; removed jsonb; kept jsonb; req_archive jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and role='parent';
 if not found then raise exception 'Parent account required' using errcode='42501'; end if;
 if p_action is null or p_action not in ('deduct','reset') or p_reason is null or length(trim(p_reason))<1 or length(p_reason)>300 then raise exception 'Invalid operation'; end if;
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
end $$;
revoke all on function public.manage_points(text,text,text,integer,text,bigint) from public,anon;
grant execute on function public.manage_points(text,text,text,integer,text,bigint) to authenticated;
create or replace function public.load_family() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb; rev bigint; k text;
begin
 select * into m from public.family_members where user_id=auth.uid();
 if not found then raise exception 'Membership required' using errcode='42501'; end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id;
 if d is null then return jsonb_build_object('data',null,'revision',0); end if;
 if m.role='child' then
  d:=d-'resetArchive';
  d:=jsonb_set(d,'{children}',coalesce((select jsonb_agg(c) from jsonb_array_elements(d->'children') c where c->>'id'=m.child_id),'[]'));
  foreach k in array array['evaluations','attempts','redemptions','adjustments'] loop
   d:=jsonb_set(d,array[k],coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(d->k,'[]')) e where e->>'child'=m.child_id),'[]'));
  end loop;
 end if;
 return jsonb_build_object('data',d,'revision',rev);
end $$;
revoke all on function public.load_family() from public,anon;
grant execute on function public.load_family() to authenticated;

create or replace function public.save_family(p_data jsonb,p_revision bigint) returns bigint
language plpgsql security definer set search_path='' as $$
declare actor uuid; current_revision bigint; k text;
begin
 select owner_id into actor from public.family_members where user_id=auth.uid() and role='parent';
 if actor is null then raise exception 'Authentication required' using errcode='42501'; end if;
 p_data:=p_data||jsonb_build_object('adjustments',coalesce(p_data->'adjustments','[]'),'resetArchive',coalesce(p_data->'resetArchive','[]'));
 if jsonb_typeof(p_data->'adjustments') is distinct from 'array' or jsonb_typeof(p_data->'resetArchive') is distinct from 'array' then raise exception 'Invalid ledger'; end if;
 if exists(select 1 from jsonb_array_elements(p_data->'adjustments') a where (a->>'points')::numeric>=0 or (a->>'points')::numeric<>trunc((a->>'points')::numeric) or not exists(select 1 from jsonb_array_elements(p_data->'children') c where c->>'id'=a->>'child')) then raise exception 'Invalid deduction'; end if;
 if p_data->>'version' is distinct from '1' or octet_length(p_data::text)>2000000 then raise exception 'Invalid data'; end if;
 foreach k in array array['children','criteria','evaluations','rewards','redemptions','quizzes','attempts'] loop
  if jsonb_typeof(p_data->k) is distinct from 'array' then raise exception 'Invalid collection'; end if;
 end loop;
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
  return 1;
 end if;
 if current_revision<>p_revision then raise sqlstate 'PT409' using message='Revision conflict'; end if;
 update public.family_state set data=p_data,revision=revision+1,updated_at=now() where owner_id=actor;
 return current_revision+1;
end $$;

revoke all on function public.save_family(jsonb,bigint) from public,anon;
grant execute on function public.save_family(jsonb,bigint) to authenticated;
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
  row_data:=jsonb_build_object('child',r.child_id,'criterion',r.criterion_id,'date',r.day::text,'level',p_level,'points',(c->'points'->>p_level)::integer,'note',r.note,'request_id',r.id);
  d:=jsonb_set(d,'{evaluations}',coalesce((select jsonb_agg(e) from jsonb_array_elements(d->'evaluations') e where not(e->>'child'=r.child_id and e->>'criterion'=r.criterion_id and e->>'date'=r.day::text)),'[]')||jsonb_build_array(row_data));
  if coalesce((select sum((e->>'points')::numeric) from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e union all select e from jsonb_array_elements(coalesce(d->'adjustments','[]')) e) t where e->>'child'=r.child_id),0)<coalesce((select sum((x->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') x where x->>'child'=r.child_id),0) then raise exception 'Cannot reduce spent points'; end if;
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 update public.point_requests set status=case when p_approve then 'approved' else 'rejected' end,review_note=p_note,reviewed_at=now() where id=r.id;
end $$;
revoke all on function public.review_point_request(uuid,boolean,integer,text) from public,anon;
grant execute on function public.review_point_request(uuid,boolean,integer,text) to authenticated;

-- migration-v5.sql
-- إدارة الأسرة المتقدمة. شغّل بعد migration-v4.sql.

alter table public.family_members add column if not exists active boolean not null default true;
create or replace function public.is_family_admin(p_owner uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.family_members where user_id=auth.uid() and owner_id=p_owner and user_id=owner_id and role='parent' and active)$$;
create or replace function public.is_family_parent(p_owner uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.family_members where user_id=auth.uid() and owner_id=p_owner and role='parent' and active)$$;
create or replace function public.has_active_membership() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.family_members where user_id=auth.uid() and active)$$;
revoke all on function public.is_family_admin(uuid),public.has_active_membership() from public,anon;
grant execute on function public.is_family_admin(uuid),public.has_active_membership() to authenticated;
drop policy if exists member_read on public.family_members;
create policy member_read on public.family_members for select to authenticated using((user_id=auth.uid() and active) or public.is_family_admin(owner_id));
drop policy if exists request_read on public.point_requests;
create policy request_read on public.point_requests for select to authenticated using((requester=auth.uid() and public.has_active_membership()) or public.is_family_parent(owner_id));
create table if not exists public.family_audit(id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id) on delete cascade,actor_id uuid,child_id text,kind text not null,detail text not null default '',created_at timestamptz not null default now());
create table if not exists public.family_suggestions(id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id) on delete cascade,requester uuid not null references auth.users(id) on delete cascade,child_id text,kind text not null check(kind in ('reward','task','message','deduction')),title text not null check(length(title) between 1 and 100),description text not null default '' check(length(description)<=500),amount integer not null default 0 check(amount between 0 and 10000),status text not null default 'pending' check(status in ('pending','approved','rejected')),review_note text not null default '',created_at timestamptz not null default now());
alter table public.family_audit enable row level security;alter table public.family_suggestions enable row level security;
revoke all on public.family_audit,public.family_suggestions from anon,authenticated;
grant select on public.family_audit,public.family_suggestions to authenticated;
drop policy if exists audit_read on public.family_audit;create policy audit_read on public.family_audit for select to authenticated using(public.is_family_parent(owner_id));
drop policy if exists suggestions_read on public.family_suggestions;create policy suggestions_read on public.family_suggestions for select to authenticated using((requester=auth.uid() and public.has_active_membership()) or public.is_family_parent(owner_id));
-- Internal logger: callers cannot forge audit events through the public API.
create or replace function public.log_family_event(p_owner uuid,p_kind text,p_child text,p_detail text) returns void language sql security definer set search_path='' as $$insert into public.family_audit(owner_id,actor_id,kind,child_id,detail) values(p_owner,auth.uid(),p_kind,p_child,left(p_detail,1000))$$;
revoke all on function public.log_family_event(uuid,text,text,text) from public,anon,authenticated;
create or replace function public.add_suggestion(p_kind text,p_title text,p_description text,p_amount integer,p_child text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 if p_kind is null or p_kind not in ('reward','task','message','deduction') or p_title is null or length(trim(p_title)) not between 1 and 100 or p_description is null or length(p_description)>500 or p_amount is null or p_amount not between 0 and 10000 then raise exception 'Invalid suggestion';end if;
 if m.role='child' and p_kind='deduction' then raise exception 'Parent only' using errcode='42501';end if;
 if m.role='child' then p_child:=m.child_id;end if;
 select data into d from public.family_state where owner_id=m.owner_id;
 if p_child is not null and not exists(select 1 from jsonb_array_elements(d->'children') c where c->>'id'=p_child) then raise exception 'Unknown child';end if;
 if p_kind='deduction' and (p_child is null or p_amount<1 or p_amount>1000) then raise exception 'Invalid deduction';end if;
 if(select count(*) from public.family_suggestions where requester=m.user_id and status='pending')>=50 then raise exception 'Too many pending suggestions';end if;
 insert into public.family_suggestions(owner_id,requester,child_id,kind,title,description,amount) values(m.owner_id,m.user_id,p_child,p_kind,trim(p_title),p_description,p_amount);
 perform public.log_family_event(m.owner_id,'اقتراح جديد',p_child,p_title);
end $$;
revoke all on function public.add_suggestion(text,text,text,integer,text) from public,anon;grant execute on function public.add_suggestion(text,text,text,integer,text) to authenticated;
create or replace function public.review_suggestion(p_id uuid,p_approve boolean,p_amount integer,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_suggestions;d jsonb;rev bigint;newid text;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent' and user_id=owner_id;if not found then raise exception 'Admin only' using errcode='42501';end if;
 if p_approve is null or p_amount is null or p_amount not between 0 and 10000 or p_note is null or length(p_note)>300 then raise exception 'Invalid review';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 select * into s from public.family_suggestions where id=p_id and owner_id=m.owner_id for update;if not found or s.status<>'pending' then raise sqlstate 'PT409' using message='Request already reviewed';end if;
 if p_approve then
  newid:=replace(gen_random_uuid()::text,'-','');
  if s.kind='reward' then
   if p_amount<1 then raise exception 'Cost required';end if;
   d:=jsonb_set(d,'{rewards}',(d->'rewards')||jsonb_build_array(jsonb_build_object('id',newid,'name',s.title,'description',s.description,'cost',p_amount,'suggested_by',s.child_id)));
  elsif s.kind='task' then
   if p_amount>1000 then raise exception 'Points limit';end if;
   d:=jsonb_set(d,'{criteria}',(d->'criteria')||jsonb_build_array(jsonb_build_object('id','bonus_'||newid,'name',s.title,'points',jsonb_build_array(0,p_amount/2,p_amount),'assigned_child',s.child_id)));
  elsif s.kind='deduction' then
   perform public.manage_points(s.child_id,'deduct',null,p_amount,s.title||': '||s.description,rev);
   select data into d from public.family_state where owner_id=m.owner_id;
  end if;
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 update public.family_suggestions set status=case when p_approve then 'approved' else 'rejected' end,review_note=p_note,amount=p_amount where id=s.id;
 perform public.log_family_event(m.owner_id,case when p_approve then 'اعتماد اقتراح' else 'إعادة اقتراح' end,s.child_id,s.title||' — '||p_note);
end $$;
revoke all on function public.review_suggestion(uuid,boolean,integer,text) from public,anon;grant execute on function public.review_suggestion(uuid,boolean,integer,text) to authenticated;
create or replace function public.set_child_preferences(p_theme text,p_motion boolean,p_sound boolean) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='child';if not found then raise exception 'Child required' using errcode='42501';end if;
 if p_theme is null or p_theme not in ('car','ladder','rocket') or p_motion is null or p_sound is null then raise exception 'Invalid preference';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 d:=jsonb_set(d,'{children}',(select jsonb_agg(case when c->>'id'=m.child_id then c||jsonb_build_object('theme',p_theme,'motion',p_motion,'sound',p_sound) else c end) from jsonb_array_elements(d->'children') c));
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
end $$;
revoke all on function public.set_child_preferences(text,boolean,boolean) from public,anon;grant execute on function public.set_child_preferences(text,boolean,boolean) to authenticated;
create or replace function public.add_encouragement(p_child text,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_note is null or length(trim(p_note)) not between 1 and 300 then raise exception 'Invalid note';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;if not exists(select 1 from jsonb_array_elements(d->'children') c where c->>'id'=p_child) then raise exception 'Unknown child';end if;
 d:=jsonb_set(d,'{encouragements}',coalesce(d->'encouragements','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',p_child,'note',trim(p_note),'date',(now() at time zone 'Asia/Amman')::date::text)));
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'رسالة تشجيع',p_child,p_note);
end $$;
revoke all on function public.add_encouragement(text,text) from public,anon;grant execute on function public.add_encouragement(text,text) to authenticated;
-- Deletes live AND archived child data; only internal trigger/admin RPC may call it.
create or replace function public.purge_child_data(p_owner uuid,p_child text) returns void language plpgsql security definer set search_path='' as $$
declare d jsonb;k text;
begin
 select data into d from public.family_state where owner_id=p_owner for update;if d is null then return;end if;
 d:=jsonb_set(d,'{children}',coalesce((select jsonb_agg(c) from jsonb_array_elements(d->'children') c where c->>'id'<>p_child),'[]'));
 foreach k in array array['evaluations','attempts','redemptions','adjustments','resetArchive','encouragements'] loop
  d:=jsonb_set(d,array[k],coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(d->k,'[]')) e where e->>'child' is distinct from p_child),'[]'));
 end loop;
 d:=jsonb_set(d,'{criteria}',coalesce((select jsonb_agg(c) from jsonb_array_elements(d->'criteria') c where c->>'assigned_child' is distinct from p_child),'[]'));
 delete from public.point_requests where owner_id=p_owner and child_id=p_child;
 delete from public.family_suggestions where owner_id=p_owner and child_id=p_child;
 delete from public.family_audit where owner_id=p_owner and child_id=p_child;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=p_owner;
end $$;
revoke all on function public.purge_child_data(uuid,text) from public,anon,authenticated;
create or replace function public.on_family_auth_delete() returns trigger language plpgsql security definer set search_path='' as $$
declare m public.family_members;
begin
 select * into m from public.family_members where user_id=old.id;
 if found and m.role='child' then perform public.purge_child_data(m.owner_id,m.child_id);end if;
 return old;
end $$;
revoke all on function public.on_family_auth_delete() from public,anon,authenticated;
drop trigger if exists family_auth_cleanup on auth.users;
create trigger family_auth_cleanup before delete on auth.users for each row execute function public.on_family_auth_delete();
create or replace function public.delete_child_profile(p_child text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;
begin
 select * into m from public.family_members where user_id=auth.uid() and role='parent' and user_id=owner_id and active;if not found then raise exception 'Admin only' using errcode='42501';end if;
 if exists(select 1 from public.family_members where owner_id=m.owner_id and child_id=p_child) then raise exception 'Delete linked account first';end if;
 perform public.purge_child_data(m.owner_id,p_child);perform public.log_family_event(m.owner_id,'حذف ملف طفل',null,'حذف كامل من السجلات النشطة والأرشيف');
end $$;
revoke all on function public.delete_child_profile(text) from public,anon;grant execute on function public.delete_child_profile(text) to authenticated;
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
 if not m.active then raise exception 'Account disabled' using errcode='42501';end if;
 return to_jsonb(m)||jsonb_build_object('is_primary',m.role='parent' and m.user_id=m.owner_id);
end $$;
revoke all on function public.my_membership() from public,anon;
grant execute on function public.my_membership() to authenticated;
-- Child receives only its own records, never the complete family document.

create or replace function public.load_family() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb; rev bigint; k text;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;
 if not found then raise exception 'Membership required' using errcode='42501'; end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id;
 if d is null then return jsonb_build_object('data',null,'revision',0); end if;
 if m.role='parent' and m.user_id<>m.owner_id then d:=d-'resetArchive';end if;
 if m.role='child' then
  d:=d-'resetArchive';
  d:=jsonb_set(d,'{criteria}',coalesce((select jsonb_agg(c) from jsonb_array_elements(d->'criteria') c where c->>'assigned_child' is null or c->>'assigned_child'=m.child_id),'[]'));
  d:=jsonb_set(d,'{children}',coalesce((select jsonb_agg(c) from jsonb_array_elements(d->'children') c where c->>'id'=m.child_id),'[]'));
  foreach k in array array['evaluations','attempts','redemptions','adjustments','encouragements'] loop
   d:=jsonb_set(d,array[k],coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(d->k,'[]')) e where e->>'child'=m.child_id),'[]'));
  end loop;
 end if;
 return jsonb_build_object('data',d,'revision',rev);
end $$;
revoke all on function public.load_family() from public,anon;
grant execute on function public.load_family() to authenticated;


create or replace function public.save_family(p_data jsonb,p_revision bigint) returns bigint
language plpgsql security definer set search_path='' as $$
declare actor uuid; current_revision bigint; k text;
begin
 select owner_id into actor from public.family_members where user_id=auth.uid() and active and role='parent' and user_id=owner_id;
 if actor is null then raise exception 'Authentication required' using errcode='42501'; end if;
 p_data:=p_data||jsonb_build_object('adjustments',coalesce(p_data->'adjustments','[]'),'resetArchive',coalesce(p_data->'resetArchive','[]'));
 if jsonb_typeof(p_data->'adjustments') is distinct from 'array' or jsonb_typeof(p_data->'resetArchive') is distinct from 'array' then raise exception 'Invalid ledger'; end if;
 if exists(select 1 from jsonb_array_elements(p_data->'adjustments') a where (a->>'points')::numeric>=0 or (a->>'points')::numeric<>trunc((a->>'points')::numeric) or not exists(select 1 from jsonb_array_elements(p_data->'children') c where c->>'id'=a->>'child')) then raise exception 'Invalid deduction'; end if;
 if p_data->>'version' is distinct from '1' or octet_length(p_data::text)>2000000 then raise exception 'Invalid data'; end if;
 foreach k in array array['children','criteria','evaluations','rewards','redemptions','quizzes','attempts'] loop
  if jsonb_typeof(p_data->k) is distinct from 'array' then raise exception 'Invalid collection'; end if;
 end loop;
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

create or replace function public.manage_points(p_child text,p_action text,p_criterion text,p_amount integer,p_reason text,p_revision bigint) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb; rev bigint; amount_available numeric; k text; archived jsonb:='{}'; removed jsonb; kept jsonb; req_archive jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent' and user_id=owner_id;
 if not found then raise exception 'Parent account required' using errcode='42501'; end if;
 if p_action is null or p_action not in ('deduct','reset') or p_reason is null or length(trim(p_reason))<1 or length(p_reason)>300 then raise exception 'Invalid operation'; end if;
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
  if c is null or not exists(select 1 from jsonb_array_elements(d->'children') x where x->>'id'=r.child_id) then raise exception 'Missing criterion or child'; end if;
  row_data:=jsonb_build_object('child',r.child_id,'criterion',r.criterion_id,'date',r.day::text,'level',p_level,'points',(c->'points'->>p_level)::integer,'note',r.note,'request_id',r.id);
  d:=jsonb_set(d,'{evaluations}',coalesce((select jsonb_agg(e) from jsonb_array_elements(d->'evaluations') e where not(e->>'child'=r.child_id and e->>'criterion'=r.criterion_id and e->>'date'=r.day::text)),'[]')||jsonb_build_array(row_data));
  if coalesce((select sum((e->>'points')::numeric) from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e union all select e from jsonb_array_elements(coalesce(d->'adjustments','[]')) e) t where e->>'child'=r.child_id),0)<coalesce((select sum((x->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') x where x->>'child'=r.child_id),0) then raise exception 'Cannot reduce spent points'; end if;
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 update public.point_requests set status=case when p_approve then 'approved' else 'rejected' end,review_note=p_note,reviewed_at=now() where id=r.id;
 perform public.log_family_event(m.owner_id,case when p_approve then 'اعتماد إنجاز' else 'إعادة إنجاز للمراجعة' end,r.child_id,p_note);
end $$;
revoke all on function public.review_point_request(uuid,boolean,integer,text) from public,anon;
grant execute on function public.review_point_request(uuid,boolean,integer,text) to authenticated;



create or replace function public.submit_point_request(p_criterion text,p_day date,p_level integer,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='child';
 if not found then raise exception 'Child account required' using errcode='42501'; end if;
 if p_day is null or p_day> (now() at time zone 'Asia/Amman')::date or p_level is null or p_level not between 0 and 2 or p_note is null or length(p_note)>300 then raise exception 'Invalid request'; end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 if not exists(select 1 from jsonb_array_elements(d->'criteria') c where c->>'id'=p_criterion and (c->>'assigned_child' is null or c->>'assigned_child'=m.child_id)) then raise exception 'Unknown criterion'; end if;
 insert into public.point_requests(owner_id,requester,child_id,criterion_id,day,level,note)
 values(m.owner_id,m.user_id,m.child_id,p_criterion,p_day,p_level,p_note)
 on conflict(owner_id,child_id,criterion_id,day) do update set level=excluded.level,note=excluded.note,status='pending',review_note='',reviewed_at=null
 where point_requests.requester=excluded.requester;
 if not found then raise sqlstate 'PT409' using message='Already approved'; end if;
end $$;
revoke all on function public.submit_point_request(text,date,integer,text) from public,anon;
grant execute on function public.submit_point_request(text,date,integer,text) to authenticated;


create or replace function public.cleanup_trial(p_child text,p_keys text[],p_reason text,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;k text;prefix text;removed jsonb;kept jsonb;snapshot jsonb:='{}';amount_available numeric;reqs jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent' and user_id=owner_id;if not found then raise exception 'Admin only' using errcode='42501';end if;
 if p_keys is null or cardinality(p_keys) not between 1 and 500 or p_reason is null or length(trim(p_reason)) not between 1 and 300 then raise exception 'Invalid cleanup';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 foreach k in array array['evaluations','adjustments','attempts','redemptions'] loop
  prefix:=case k when 'evaluations' then 'e' when 'adjustments' then 'a' when 'attempts' then 'q' else 'r' end;
  select coalesce(jsonb_agg(e) filter(where e->>'child'=p_child and (case when k='evaluations' then 'e|'||(e->>'criterion')||'|'||(e->>'date') else prefix||'|'||(e->>'id') end)=any(p_keys)),'[]'),coalesce(jsonb_agg(e) filter(where not(e->>'child'=p_child and coalesce((case when k='evaluations' then 'e|'||(e->>'criterion')||'|'||(e->>'date') else prefix||'|'||(e->>'id') end)=any(p_keys),false))),'[]') into removed,kept from jsonb_array_elements(coalesce(d->k,'[]')) e;
  snapshot:=snapshot||jsonb_build_object(k,removed);d:=jsonb_set(d,array[k],kept);
 end loop;
 select coalesce(sum((e->>'points')::numeric),0) into amount_available from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e union all select e from jsonb_array_elements(d->'adjustments') e) t where e->>'child'=p_child;
 if amount_available<coalesce((select sum((r->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') r where r->>'child'=p_child),0) then raise exception 'Reset would reduce spent points';end if;
 select coalesce(jsonb_agg(to_jsonb(r)),'[]') into reqs from public.point_requests r where owner_id=m.owner_id and child_id=p_child and ('e|'||criterion_id||'|'||day::text)=any(p_keys);
 delete from public.point_requests where owner_id=m.owner_id and child_id=p_child and ('e|'||criterion_id||'|'||day::text)=any(p_keys);
 snapshot:=snapshot||jsonb_build_object('requests',reqs);
 d:=jsonb_set(d,'{resetArchive}',coalesce(d->'resetArchive','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',p_child,'date',(now() at time zone 'Asia/Amman')::date::text,'note',p_reason,'records',snapshot)));
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تنظيف سجلات تجربة',p_child,p_reason);
end $$;
revoke all on function public.cleanup_trial(text,text[],text,bigint) from public,anon;grant execute on function public.cleanup_trial(text,text[],text,bigint) to authenticated;
-- Reject account creation by an old Edge Function that does not identify the verified primary admin.
alter table public.family_members add column if not exists created_by uuid;
create or replace function public.check_member_creation() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.user_id=new.owner_id and new.role='parent' and auth.uid()=new.user_id then return new;end if;
 if not exists(select 1 from public.family_members where user_id=new.created_by and owner_id=new.owner_id and user_id=owner_id and role='parent' and active) then raise exception 'Primary admin provenance required' using errcode='42501';end if;
 return new;
end $$;
revoke all on function public.check_member_creation() from public,anon,authenticated;
drop trigger if exists verify_family_member_creation on public.family_members;
create trigger verify_family_member_creation before insert on public.family_members for each row execute function public.check_member_creation();
drop policy if exists own_family_read on public.family_state;
create policy own_family_read on public.family_state for select to authenticated using(public.is_family_admin(owner_id));
do $$ begin if exists(select 1 from pg_roles where rolname='service_role') then grant select,insert,update,delete on public.family_members,public.family_audit,public.family_suggestions to service_role;grant select on public.family_state to service_role;end if;end $$;

-- migration-v6.sql
-- تفويض صلاحيات النقاط لولي الأمر الثاني. شغّل بعد v5.

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

-- migration-v7.sql
-- إصلاح تعديل الاسم بصورة مستقلة عن دالة إنشاء المستخدمين. شغّل بعد v6.

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
