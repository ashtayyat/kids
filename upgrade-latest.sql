-- تحديث شامل حتى v19، مع الحفاظ على البيانات.
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
-- migration-v8.sql
-- العمل اليومي مشترك بين وليي الأمر. شغّل بعد v7.
create or replace function public.save_family(p_data jsonb,p_revision bigint) returns bigint
language plpgsql security definer set search_path='' as $$
declare actor uuid; current_revision bigint; k text; existing_data jsonb; merged jsonb; main_parent boolean;
begin
 select owner_id into actor from public.family_members where user_id=auth.uid() and active and role='parent';
 if actor is null then raise exception 'Authentication required' using errcode='42501'; end if;
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
  foreach k in array array['children','criteria','evaluations','rewards','redemptions','quizzes','attempts'] loop
   if jsonb_typeof(p_data->k) is distinct from 'array' then raise exception 'Invalid collection';end if;
   merged:=jsonb_set(merged,array[k],p_data->k);
  end loop;
  p_data:=merged;
 end if;

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

create or replace function public.review_suggestion(p_id uuid,p_approve boolean,p_amount integer,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_suggestions;d jsonb;rev bigint;newid text;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Admin only' using errcode='42501';end if;
 if p_approve is null or p_amount is null or p_amount not between 0 and 10000 or p_note is null or length(p_note)>300 then raise exception 'Invalid review';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 select * into s from public.family_suggestions where id=p_id and owner_id=m.owner_id for update;if not found or s.status<>'pending' then raise sqlstate 'PT409' using message='Request already reviewed';end if;
 if s.kind='deduction' and not public.has_family_permission(m.owner_id,'deduct_points') then raise exception 'Deduction permission required' using errcode='42501';end if;
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

-- migration-v9.sql
-- إضافة الصلاة والواجبات والتحديات التعليمية. شغّل بعد v8.
create or replace function public.submit_quiz(p_quiz text,p_child text,p_answers integer[]) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;q jsonb;question jsonb;v_child text;day text;correct_count integer:=0;total_count integer;idx integer:=1;score integer;age integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;
 if not found then raise exception 'Membership required' using errcode='42501';end if;
 v_child:=case when m.role='child' then m.child_id else p_child end;
 if m.role='child' and p_child is not null and p_child<>m.child_id then raise exception 'Own child only' using errcode='42501';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select (c->>'age')::integer into age from jsonb_array_elements(d->'children') c where c->>'id'=v_child;
 if not found then raise exception 'Unknown child';end if;
 select entry into q from jsonb_array_elements(d->'quizzes') entry where entry->>'id'=p_quiz;
 if not found then raise exception 'Unknown quiz';end if;
 if (q ? 'min_age' and age<(q->>'min_age')::integer) or (q ? 'max_age' and age>(q->>'max_age')::integer) then raise exception 'Quiz age mismatch';end if;
 total_count:=jsonb_array_length(q->'questions');day:=(now() at time zone 'Asia/Amman')::date::text;
 if p_answers is null or total_count<1 or cardinality(p_answers)<>total_count or array_ndims(p_answers)<>1 or array_lower(p_answers,1)<>1 or exists(select 1 from unnest(p_answers) a where a is null or a not between 0 and 2) then raise exception 'Invalid answers';end if;
 if exists(select 1 from jsonb_array_elements(d->'attempts') a where a->>'child'=v_child and a->>'quiz'=p_quiz and a->>'date'=day) then raise sqlstate 'PT409' using message='Quiz already counted today';end if;
 for question in select value from jsonb_array_elements(q->'questions') loop
  if p_answers[idx]=(question->>'correct')::integer then correct_count:=correct_count+1;end if;idx:=idx+1;
 end loop;
 score:=round((q->>'points')::numeric*correct_count/total_count)::integer;
 d:=jsonb_set(d,'{attempts}',coalesce(d->'attempts','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',v_child,'quiz',p_quiz,'name',q->>'name','date',day,'correct',correct_count,'total',total_count,'points',score)));
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'إكمال اختبار',v_child,q->>'name');
end $$;
revoke all on function public.submit_quiz(text,text,integer[]) from public,anon;
grant execute on function public.submit_quiz(text,text,integer[]) to authenticated;

-- Append starter content only when its ID does not exist. Keep family customizations intact.
do $seed$
declare f record;d jsonb;entry jsonb;changed boolean;
begin
 for f in select owner_id,data from public.family_state for update loop
  d:=f.data;changed:=false;
  for entry in select value from jsonb_array_elements('[{"id": "homework", "name": "حل الواجبات", "points": [0, 2, 4]}, {"id": "prayer_fajr", "name": "صلاة الفجر", "labels": ["في وقتها", "جماعة", "قضاء"], "points": [3, 5, 1]}, {"id": "prayer_dhuhr", "name": "صلاة الظهر", "labels": ["في وقتها", "جماعة", "قضاء"], "points": [3, 5, 1]}, {"id": "prayer_asr", "name": "صلاة العصر", "labels": ["في وقتها", "جماعة", "قضاء"], "points": [3, 5, 1]}, {"id": "prayer_maghrib", "name": "صلاة المغرب", "labels": ["في وقتها", "جماعة", "قضاء"], "points": [3, 5, 1]}, {"id": "prayer_isha", "name": "صلاة العشاء", "labels": ["في وقتها", "جماعة", "قضاء"], "points": [3, 5, 1]}]'::jsonb) loop
   if not exists(select 1 from jsonb_array_elements(d->'criteria') old where old->>'id'=entry->>'id') then d:=jsonb_set(d,'{criteria}',(d->'criteria')||jsonb_build_array(entry));changed:=true;end if;
  end loop;
  for entry in select value from jsonb_array_elements('[{"id": "starter_general", "name": "تحدي المعلومات العامة", "category": "معلومات عامة", "min_age": 8, "max_age": 18, "points": 10, "questions": [{"text": "أي كوكب نعيش عليه؟", "options": ["المريخ", "الأرض", "زحل"], "correct": 1}, {"text": "ما عاصمة الأردن؟", "options": ["عمّان", "العقبة", "إربد"], "correct": 0}, {"text": "أي عضو نستخدمه للسمع؟", "options": ["العين", "اليد", "الأذن"], "correct": 2}, {"text": "كم عدد أيام الأسبوع؟", "options": ["خمسة", "سبعة", "تسعة"], "correct": 1}]}, {"id": "starter_sport", "name": "تحدي الرياضة", "category": "رياضة", "min_age": 8, "max_age": 18, "points": 10, "questions": [{"text": "كم لاعبًا يبدأ بهم فريق كرة القدم داخل الملعب؟", "options": ["٩", "١١", "١٣"], "correct": 1}, {"text": "أي رياضة تُمارَس في الماء؟", "options": ["السباحة", "التنس", "الجري"], "correct": 0}, {"text": "أي أداة تُستخدم في التنس؟", "options": ["مضرب", "دراجة", "قفاز ملاكمة"], "correct": 0}, {"text": "أي نشاط يقوّي مهارة ركوب الدراجة؟", "options": ["القراءة", "الرسم", "التوازن"], "correct": 2}]}, {"id": "starter_math", "name": "تحدي الرياضيات", "category": "رياضيات", "min_age": 8, "max_age": 18, "points": 10, "questions": [{"text": "ما ناتج ٧ × ٦؟", "options": ["٣٦", "٤٢", "٤٨"], "correct": 1}, {"text": "ما نصف العدد ٥٠؟", "options": ["٢٠", "٢٥", "٣٠"], "correct": 1}, {"text": "ما ناتج ١٢٠ ÷ ١٠؟", "options": ["١٢", "١٠٢", "٢١"], "correct": 0}, {"text": "كم ضلعًا للمثلث؟", "options": ["٤", "٥", "٣"], "correct": 2}]}, {"id": "starter_english", "name": "تحدي اللغة الإنجليزية", "category": "إنجليزي", "min_age": 8, "max_age": 18, "points": 10, "questions": [{"text": "ما معنى Book؟", "options": ["كتاب", "قلم", "باب"], "correct": 0}, {"text": "أكمل: She ___ a student.", "options": ["are", "is", "am"], "correct": 1}, {"text": "ما جمع child؟", "options": ["childs", "childes", "children"], "correct": 2}, {"text": "ما عكس hot؟", "options": ["cold", "big", "new"], "correct": 0}]}, {"id": "starter_junior", "name": "تحدي الصغار: ألوان وأعداد", "category": "للمبتدئين", "min_age": 4, "max_age": 7, "points": 6, "questions": [{"text": "كم يساوي ١ + ١؟", "options": ["١", "٢", "٣"], "correct": 1}, {"text": "ما لون الموز الناضج عادةً؟", "options": ["أزرق", "بنفسجي", "أصفر"], "correct": 2}, {"text": "أي حيوان يقول مياو؟", "options": ["القطة", "الحصان", "البقرة"], "correct": 0}]}]'::jsonb) loop
   if not exists(select 1 from jsonb_array_elements(d->'quizzes') old where old->>'id'=entry->>'id') then d:=jsonb_set(d,'{quizzes}',(d->'quizzes')||jsonb_build_array(entry));changed:=true;end if;
  end loop;
  if changed then update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=f.owner_id;end if;
 end loop;
end $seed$;
-- migration-v10.sql
-- حذف معيار من التقييم الجديد مع حفظ السجل. شغّل بعد v9.
create or replace function public.delete_criterion(p_criterion text,p_revision bigint) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;c jsonb;rev bigint;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';
 if not found then raise exception 'Parent required' using errcode='42501';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 select entry into c from jsonb_array_elements(d->'criteria') entry where entry->>'id'=p_criterion and not coalesce((entry->>'archived')::boolean,false);
 if not found then raise exception 'Unknown criterion';end if;
 -- Retain the ID, name and historical points; also prevents seed migrations reviving it.
 d:=jsonb_set(d,'{criteria}',(select jsonb_agg(case when entry->>'id'=p_criterion then entry||jsonb_build_object('archived',true) else entry end) from jsonb_array_elements(d->'criteria') entry));
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 update public.point_requests set status='rejected',review_note='تم حذف المعيار من التقييم الجديد',reviewed_at=now() where owner_id=m.owner_id and criterion_id=p_criterion and status='pending';
 perform public.log_family_event(m.owner_id,'حذف معيار',null,c->>'name');
end $$;
revoke all on function public.delete_criterion(text,bigint) from public,anon;
grant execute on function public.delete_criterion(text,bigint) to authenticated;
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
 if not exists(select 1 from jsonb_array_elements(d->'criteria') c where c->>'id'=p_criterion and not coalesce((c->>'archived')::boolean,false) and (c->>'assigned_child' is null or c->>'assigned_child'=m.child_id)) then raise exception 'Unknown criterion'; end if;
 insert into public.point_requests(owner_id,requester,child_id,criterion_id,day,level,note)
 values(m.owner_id,m.user_id,m.child_id,p_criterion,p_day,p_level,p_note)
 on conflict(owner_id,child_id,criterion_id,day) do update set level=excluded.level,note=excluded.note,status='pending',review_note='',reviewed_at=null
 where point_requests.requester=excluded.requester;
 if not found then raise sqlstate 'PT409' using message='Already approved'; end if;
end $$;
revoke all on function public.submit_point_request(text,date,integer,text) from public,anon;
grant execute on function public.submit_point_request(text,date,integer,text) to authenticated;



-- migration-v11.sql
-- قوائم المكافآت وبنود الخصم. شغّل بعد v10.
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

-- migration-v12.sql
-- ألعاب عائلية بمراحل ونقاط يومية محفوظة على الخادم. شغّل بعد v11.
create table if not exists public.family_game_settings(owner_id uuid primary key references auth.users(id) on delete cascade,daily_cap integer not null default 20 check(daily_cap between 0 and 100),max_difficulty integer not null default 3 check(max_difficulty between 1 and 3),enabled boolean not null default true);
create table if not exists public.family_game_sessions(id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id) on delete cascade,game text not null check(game in ('memory','space')),difficulty integer not null check(difficulty between 1 and 3),stage integer not null check(stage between 1 and 5),participants text[] not null,status text not null default 'active' check(status in ('active','completed','failed')),data jsonb not null,revision bigint not null default 0,created_at timestamptz not null default now());
create index if not exists game_sessions_family on public.family_game_sessions(owner_id,created_at desc);
create table if not exists public.family_game_completions(id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id) on delete cascade,child_id text not null,game text not null,difficulty integer not null,stage integer not null,day date not null,points integer not null check(points between 0 and 100),session_id uuid,created_at timestamptz not null default now(),unique(owner_id,child_id,game,difficulty,stage,day));
alter table public.family_game_settings enable row level security;
alter table public.family_game_sessions enable row level security;
alter table public.family_game_completions enable row level security;
revoke all on public.family_game_settings,public.family_game_sessions,public.family_game_completions from anon,authenticated;
-- Private session data includes the hidden deck and correct answers. Only filtered RPCs expose it.
create or replace function public.game_question(p_age integer,p_difficulty integer,p_stage integer,p_index integer) returns jsonb language plpgsql set search_path='' as $$
declare a integer;b integer;answer integer;label text;options jsonb;slot integer;
begin
 a:=1+floor(random()*(case when p_age<8 then 3+p_stage else 7+p_stage*3 end))::integer;
 b:=1+floor(random()*(case when p_age<8 then 3 else 5+p_stage end))::integer;
 if p_age>=8 and p_difficulty>=2 and p_index%2=0 then answer:=a*b;label:=a||' × '||b||' = ؟';
 elsif p_age>=8 and p_difficulty=3 then answer:=a+b;label:='ما العدد المفقود؟ '||a||' + ؟ = '||answer;answer:=b;
 else answer:=a+b;label:=a||' + '||b||' = ؟';end if;
 slot:=floor(random()*3)::integer;
 select jsonb_agg(case when n=slot then answer else answer+1+((n-slot+3)%3) end order by n) into options from generate_series(0,2) n;
 return jsonb_build_object('text',label,'options',options,'correct',slot);
end $$;
revoke all on function public.game_question(integer,integer,integer,integer) from public,anon,authenticated;

create or replace function public.game_overview() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg jsonb;roster jsonb;rooms jsonb;progress jsonb;v_day date:=(now() at time zone 'Asia/Amman')::date;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('daily_cap',daily_cap,'max_difficulty',max_difficulty,'enabled',enabled) into cfg from public.family_game_settings where owner_id=m.owner_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',c->>'id','name',c->>'name','age',c->'age')),'[]') into roster from public.family_state f,jsonb_array_elements(f.data->'children') c where f.owner_id=m.owner_id and (m.role='parent' or c->>'id'=m.child_id);
 select coalesce(jsonb_agg(r order by r->>'created_at' desc),'[]') into rooms from(select jsonb_build_object('id',id,'game',game,'difficulty',difficulty,'stage',stage,'status',status,'created_at',created_at) r from public.family_game_sessions where owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) order by created_at desc limit 15) x;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',last_day,'points',points)),'[]') into progress from(select child_id,game,difficulty,stage,max(day) as last_day,coalesce(sum(points) filter(where day=v_day),0) points from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) group by child_id,game,difficulty,stage) compact;
 return jsonb_build_object('settings',coalesce(cfg,'{"daily_cap":20,"max_difficulty":3,"enabled":true}'::jsonb),'children',roster,'sessions',rooms,'progress',progress,'day',v_day);
end $$;
revoke all on function public.game_overview() from public,anon;grant execute on function public.game_overview() to authenticated;

create or replace function public.configure_games(p_cap integer,p_max integer,p_enabled boolean) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_cap is null or p_cap not between 0 and 100 or p_max is null or p_max not between 1 and 3 or p_enabled is null then raise exception 'Invalid settings';end if;
 insert into public.family_game_settings(owner_id,daily_cap,max_difficulty,enabled) values(m.owner_id,p_cap,p_max,p_enabled) on conflict(owner_id) do update set daily_cap=excluded.daily_cap,max_difficulty=excluded.max_difficulty,enabled=excluded.enabled;
 perform public.log_family_event(m.owner_id,'إعدادات الألعاب',null,'الحد اليومي: '||p_cap||'، أعلى صعوبة: '||p_max);
end $$;
revoke all on function public.configure_games(integer,integer,boolean) from public,anon;grant execute on function public.configure_games(integer,integer,boolean) to authenticated;

create or replace function public.start_game(p_game text,p_difficulty integer,p_stage integer,p_children text[]) returns uuid language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg public.family_game_settings;f jsonb;d jsonb;deck jsonb;players jsonb:='[]';questions jsonb;child text;c jsonb;i integer;pairs integer;sid uuid;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 if p_game is null or p_game not in ('memory','space') or p_difficulty is null or p_difficulty not between 1 and 3 or p_stage is null or p_stage not between 1 and 5 then raise exception 'Invalid stage';end if;
 select data into f from public.family_state where owner_id=m.owner_id for update;
 select * into cfg from public.family_game_settings where owner_id=m.owner_id;
 if coalesce(cfg.enabled,true)=false or p_difficulty>coalesce(cfg.max_difficulty,3) then raise exception 'Game disabled or difficulty restricted';end if;
 if p_children is null or cardinality(p_children) is null or cardinality(p_children) not between 1 and 6 or array_ndims(p_children)<>1 or exists(select 1 from unnest(p_children) id where id is null) or (select count(distinct id) from unnest(p_children) id)<>cardinality(p_children) then raise exception 'Select players';end if;
 if m.role='child' and (p_game<>'memory' or cardinality(p_children)<>1 or p_children[1]<>m.child_id) then raise exception 'Own memory game only; a parent starts team missions' using errcode='42501';end if;
 if (p_game='memory' and cardinality(p_children)<>1) or (p_game='space' and cardinality(p_children)<2) then raise exception 'Invalid crew size';end if;
 foreach child in array p_children loop
  select value into c from jsonb_array_elements(f->'children') where value->>'id'=child;if not found then raise exception 'Unknown child';end if;
  if p_stage>1 and not exists(select 1 from public.family_game_completions where owner_id=m.owner_id and child_id=child and game=p_game and difficulty=p_difficulty and stage=p_stage-1) then raise exception 'Finish previous stage for every player first';end if;
 end loop;
 update public.family_game_sessions set status='failed' where owner_id=m.owner_id and status='active' and created_at<now()-interval '4 hours';
 if p_game='memory' then update public.family_game_sessions set status='failed' where owner_id=m.owner_id and game='memory' and status='active' and participants=p_children;end if;
 if(select count(*) from public.family_game_sessions where owner_id=m.owner_id and status='active')>=10 then raise exception 'Too many active games';end if;
 if p_game='memory' then
  pairs:=p_stage+p_difficulty+1;
  select jsonb_agg(v order by random()) into deck from(select n v from generate_series(0,pairs-1) n cross join generate_series(1,2) dup) cards;
  d:=jsonb_build_object('deck',deck,'matched','[]'::jsonb,'open','[]'::jsonb,'moves',0,'limit',case when p_difficulty=1 then 0 when p_difficulty=2 then pairs*4 else pairs*3 end);
 else
  foreach child in array p_children loop
   select value into c from jsonb_array_elements(f->'children') where value->>'id'=child;questions:='[]';
   for i in 1..(2+p_stage) loop questions:=questions||jsonb_build_array(public.game_question((c->>'age')::integer,p_difficulty,p_stage,i));end loop;
   players:=players||jsonb_build_array(jsonb_build_object('child',child,'name',c->>'name','index',0,'questions',questions));
  end loop;
  d:=jsonb_build_object('players',players);
 end if;
 insert into public.family_game_sessions(owner_id,game,difficulty,stage,participants,data) values(m.owner_id,p_game,p_difficulty,p_stage,p_children,d) returning id into sid;return sid;
end $$;
revoke all on function public.start_game(text,integer,integer,text[]) from public,anon;grant execute on function public.start_game(text,integer,integer,text[]) to authenticated;

create or replace function public.game_view(p_session uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_game_sessions;d jsonb;cards jsonb;players jsonb;awards jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select * into s from public.family_game_sessions where id=p_session and owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants));if not found then raise exception 'Game access denied' using errcode='42501';end if;
 if s.game='memory' then
  select jsonb_agg(case when s.data->'matched' @> jsonb_build_array(idx-1) or s.data->'open' @> jsonb_build_array(idx-1) then val else 'null'::jsonb end order by idx) into cards from jsonb_array_elements(s.data->'deck') with ordinality t(val,idx);
  d:=jsonb_build_object('cards',cards,'matched',s.data->'matched','open',s.data->'open','moves',s.data->'moves','limit',s.data->'limit');
 else
  select jsonb_agg(jsonb_build_object('child',p->>'child','name',p->>'name','index',p->'index','total',jsonb_array_length(p->'questions'),'question',case when m.role='parent' or p->>'child'=m.child_id then (p->'questions'->((p->>'index')::integer))-'correct' else null end)) into players from jsonb_array_elements(s.data->'players') p;
  d:=jsonb_build_object('players',players);
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'points',points)),'[]') into awards from public.family_game_completions where session_id=s.id and owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id);
 return jsonb_build_object('id',s.id,'game',s.game,'difficulty',s.difficulty,'stage',s.stage,'participants',s.participants,'status',s.status,'revision',s.revision,'data',d,'awards',awards);
end $$;
revoke all on function public.game_view(uuid) from public,anon;grant execute on function public.game_view(uuid) to authenticated;

-- Only validated server completion can call this award helper. It is not a public API.
create or replace function public.award_game(p_session uuid) returns void language plpgsql security definer set search_path='' as $$
declare s public.family_game_sessions;d jsonb;child text;cap integer;used integer;amount integer;score integer;total integer;cid uuid;v_day date:=(now() at time zone 'Asia/Amman')::date;title text;
begin
 select * into s from public.family_game_sessions where id=p_session;if s.status<>'completed' then raise exception 'Game incomplete';end if;
 select data into d from public.family_state where owner_id=s.owner_id for update;
 select daily_cap into cap from public.family_game_settings where owner_id=s.owner_id;cap:=coalesce(cap,20);score:=s.difficulty+s.stage;
 title:=case when s.game='memory' then 'ذاكرة الصور' else 'مهمة الفضاء' end||' — مرحلة '||s.stage||' — صعوبة '||s.difficulty;
 foreach child in array s.participants loop
  select coalesce(sum(points),0) into used from public.family_game_completions where owner_id=s.owner_id and child_id=child and day=v_day;
  amount:=greatest(0,least(score,cap-used));cid:=null;
  insert into public.family_game_completions(owner_id,child_id,game,difficulty,stage,day,points,session_id) values(s.owner_id,child,s.game,s.difficulty,s.stage,v_day,amount,s.id) on conflict(owner_id,child_id,game,difficulty,stage,day) do nothing returning id into cid;
  if cid is not null then
   total:=case when s.game='memory' then jsonb_array_length(s.data->'deck')/2 else 2+s.stage end;
   d:=jsonb_set(d,'{attempts}',(d->'attempts')||jsonb_build_array(jsonb_build_object('id',cid,'child',child,'quiz','game_'||s.game||'_'||s.difficulty||'_'||s.stage,'kind','game','name',title,'date',v_day::text,'correct',total,'total',total,'points',amount)));
   perform public.log_family_event(s.owner_id,'إكمال مرحلة لعبة',child,title||' — '||amount||' نقطة');
  end if;
 end loop;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=s.owner_id;
end $$;
revoke all on function public.award_game(uuid) from public,anon,authenticated;

create or replace function public.game_step(p_session uuid,p_child text,p_choice integer,p_revision bigint,p_question integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_game_sessions;d jsonb;open_cards jsonb;matched jsonb;first_card integer;moves integer;limit_moves integer;players jsonb:='[]';player jsonb;question jsonb;target text;correct_answer boolean:=false;complete boolean:=false;new_status text:='active';
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 -- Serialize family writes before the game lock, same order as starts/deletions/ledger writes.
 perform 1 from public.family_state where owner_id=m.owner_id for update;
 select * into s from public.family_game_sessions where id=p_session and owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) for update;
 if not found then raise exception 'Game access denied' using errcode='42501';end if;
 if s.status<>'active' then raise sqlstate 'PT409' using message='Game no longer active';end if;
 if s.created_at<now()-interval '4 hours' then raise exception 'Game expired; start again';end if;
 if exists(select 1 from public.family_game_settings where owner_id=m.owner_id and (not enabled or max_difficulty<s.difficulty)) then raise exception 'Game disabled';end if;
 d:=s.data;
 if s.game='memory' then
  if s.revision is distinct from p_revision then raise sqlstate 'PT409' using message='Game revision conflict';end if;
  if p_choice is null or p_choice<0 or p_choice>=jsonb_array_length(d->'deck') then raise exception 'Invalid card';end if;
  open_cards:=d->'open';matched:=d->'matched';moves:=(d->>'moves')::integer;limit_moves:=(d->>'limit')::integer;
  if jsonb_array_length(open_cards)=2 then open_cards:='[]';end if;
  if matched @> jsonb_build_array(p_choice) or open_cards @> jsonb_build_array(p_choice) then raise exception 'Card already open';end if;
  open_cards:=open_cards||jsonb_build_array(p_choice);
  if jsonb_array_length(open_cards)=2 then
   moves:=moves+1;first_card:=(open_cards->>0)::integer;
   if d->'deck'->first_card=d->'deck'->p_choice then matched:=matched||open_cards;open_cards:='[]';end if;
   complete:=jsonb_array_length(matched)=jsonb_array_length(d->'deck');
   if not complete and limit_moves>0 and moves>=limit_moves then new_status:='failed';end if;
  end if;
  d:=d||jsonb_build_object('open',open_cards,'matched',matched,'moves',moves);
 else
  target:=case when m.role='child' then m.child_id else p_child end;
  if target is null or not(target=any(s.participants)) or (m.role='child' and p_child is not null and p_child<>m.child_id) then raise exception 'Own question only' using errcode='42501';end if;
  if p_choice is null or p_choice not between 0 and 2 then raise exception 'Invalid answer';end if;
  for player in select value from jsonb_array_elements(d->'players') loop
   if player->>'child'=target then
    if (player->>'index')::integer is distinct from p_question then raise sqlstate 'PT409' using message='Question already changed';end if;
    question:=player->'questions'->p_question;if question is null then raise exception 'Player completed';end if;
    correct_answer:=p_choice=(question->>'correct')::integer;
    if correct_answer then player:=jsonb_set(player,'{index}',to_jsonb(p_question+1));end if;
   end if;
   players:=players||jsonb_build_array(player);
  end loop;
  d:=jsonb_set(d,'{players}',players);
  complete:=not exists(select 1 from jsonb_array_elements(players) p where (p->>'index')::integer<jsonb_array_length(p->'questions'));
 end if;
 if complete then new_status:='completed';end if;
 update public.family_game_sessions set data=d,status=new_status,revision=revision+1 where id=s.id;
 if complete then perform public.award_game(s.id);end if;
 return jsonb_build_object('correct',correct_answer,'view',public.game_view(s.id));
end $$;
revoke all on function public.game_step(uuid,text,integer,bigint,integer) from public,anon;grant execute on function public.game_step(uuid,text,integer,bigint,integer) to authenticated;

create or replace function public.purge_child_data(p_owner uuid,p_child text) returns void language plpgsql security definer set search_path='' as $$
declare d jsonb;k text;
begin
 select data into d from public.family_state where owner_id=p_owner for update;if d is null then return;end if;
 d:=jsonb_set(d,'{children}',coalesce((select jsonb_agg(c) from jsonb_array_elements(d->'children') c where c->>'id'<>p_child),'[]'));
 foreach k in array array['evaluations','attempts','redemptions','adjustments','resetArchive','encouragements'] loop
  d:=jsonb_set(d,array[k],coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(d->k,'[]')) e where e->>'child' is distinct from p_child),'[]'));
 end loop;
 d:=jsonb_set(d,'{criteria}',coalesce((select jsonb_agg(c) from jsonb_array_elements(d->'criteria') c where c->>'assigned_child' is distinct from p_child),'[]'));
 delete from public.family_game_completions where owner_id=p_owner and child_id=p_child;
 delete from public.family_game_sessions where owner_id=p_owner and p_child=any(participants);
 delete from public.point_requests where owner_id=p_owner and child_id=p_child;
 delete from public.family_suggestions where owner_id=p_owner and child_id=p_child;
 delete from public.family_audit where owner_id=p_owner and child_id=p_child;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=p_owner;
end $$;
revoke all on function public.purge_child_data(uuid,text) from public,anon,authenticated;

-- migration-v13.sql
-- مشاركة أولياء الأمر بحساباتهم الحالية، دون إنشاء ملفات أطفال لهم.
-- Private roster: parent IDs use a namespace rejected by child-profile validation.
create or replace function public.game_roster(p_owner uuid) returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(player order by player->>'role',player->>'name'),'[]'::jsonb) from (
 select jsonb_build_object('id',c->>'id','name',c->>'name','age',c->'age','role','child') player
 from public.family_state f,jsonb_array_elements(f.data->'children') c where f.owner_id=p_owner
 union all
 select jsonb_build_object('id','parent:'||user_id::text,'name',display_name,'age',30,'role','parent')
 from public.family_members where owner_id=p_owner and role='parent' and active
 ) roster;
$$;
revoke all on function public.game_roster(uuid) from public,anon,authenticated;
create or replace function public.game_overview() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg jsonb;roster jsonb;rooms jsonb;progress jsonb;v_day date:=(now() at time zone 'Asia/Amman')::date;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('daily_cap',daily_cap,'max_difficulty',max_difficulty,'enabled',enabled) into cfg from public.family_game_settings where owner_id=m.owner_id;
 select coalesce(jsonb_agg(c),'[]') into roster from jsonb_array_elements(public.game_roster(m.owner_id)) c where m.role='parent' or c->>'id'=m.child_id;
 select coalesce(jsonb_agg(r order by r->>'created_at' desc),'[]') into rooms from(select jsonb_build_object('id',id,'game',game,'difficulty',difficulty,'stage',stage,'status',status,'created_at',created_at) r from public.family_game_sessions where owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) order by created_at desc limit 15) x;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',last_day,'points',points,'total_points',total_points)),'[]') into progress from(select child_id,game,difficulty,stage,max(day) as last_day,sum(points) total_points,coalesce(sum(points) filter(where day=v_day),0) points from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) group by child_id,game,difficulty,stage) compact;
 return jsonb_build_object('settings',coalesce(cfg,'{"daily_cap":20,"max_difficulty":3,"enabled":true}'::jsonb),'children',roster,'sessions',rooms,'progress',progress,'day',v_day);
end $$;
revoke all on function public.game_overview() from public,anon;grant execute on function public.game_overview() to authenticated;

create or replace function public.start_game(p_game text,p_difficulty integer,p_stage integer,p_children text[]) returns uuid language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg public.family_game_settings;f jsonb;d jsonb;deck jsonb;players jsonb:='[]';questions jsonb;child text;c jsonb;i integer;pairs integer;sid uuid;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 if p_game is null or p_game not in ('memory','space') or p_difficulty is null or p_difficulty not between 1 and 3 or p_stage is null or p_stage not between 1 and 5 then raise exception 'Invalid stage';end if;
 select data into f from public.family_state where owner_id=m.owner_id for update;
 select * into cfg from public.family_game_settings where owner_id=m.owner_id;
 if coalesce(cfg.enabled,true)=false or p_difficulty>coalesce(cfg.max_difficulty,3) then raise exception 'Game disabled or difficulty restricted';end if;
 if p_children is null or cardinality(p_children) is null or cardinality(p_children) not between 1 and 6 or array_ndims(p_children)<>1 or exists(select 1 from unnest(p_children) id where id is null) or (select count(distinct id) from unnest(p_children) id)<>cardinality(p_children) then raise exception 'Select players';end if;
 if m.role='child' and (p_game<>'memory' or cardinality(p_children)<>1 or p_children[1]<>m.child_id) then raise exception 'Own memory game only; a parent starts team missions' using errcode='42501';end if;
 if (p_game='memory' and cardinality(p_children)<>1) or (p_game='space' and cardinality(p_children)<2) then raise exception 'Invalid crew size';end if;
 foreach child in array p_children loop
  select value into c from jsonb_array_elements(public.game_roster(m.owner_id)) where value->>'id'=child;if not found then raise exception 'Unknown player';end if;
  if p_stage>1 and not exists(select 1 from public.family_game_completions where owner_id=m.owner_id and child_id=child and game=p_game and difficulty=p_difficulty and stage=p_stage-1) then raise exception 'Finish previous stage for every player first';end if;
 end loop;
 update public.family_game_sessions set status='failed' where owner_id=m.owner_id and status='active' and created_at<now()-interval '4 hours';
 if p_game='memory' then update public.family_game_sessions set status='failed' where owner_id=m.owner_id and game='memory' and status='active' and participants=p_children;end if;
 if(select count(*) from public.family_game_sessions where owner_id=m.owner_id and status='active')>=10 then raise exception 'Too many active games';end if;
 if p_game='memory' then
  pairs:=p_stage+p_difficulty+1;
  select jsonb_agg(v order by random()) into deck from(select n v from generate_series(0,pairs-1) n cross join generate_series(1,2) dup) cards;
  d:=jsonb_build_object('deck',deck,'matched','[]'::jsonb,'open','[]'::jsonb,'moves',0,'limit',case when p_difficulty=1 then 0 when p_difficulty=2 then pairs*4 else pairs*3 end);
 else
  foreach child in array p_children loop
   select value into c from jsonb_array_elements(public.game_roster(m.owner_id)) where value->>'id'=child;questions:='[]';
   for i in 1..(2+p_stage) loop questions:=questions||jsonb_build_array(public.game_question((c->>'age')::integer,p_difficulty,p_stage,i));end loop;
   players:=players||jsonb_build_array(jsonb_build_object('child',child,'name',c->>'name','index',0,'questions',questions));
  end loop;
  d:=jsonb_build_object('players',players);
 end if;
 insert into public.family_game_sessions(owner_id,game,difficulty,stage,participants,data) values(m.owner_id,p_game,p_difficulty,p_stage,p_children,d) returning id into sid;return sid;
end $$;
revoke all on function public.start_game(text,integer,integer,text[]) from public,anon;grant execute on function public.start_game(text,integer,integer,text[]) to authenticated;

create or replace function public.award_game(p_session uuid) returns void language plpgsql security definer set search_path='' as $$
declare s public.family_game_sessions;d jsonb;child text;cap integer;used integer;amount integer;score integer;total integer;cid uuid;v_day date:=(now() at time zone 'Asia/Amman')::date;title text;
begin
 select * into s from public.family_game_sessions where id=p_session;if s.status<>'completed' then raise exception 'Game incomplete';end if;
 select data into d from public.family_state where owner_id=s.owner_id for update;
 select daily_cap into cap from public.family_game_settings where owner_id=s.owner_id;cap:=coalesce(cap,20);score:=s.difficulty+s.stage;
 title:=case when s.game='memory' then 'ذاكرة الصور' else 'مهمة الفضاء' end||' — مرحلة '||s.stage||' — صعوبة '||s.difficulty;
 foreach child in array s.participants loop
  select coalesce(sum(points),0) into used from public.family_game_completions where owner_id=s.owner_id and child_id=child and day=v_day;
  amount:=greatest(0,least(score,cap-used));cid:=null;
  insert into public.family_game_completions(owner_id,child_id,game,difficulty,stage,day,points,session_id) values(s.owner_id,child,s.game,s.difficulty,s.stage,v_day,amount,s.id) on conflict(owner_id,child_id,game,difficulty,stage,day) do nothing returning id into cid;
  if cid is not null then
   total:=case when s.game='memory' then jsonb_array_length(s.data->'deck')/2 else 2+s.stage end;
   if child not like 'parent:%' then
   d:=jsonb_set(d,'{attempts}',(d->'attempts')||jsonb_build_array(jsonb_build_object('id',cid,'child',child,'quiz','game_'||s.game||'_'||s.difficulty||'_'||s.stage,'kind','game','name',title,'date',v_day::text,'correct',total,'total',total,'points',amount)));
   end if;
   perform public.log_family_event(s.owner_id,'إكمال مرحلة لعبة',child,title||' — '||amount||' نقطة');
  end if;
 end loop;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=s.owner_id;
end $$;
revoke all on function public.award_game(uuid) from public,anon,authenticated;

create or replace function public.on_family_auth_delete() returns trigger language plpgsql security definer set search_path='' as $$
declare m public.family_members;player_id text;
begin
 select * into m from public.family_members where user_id=old.id;
 if found then
  if m.role='child' then perform public.purge_child_data(m.owner_id,m.child_id);
  else
   player_id:='parent:'||old.id::text;
   perform 1 from public.family_state where owner_id=m.owner_id for update;
   delete from public.family_game_completions where owner_id=m.owner_id and child_id=player_id;
   delete from public.family_game_sessions where owner_id=m.owner_id and player_id=any(participants);
  end if;
 end if;
 return old;
end $$;
revoke all on function public.on_family_auth_delete() from public,anon,authenticated;

-- migration-v14.sql
-- تصفير نقاط الألعاب دون حذف المراحل أو تجاوز حد مكافآت اليوم. شغّل بعد v13.
alter table public.family_game_completions add column if not exists reset_at timestamptz;
create or replace function public.game_overview() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg jsonb;roster jsonb;rooms jsonb;progress jsonb;v_day date:=(now() at time zone 'Asia/Amman')::date;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('daily_cap',daily_cap,'max_difficulty',max_difficulty,'enabled',enabled) into cfg from public.family_game_settings where owner_id=m.owner_id;
 select coalesce(jsonb_agg(c),'[]') into roster from jsonb_array_elements(public.game_roster(m.owner_id)) c where m.role='parent' or c->>'id'=m.child_id;
 select coalesce(jsonb_agg(r order by r->>'created_at' desc),'[]') into rooms from(select jsonb_build_object('id',id,'game',game,'difficulty',difficulty,'stage',stage,'status',status,'created_at',created_at) r from public.family_game_sessions where owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) order by created_at desc limit 15) x;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',last_day,'points',points,'total_points',total_points,'daily_used',daily_used)),'[]') into progress from(select child_id,game,difficulty,stage,max(day) as last_day,coalesce(sum(points) filter(where reset_at is null),0) total_points,coalesce(sum(points) filter(where day=v_day and reset_at is null),0) points,coalesce(sum(points) filter(where day=v_day),0) daily_used from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) group by child_id,game,difficulty,stage) compact;
 return jsonb_build_object('settings',coalesce(cfg,'{"daily_cap":20,"max_difficulty":3,"enabled":true}'::jsonb),'can_reset',public.has_family_permission(m.owner_id,'reset_points'),'revision',(select revision from public.family_state where owner_id=m.owner_id),'children',roster,'sessions',rooms,'progress',progress,'day',v_day);
end $$;
revoke all on function public.game_overview() from public,anon;grant execute on function public.game_overview() to authenticated;
create or replace function public.game_view(p_session uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_game_sessions;d jsonb;cards jsonb;players jsonb;awards jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select * into s from public.family_game_sessions where id=p_session and owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants));if not found then raise exception 'Game access denied' using errcode='42501';end if;
 if s.game='memory' then
  select jsonb_agg(case when s.data->'matched' @> jsonb_build_array(idx-1) or s.data->'open' @> jsonb_build_array(idx-1) then val else 'null'::jsonb end order by idx) into cards from jsonb_array_elements(s.data->'deck') with ordinality t(val,idx);
  d:=jsonb_build_object('cards',cards,'matched',s.data->'matched','open',s.data->'open','moves',s.data->'moves','limit',s.data->'limit');
 else
  select jsonb_agg(jsonb_build_object('child',p->>'child','name',p->>'name','index',p->'index','total',jsonb_array_length(p->'questions'),'question',case when m.role='parent' or p->>'child'=m.child_id then (p->'questions'->((p->>'index')::integer))-'correct' else null end)) into players from jsonb_array_elements(s.data->'players') p;
  d:=jsonb_build_object('players',players);
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'points',case when reset_at is null then points else 0 end,'reset',reset_at is not null)),'[]') into awards from public.family_game_completions where session_id=s.id and owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id);
 return jsonb_build_object('id',s.id,'game',s.game,'difficulty',s.difficulty,'stage',s.stage,'participants',s.participants,'status',s.status,'revision',s.revision,'data',d,'awards',awards);
end $$;
revoke all on function public.game_view(uuid) from public,anon;grant execute on function public.game_view(uuid) to authenticated;
create or replace function public.reset_game_points(p_player text,p_reason text,p_revision bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;removed jsonb;kept jsonb;entries jsonb;c jsonb;child text;available numeric;spent numeric;affected integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';
 if not found or not public.has_family_permission(m.owner_id,'reset_points') then raise exception 'Permission not granted' using errcode='42501';end if;
 if p_reason is null or length(trim(p_reason)) not between 1 and 300 then raise exception 'Invalid reason';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 if p_player is not null and not exists(select 1 from jsonb_array_elements(public.game_roster(m.owner_id)) r where r->>'id'=p_player) then raise exception 'Unknown player';end if;
 select coalesce(jsonb_agg(e) filter(where coalesce(e->>'kind','')='game' and (p_player is null or e->>'child'=p_player)),'[]'),
 coalesce(jsonb_agg(e) filter(where not(coalesce(e->>'kind','')='game' and (p_player is null or e->>'child'=p_player))),'[]') into removed,kept from jsonb_array_elements(d->'attempts') e;
 -- Check every affected child's remaining balance before changing any ledger or game record.
 for c in select value from jsonb_array_elements(d->'children') where p_player is null or value->>'id'=p_player loop
  child:=c->>'id';
  select coalesce(sum((e->>'points')::numeric),0) into available from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(kept) e union all select e from jsonb_array_elements(coalesce(d->'adjustments','[]')) e) ledger where e->>'child'=child;
  select coalesce(sum((r->>'cost')::numeric),0) into spent from jsonb_array_elements(d->'redemptions') r where r->>'child'=child;
  if available<spent then raise exception 'Game reset would reduce spent points';end if;
 end loop;
 d:=jsonb_set(d,'{attempts}',kept);
 for child in select distinct e->>'child' from jsonb_array_elements(removed) e loop
  select jsonb_agg(e) into entries from jsonb_array_elements(removed) e where e->>'child'=child;
  d:=jsonb_set(d,'{resetArchive}',coalesce(d->'resetArchive','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',child,'date',(now() at time zone 'Asia/Amman')::date::text,'kind','game_reset','note',trim(p_reason),'records',jsonb_build_object('attempts',entries))));
 end loop;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 -- Keep original awarded points for the daily cap and keep rows for unlocked stages / deduplication.
 update public.family_game_completions set reset_at=now() where owner_id=m.owner_id and reset_at is null and (p_player is null or child_id=p_player);
 get diagnostics affected=row_count;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تصفير نقاط الألعاب',p_player,case when p_player is null then 'جميع المشاركين' else p_player end||' — '||trim(p_reason)||' — سجلات: '||affected);
 return jsonb_build_object('reset_records',affected,'archived_attempts',jsonb_array_length(removed));
end $$;
revoke all on function public.reset_game_points(text,text,bigint) from public,anon;
grant execute on function public.reset_game_points(text,text,bigint) to authenticated;

-- migration-v15.sql
-- صور أدلة اختيارية، تخصيص الطفل، وعبارات التشجيع. شغّل بعد v14.
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
-- migration-v16.sql
-- رفض واضح وإعادة المقترحات وتعديل نصوصها مع منع الكتابة فوق تعديل أحدث.
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
-- migration-v17.sql
-- نقاط الألعاب تُعتمد من ولي الأمر، وتحويل الأمنية إلى بند خصم دون تطبيق الخصم.
-- Existing earned points remain approved; new completions explicitly start pending.
alter table public.family_game_completions add column if not exists approval_status text not null default 'approved' check(approval_status in ('pending','approved','rejected'));
alter table public.family_game_completions add column if not exists review_note text not null default '';
alter table public.family_game_completions add column if not exists reviewed_at timestamptz;
alter table public.family_game_completions add column if not exists reviewed_by uuid;
create or replace function public.game_overview() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg jsonb;roster jsonb;rooms jsonb;progress jsonb;requests jsonb;v_day date:=(now() at time zone 'Asia/Amman')::date;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('daily_cap',daily_cap,'max_difficulty',max_difficulty,'enabled',enabled) into cfg from public.family_game_settings where owner_id=m.owner_id;
 select coalesce(jsonb_agg(c),'[]') into roster from jsonb_array_elements(public.game_roster(m.owner_id)) c where m.role='parent' or c->>'id'=m.child_id;
 select coalesce(jsonb_agg(r order by r->>'created_at' desc),'[]') into rooms from(select jsonb_build_object('id',id,'game',game,'difficulty',difficulty,'stage',stage,'status',status,'created_at',created_at) r from public.family_game_sessions where owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) order by created_at desc limit 15) x;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',last_day,'points',points,'total_points',total_points,'daily_used',daily_used)),'[]') into progress from(select child_id,game,difficulty,stage,max(day) as last_day,coalesce(sum(points) filter(where reset_at is null and approval_status='approved'),0) total_points,coalesce(sum(points) filter(where day=v_day and reset_at is null and approval_status='approved'),0) points,coalesce(sum(points) filter(where day=v_day),0) daily_used from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) group by child_id,game,difficulty,stage) compact;
 select coalesce(jsonb_agg(r),'[]') into requests from(select jsonb_build_object('id',id,'child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',day,'points',points,'status',approval_status,'note',review_note,'reset',reset_at is not null) r from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) order by (approval_status='pending' and reset_at is null) desc,created_at desc limit 200) q;
 return jsonb_build_object('settings',coalesce(cfg,'{"daily_cap":20,"max_difficulty":3,"enabled":true}'::jsonb),'can_reset',public.has_family_permission(m.owner_id,'reset_points'),'revision',(select revision from public.family_state where owner_id=m.owner_id),'requests',requests,'children',roster,'sessions',rooms,'progress',progress,'day',v_day);
end $$;
revoke all on function public.game_overview() from public,anon;grant execute on function public.game_overview() to authenticated;
create or replace function public.game_view(p_session uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_game_sessions;d jsonb;cards jsonb;players jsonb;awards jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select * into s from public.family_game_sessions where id=p_session and owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants));if not found then raise exception 'Game access denied' using errcode='42501';end if;
 if s.game='memory' then
  select jsonb_agg(case when s.data->'matched' @> jsonb_build_array(idx-1) or s.data->'open' @> jsonb_build_array(idx-1) then val else 'null'::jsonb end order by idx) into cards from jsonb_array_elements(s.data->'deck') with ordinality t(val,idx);
  d:=jsonb_build_object('cards',cards,'matched',s.data->'matched','open',s.data->'open','moves',s.data->'moves','limit',s.data->'limit');
 else
  select jsonb_agg(jsonb_build_object('child',p->>'child','name',p->>'name','index',p->'index','total',jsonb_array_length(p->'questions'),'question',case when m.role='parent' or p->>'child'=m.child_id then (p->'questions'->((p->>'index')::integer))-'correct' else null end)) into players from jsonb_array_elements(s.data->'players') p;
  d:=jsonb_build_object('players',players);
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'points',case when reset_at is null then points else 0 end,'reset',reset_at is not null,'status',approval_status)),'[]') into awards from public.family_game_completions where session_id=s.id and owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id);
 return jsonb_build_object('id',s.id,'game',s.game,'difficulty',s.difficulty,'stage',s.stage,'participants',s.participants,'status',s.status,'revision',s.revision,'data',d,'awards',awards);
end $$;
revoke all on function public.game_view(uuid) from public,anon;grant execute on function public.game_view(uuid) to authenticated;
create or replace function public.award_game(p_session uuid) returns void language plpgsql security definer set search_path='' as $$
declare s public.family_game_sessions;child text;cap integer;used integer;amount integer;cid uuid;
begin
 select * into s from public.family_game_sessions where id=p_session;if s.status<>'completed' then raise exception 'Game incomplete';end if;
 perform 1 from public.family_state where owner_id=s.owner_id for update;
 select daily_cap into cap from public.family_game_settings where owner_id=s.owner_id;cap:=coalesce(cap,20);
 foreach child in array s.participants loop
  select coalesce(sum(points),0) into used from public.family_game_completions where owner_id=s.owner_id and child_id=child and day=(now() at time zone 'Asia/Amman')::date;
  amount:=greatest(0,least(s.difficulty+s.stage,cap-used));cid:=null;
  insert into public.family_game_completions(owner_id,child_id,game,difficulty,stage,day,points,session_id,approval_status) values(s.owner_id,child,s.game,s.difficulty,s.stage,(now() at time zone 'Asia/Amman')::date,amount,s.id,'pending') on conflict(owner_id,child_id,game,difficulty,stage,day) do nothing returning id into cid;
  if cid is not null then perform public.log_family_event(s.owner_id,'طلب نقاط لعبة',child,s.game||' — مرحلة '||s.stage||' — '||amount||' نقطة بانتظار ولي الأمر');end if;
 end loop;
 update public.family_state set revision=revision+1,updated_at=now() where owner_id=s.owner_id;
end $$;
revoke all on function public.award_game(uuid) from public,anon,authenticated;

create or replace function public.review_game_points(p_id uuid,p_approve boolean,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;r public.family_game_completions;d jsonb;total integer;title text;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_approve is null or p_note is null or length(p_note)>300 then raise exception 'Invalid review';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select * into r from public.family_game_completions where id=p_id and owner_id=m.owner_id for update;
 if not found or r.approval_status<>'pending' or r.reset_at is not null then raise sqlstate 'PT409' using message='Request already reviewed';end if;
 if not exists(select 1 from jsonb_array_elements(public.game_roster(m.owner_id)) c where c->>'id'=r.child_id) then raise exception 'Unknown player';end if;
 title:=case when r.game='memory' then 'ذاكرة الصور' else 'مهمة الفضاء' end||' — مرحلة '||r.stage||' — صعوبة '||r.difficulty;
 if p_approve and r.child_id not like 'parent:%' then
  total:=case when r.game='memory' then r.stage+r.difficulty+1 else 2+r.stage end;
  d:=jsonb_set(d,'{attempts}',coalesce(d->'attempts','[]')||jsonb_build_array(jsonb_build_object('id',r.id,'child',r.child_id,'quiz','game_'||r.game||'_'||r.difficulty||'_'||r.stage,'kind','game','name',title,'date',r.day::text,'correct',total,'total',total,'points',r.points,'note',trim(p_note))));
 end if;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_game_completions set approval_status=case when p_approve then 'approved' else 'rejected' end,review_note=trim(p_note),reviewed_at=now(),reviewed_by=m.user_id where id=r.id;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,case when p_approve then 'اعتماد نقاط لعبة' else 'رفض نقاط لعبة' end,r.child_id,title||' — '||r.points||' — '||trim(p_note));
end $$;
revoke all on function public.review_game_points(uuid,boolean,text) from public,anon;
grant execute on function public.review_game_points(uuid,boolean,text) to authenticated;

create or replace function public.reset_game_points(p_player text,p_reason text,p_revision bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;removed jsonb;kept jsonb;entries jsonb;c jsonb;child text;available numeric;spent numeric;affected integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';
 if not found or not public.has_family_permission(m.owner_id,'reset_points') then raise exception 'Permission not granted' using errcode='42501';end if;
 if p_reason is null or length(trim(p_reason)) not between 1 and 300 then raise exception 'Invalid reason';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 if p_player is not null and not exists(select 1 from jsonb_array_elements(public.game_roster(m.owner_id)) r where r->>'id'=p_player) then raise exception 'Unknown player';end if;
 select coalesce(jsonb_agg(e) filter(where coalesce(e->>'kind','')='game' and (p_player is null or e->>'child'=p_player)),'[]'),
 coalesce(jsonb_agg(e) filter(where not(coalesce(e->>'kind','')='game' and (p_player is null or e->>'child'=p_player))),'[]') into removed,kept from jsonb_array_elements(d->'attempts') e;
 -- Check every affected child's remaining balance before changing any ledger or game record.
 for c in select value from jsonb_array_elements(d->'children') where p_player is null or value->>'id'=p_player loop
  child:=c->>'id';
  select coalesce(sum((e->>'points')::numeric),0) into available from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(kept) e union all select e from jsonb_array_elements(coalesce(d->'adjustments','[]')) e) ledger where e->>'child'=child;
  select coalesce(sum((r->>'cost')::numeric),0) into spent from jsonb_array_elements(d->'redemptions') r where r->>'child'=child;
  if available<spent then raise exception 'Game reset would reduce spent points';end if;
 end loop;
 d:=jsonb_set(d,'{attempts}',kept);
 for child in select distinct e->>'child' from jsonb_array_elements(removed) e loop
  select jsonb_agg(e) into entries from jsonb_array_elements(removed) e where e->>'child'=child;
  d:=jsonb_set(d,'{resetArchive}',coalesce(d->'resetArchive','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',child,'date',(now() at time zone 'Asia/Amman')::date::text,'kind','game_reset','note',trim(p_reason),'records',jsonb_build_object('attempts',entries))));
 end loop;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 -- Keep original awarded points for the daily cap and keep rows for unlocked stages / deduplication.
 update public.family_game_completions set reset_at=now(),approval_status=case when approval_status='pending' then 'rejected' else approval_status end where owner_id=m.owner_id and reset_at is null and (p_player is null or child_id=p_player);
 get diagnostics affected=row_count;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تصفير نقاط الألعاب',p_player,case when p_player is null then 'جميع المشاركين' else p_player end||' — '||trim(p_reason)||' — سجلات: '||affected);
 return jsonb_build_object('reset_records',affected,'archived_attempts',jsonb_array_length(removed));
end $$;
revoke all on function public.reset_game_points(text,text,bigint) from public,anon;
grant execute on function public.reset_game_points(text,text,bigint) to authenticated;
create or replace function public.suggestion_to_deduction(p_id uuid,p_name text,p_description text,p_points integer,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;s public.family_suggestions;d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_name is null or length(trim(p_name)) not between 1 and 100 or p_description is null or length(p_description)>500 or p_points is null or p_points not between 1 and 1000 then raise exception 'Invalid deduction';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select * into s from public.family_suggestions where id=p_id and owner_id=m.owner_id and kind='reward' for update;
 if not found then raise exception 'Suggestion access denied' using errcode='42501';end if;
 if s.revision is distinct from p_revision then raise sqlstate 'PT409' using message='Suggestion changed';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(d->'deductionRules','[]')) r where r->>'source_suggestion'=s.id::text and not coalesce((r->>'archived')::boolean,false)) then raise exception 'Suggestion already linked to deduction';end if;
 d:=jsonb_set(d,'{deductionRules}',coalesce(d->'deductionRules','[]')||jsonb_build_array(jsonb_build_object('id',replace(gen_random_uuid()::text,'-',''),'name',trim(p_name),'description',p_description,'points',p_points,'source_suggestion',s.id::text)));
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'إضافة أمنية إلى بنود الخصم',s.child_id,trim(p_name)||' — '||p_points||' نقطة؛ دون خصم فعلي');
end $$;
revoke all on function public.suggestion_to_deduction(uuid,text,text,integer,bigint) from public,anon;
grant execute on function public.suggestion_to_deduction(uuid,text,text,integer,bigint) to authenticated;

notify pgrst,'reload schema';
-- migration-v18.sql
-- إخفاء طلب الإنجاز المرفوض بعد التأكيد، مع حفظ النقاط المعتمدة والسجل الإداري.
alter table public.point_requests add column if not exists deleted_at timestamptz;
alter table public.point_requests add column if not exists deleted_by uuid;
drop policy if exists request_read on public.point_requests;
create policy request_read on public.point_requests for select to authenticated using(deleted_at is null and ((requester=auth.uid() and public.has_active_membership()) or public.is_family_parent(owner_id)));
create or replace function public.delete_rejected_point_request(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;r public.point_requests;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;
 if not found then raise exception 'Membership required' using errcode='42501';end if;
 perform 1 from public.family_state where owner_id=m.owner_id for update;
 select * into r from public.point_requests where id=p_id and owner_id=m.owner_id for update;
 if not found or (m.role='child' and (r.requester<>m.user_id or r.child_id<>m.child_id)) then raise exception 'Request access denied' using errcode='42501';end if;
 if r.deleted_at is not null or r.status<>'rejected' then raise sqlstate 'PT409' using message='Only rejected requests can be deleted';end if;
 update public.point_requests set deleted_at=now(),deleted_by=m.user_id where id=r.id;
 perform public.log_family_event(m.owner_id,'حذف طلب إنجاز مرفوض',r.child_id,r.criterion_id||' — '||r.day::text);
end $$;
revoke all on function public.delete_rejected_point_request(uuid) from public,anon;
grant execute on function public.delete_rejected_point_request(uuid) to authenticated;
create or replace function public.submit_point_request(p_criterion text,p_day date,p_level integer,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare m public.family_members; d jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='child';
 if not found then raise exception 'Child account required' using errcode='42501'; end if;
 if p_day is null or p_day> (now() at time zone 'Asia/Amman')::date or p_level is null or p_level not between 0 and 2 or p_note is null or length(p_note)>300 then raise exception 'Invalid request'; end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 if not exists(select 1 from jsonb_array_elements(d->'criteria') c where c->>'id'=p_criterion and not coalesce((c->>'archived')::boolean,false) and (c->>'assigned_child' is null or c->>'assigned_child'=m.child_id)) then raise exception 'Unknown criterion'; end if;
 insert into public.point_requests(owner_id,requester,child_id,criterion_id,day,level,note)
 values(m.owner_id,m.user_id,m.child_id,p_criterion,p_day,p_level,p_note)
 on conflict(owner_id,child_id,criterion_id,day) do update set deleted_at=null,deleted_by=null,level=excluded.level,note=excluded.note,status='pending',review_note='',reviewed_at=null
 where point_requests.requester=excluded.requester;
 if not found then raise sqlstate 'PT409' using message='Already approved'; end if;
end $$;
revoke all on function public.submit_point_request(text,date,integer,text) from public,anon;
grant execute on function public.submit_point_request(text,date,integer,text) to authenticated;
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
 on conflict(owner_id,child_id,criterion_id,day) do update set deleted_at=null,deleted_by=null,level=excluded.level,note=excluded.note,evidence=excluded.evidence,status='pending',review_note='',reviewed_at=null
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
 if not found or r.status<>'pending' or r.deleted_at is not null then raise sqlstate 'PT409' using message='Request already reviewed'; end if;
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
notify pgrst,'reload schema';
-- migration-v19.sql
-- إنجاز واحد يوميًا افتراضيًا، تكرار مضبوط، تحويل المعايير، وتصفير الألعاب القديمة.
alter table public.point_requests add column if not exists occurrence integer not null default 1 check(occurrence>0);
alter table public.point_requests drop constraint if exists point_requests_owner_id_child_id_criterion_id_day_key;
create unique index if not exists point_request_occurrence on public.point_requests(owner_id,child_id,criterion_id,day,occurrence);
create or replace function public.submit_achievement(p_criterion text,p_day date,p_level integer,p_note text,p_evidence text,p_request uuid) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;c jsonb;r public.point_requests;used integer;max_count integer;slot integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='child';if not found then raise exception 'Child account required' using errcode='42501';end if;
 if p_day is null or p_day>(now() at time zone 'Asia/Amman')::date or p_level is null or p_level not between 0 and 2 or p_note is null or length(p_note)>300 then raise exception 'Invalid request';end if;
 if p_evidence is not null and (length(p_evidence)>100000 or p_evidence !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$') then raise exception 'Invalid evidence';end if;
 select data into d from public.family_state where owner_id=m.owner_id for update;
 select value into c from jsonb_array_elements(d->'criteria') where value->>'id'=p_criterion and not coalesce((value->>'archived')::boolean,false) and (value->>'assigned_child' is null or value->>'assigned_child'=m.child_id);if not found then raise exception 'Unknown criterion';end if;
 if p_request is not null then
  select * into r from public.point_requests where id=p_request and owner_id=m.owner_id and requester=m.user_id and child_id=m.child_id and criterion_id=p_criterion and day=p_day for update;
  if not found or r.deleted_at is not null or r.status<>'rejected' then raise sqlstate 'PT409' using message='Only returned achievement may be corrected';end if;
  update public.point_requests set level=p_level,note=p_note,evidence=p_evidence,status='pending',review_note='',reviewed_at=null where id=r.id;return;
 end if;
 max_count:=case when coalesce((c->>'allow_repeat')::boolean,false) then least(20,greatest(2,coalesce((c->>'max_per_day')::integer,3))) else 1 end;
 -- Count each submitted/approved occurrence once, including direct parent evaluations.
 select count(*) into used from(select occurrence from public.point_requests where owner_id=m.owner_id and child_id=m.child_id and criterion_id=p_criterion and day=p_day and deleted_at is null union select coalesce((e->>'occurrence')::integer,1) from jsonb_array_elements(d->'evaluations') e where e->>'child'=m.child_id and e->>'criterion'=p_criterion and e->>'date'=p_day::text) q;
 if used>=max_count then raise sqlstate 'PT409' using message='Achievement daily limit reached';end if;
 select coalesce(max(n),0)+1 into slot from(select occurrence n from public.point_requests where owner_id=m.owner_id and child_id=m.child_id and criterion_id=p_criterion and day=p_day union all select coalesce((e->>'occurrence')::integer,1) from jsonb_array_elements(d->'evaluations') e where e->>'child'=m.child_id and e->>'criterion'=p_criterion and e->>'date'=p_day::text) q;
 insert into public.point_requests(owner_id,requester,child_id,criterion_id,day,level,note,evidence,occurrence) values(m.owner_id,m.user_id,m.child_id,p_criterion,p_day,p_level,p_note,p_evidence,slot);
end $$;
revoke all on function public.submit_achievement(text,date,integer,text,text,uuid) from public,anon;
grant execute on function public.submit_achievement(text,date,integer,text,text,uuid) to authenticated;
create or replace function public.submit_point_request(p_criterion text,p_day date,p_level integer,p_note text) returns void language plpgsql security definer set search_path='' as $$
begin perform public.submit_achievement(p_criterion,p_day,p_level,p_note,null,null);end $$;
revoke all on function public.submit_point_request(text,date,integer,text) from public,anon;grant execute on function public.submit_point_request(text,date,integer,text) to authenticated;
create or replace function public.submit_point_request_with_evidence(p_criterion text,p_day date,p_level integer,p_note text,p_evidence text) returns void language plpgsql security definer set search_path='' as $$
begin perform public.submit_achievement(p_criterion,p_day,p_level,p_note,p_evidence,null);end $$;
revoke all on function public.submit_point_request_with_evidence(text,date,integer,text,text) from public,anon;grant execute on function public.submit_point_request_with_evidence(text,date,integer,text,text) to authenticated;
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
 if not found or r.status<>'pending' or r.deleted_at is not null then raise sqlstate 'PT409' using message='Request already reviewed'; end if;
 if p_approve then
  select value into c from jsonb_array_elements(d->'criteria') where value->>'id'=r.criterion_id;
  if c is null or coalesce((c->>'archived')::boolean,false) or not exists(select 1 from jsonb_array_elements(d->'children') x where x->>'id'=r.child_id) then raise exception 'Missing criterion or child'; end if;
  row_data:=jsonb_build_object('child',r.child_id,'criterion',r.criterion_id,'date',r.day::text,'level',p_level,'points',(c->'points'->>p_level)::integer,'note',r.note,'occurrence',r.occurrence,'request_id',r.id,'evidence',r.evidence);
  d:=jsonb_set(d,'{evaluations}',coalesce((select jsonb_agg(e) from jsonb_array_elements(d->'evaluations') e where not(e->>'child'=r.child_id and e->>'criterion'=r.criterion_id and e->>'date'=r.day::text and coalesce((e->>'occurrence')::integer,1)=r.occurrence)),'[]')||jsonb_build_array(row_data));
  if coalesce((select sum((e->>'points')::numeric) from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e union all select e from jsonb_array_elements(coalesce(d->'adjustments','[]')) e) t where e->>'child'=r.child_id),0)<coalesce((select sum((x->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') x where x->>'child'=r.child_id),0) then raise exception 'Cannot reduce spent points'; end if;
  if length(trim(p_note))>0 then d:=jsonb_set(d,'{encouragements}',coalesce(d->'encouragements','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',r.child_id,'note',trim(p_note),'date',(now() at time zone 'Asia/Amman')::date::text,'occurrence',r.occurrence,'request_id',r.id)));end if;
  if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
  update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 end if;
 update public.point_requests set status=case when p_approve then 'approved' else 'rejected' end,review_note=p_note,reviewed_at=now() where id=r.id;
 perform public.log_family_event(m.owner_id,case when p_approve then 'اعتماد إنجاز' else 'إعادة إنجاز للمراجعة' end,r.child_id,p_note);
end $$;
revoke all on function public.review_point_request(uuid,boolean,integer,text) from public,anon;
grant execute on function public.review_point_request(uuid,boolean,integer,text) to authenticated;
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
  if exists(select 1 from jsonb_array_elements(existing_data->'evaluations') old where not exists(select 1 from jsonb_array_elements(p_data->'evaluations') new where new->>'child'=old->>'child' and new->>'criterion'=old->>'criterion' and new->>'date'=old->>'date' and coalesce((new->>'occurrence')::integer,1)=coalesce((old->>'occurrence')::integer,1))) then raise exception 'Use delegated reset operation' using errcode='42501';end if;
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
 if exists(select 1 from jsonb_array_elements(p_data->'criteria') c where (c ? 'allow_repeat' and jsonb_typeof(c->'allow_repeat')<>'boolean') or (c ? 'max_per_day' and (coalesce(c->>'max_per_day','')!~'^[0-9]+$' or (c->>'max_per_day')::numeric not between 1 and 20))) then raise exception 'Invalid repeat settings';end if;
 if exists(select 1 from jsonb_array_elements(p_data->'evaluations') e where e ? 'occurrence' and (coalesce(e->>'occurrence','')!~'^[1-9][0-9]*$')) then raise exception 'Invalid occurrence';end if;
 if exists(select 1 from jsonb_array_elements(p_data->'evaluations') e group by e->>'child',e->>'criterion',e->>'date',coalesce((e->>'occurrence')::integer,1) having count(*)>1) then raise exception 'Duplicate daily evaluation'; end if;
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
create or replace function public.cleanup_trial(p_child text,p_keys text[],p_reason text,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;k text;prefix text;removed jsonb;kept jsonb;snapshot jsonb:='{}';amount_available numeric;reqs jsonb;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent' and user_id=owner_id;if not found then raise exception 'Admin only' using errcode='42501';end if;
 if p_keys is null or cardinality(p_keys) not between 1 and 500 or p_reason is null or length(trim(p_reason)) not between 1 and 300 then raise exception 'Invalid cleanup';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 foreach k in array array['evaluations','adjustments','attempts','redemptions'] loop
  prefix:=case k when 'evaluations' then 'e' when 'adjustments' then 'a' when 'attempts' then 'q' else 'r' end;
  select coalesce(jsonb_agg(e) filter(where e->>'child'=p_child and (case when k='evaluations' then 'e|'||(e->>'criterion')||'|'||(e->>'date')||case when coalesce((e->>'occurrence')::integer,1)>1 then '|'||(e->>'occurrence') else '' end else prefix||'|'||(e->>'id') end)=any(p_keys)),'[]'),coalesce(jsonb_agg(e) filter(where not(e->>'child'=p_child and coalesce((case when k='evaluations' then 'e|'||(e->>'criterion')||'|'||(e->>'date')||case when coalesce((e->>'occurrence')::integer,1)>1 then '|'||(e->>'occurrence') else '' end else prefix||'|'||(e->>'id') end)=any(p_keys),false))),'[]') into removed,kept from jsonb_array_elements(coalesce(d->k,'[]')) e;
  snapshot:=snapshot||jsonb_build_object(k,removed);d:=jsonb_set(d,array[k],kept);
 end loop;
 select coalesce(sum((e->>'points')::numeric),0) into amount_available from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(d->'attempts') e union all select e from jsonb_array_elements(d->'adjustments') e) t where e->>'child'=p_child;
 if amount_available<coalesce((select sum((r->>'cost')::numeric) from jsonb_array_elements(d->'redemptions') r where r->>'child'=p_child),0) then raise exception 'Reset would reduce spent points';end if;
 select coalesce(jsonb_agg(to_jsonb(r)),'[]') into reqs from public.point_requests r where owner_id=m.owner_id and child_id=p_child and ('e|'||criterion_id||'|'||day::text||case when occurrence>1 then '|'||occurrence::text else '' end)=any(p_keys);
 delete from public.point_requests where owner_id=m.owner_id and child_id=p_child and ('e|'||criterion_id||'|'||day::text||case when occurrence>1 then '|'||occurrence::text else '' end)=any(p_keys);
 snapshot:=snapshot||jsonb_build_object('requests',reqs);
 d:=jsonb_set(d,'{resetArchive}',coalesce(d->'resetArchive','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',p_child,'date',(now() at time zone 'Asia/Amman')::date::text,'note',p_reason,'records',snapshot)));
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تنظيف سجلات تجربة',p_child,p_reason);
end $$;
revoke all on function public.cleanup_trial(text,text[],text,bigint) from public,anon;grant execute on function public.cleanup_trial(text,text[],text,bigint) to authenticated;
-- Reject account creation by an old Edge Function that does not identify the verified primary admin.
alter table public.family_members add column if not exists created_by uuid;
create or replace function public.is_game_attempt(e jsonb) returns boolean language sql immutable set search_path='' as $$
 select coalesce(e->>'kind','')='game' or coalesce(e->>'quiz','') ~ '^game_(memory|space)_' or (not(e ? 'kind') and coalesce(e->>'name','') ~ '^(ذاكرة الصور|مهمة الفضاء).*مرحلة.*صعوبة')
$$;
revoke all on function public.is_game_attempt(jsonb) from public,anon,authenticated;

create or replace function public.reset_game_points(p_player text,p_reason text,p_revision bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;rev bigint;removed jsonb;kept jsonb;entries jsonb;c jsonb;child text;available numeric;spent numeric;affected integer;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';
 if not found or not public.has_family_permission(m.owner_id,'reset_points') then raise exception 'Permission not granted' using errcode='42501';end if;
 if p_reason is null or length(trim(p_reason)) not between 1 and 300 then raise exception 'Invalid reason';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;
 if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 if p_player is not null and not exists(select 1 from jsonb_array_elements(public.game_roster(m.owner_id)) r where r->>'id'=p_player) then raise exception 'Unknown player';end if;
 select coalesce(jsonb_agg(e) filter(where public.is_game_attempt(e) and (p_player is null or e->>'child'=p_player)),'[]'),
 coalesce(jsonb_agg(e) filter(where not(public.is_game_attempt(e) and (p_player is null or e->>'child'=p_player))),'[]') into removed,kept from jsonb_array_elements(d->'attempts') e;
 -- Check every affected child's remaining balance before changing any ledger or game record.
 for c in select value from jsonb_array_elements(d->'children') where p_player is null or value->>'id'=p_player loop
  child:=c->>'id';
  select coalesce(sum((e->>'points')::numeric),0) into available from (select e from jsonb_array_elements(d->'evaluations') e union all select e from jsonb_array_elements(kept) e union all select e from jsonb_array_elements(coalesce(d->'adjustments','[]')) e) ledger where e->>'child'=child;
  select coalesce(sum((r->>'cost')::numeric),0) into spent from jsonb_array_elements(d->'redemptions') r where r->>'child'=child;
  if available<spent then raise exception 'Game reset would reduce spent points';end if;
 end loop;
 d:=jsonb_set(d,'{attempts}',kept);
 for child in select distinct e->>'child' from jsonb_array_elements(removed) e loop
  select jsonb_agg(e) into entries from jsonb_array_elements(removed) e where e->>'child'=child;
  d:=jsonb_set(d,'{resetArchive}',coalesce(d->'resetArchive','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'child',child,'date',(now() at time zone 'Asia/Amman')::date::text,'kind','game_reset','note',trim(p_reason),'records',jsonb_build_object('attempts',entries))));
 end loop;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 -- Keep original awarded points for the daily cap and keep rows for unlocked stages / deduplication.
 update public.family_game_completions set reset_at=now(),approval_status=case when approval_status='pending' then 'rejected' else approval_status end where owner_id=m.owner_id and reset_at is null and (p_player is null or child_id=p_player);
 get diagnostics affected=row_count;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تصفير نقاط الألعاب',p_player,case when p_player is null then 'جميع المشاركين' else p_player end||' — '||trim(p_reason)||' — سجلات: '||affected);
 return jsonb_build_object('reset_records',affected,'archived_attempts',jsonb_array_length(removed));
end $$;
revoke all on function public.reset_game_points(text,text,bigint) from public,anon;
grant execute on function public.reset_game_points(text,text,bigint) to authenticated;
create or replace function public.game_overview() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.family_members;cfg jsonb;roster jsonb;rooms jsonb;progress jsonb;requests jsonb;legacy jsonb;v_day date:=(now() at time zone 'Asia/Amman')::date;
begin
 select * into m from public.family_members where user_id=auth.uid() and active;if not found then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('daily_cap',daily_cap,'max_difficulty',max_difficulty,'enabled',enabled) into cfg from public.family_game_settings where owner_id=m.owner_id;
 select coalesce(jsonb_agg(c),'[]') into roster from jsonb_array_elements(public.game_roster(m.owner_id)) c where m.role='parent' or c->>'id'=m.child_id;
 select coalesce(jsonb_agg(r order by r->>'created_at' desc),'[]') into rooms from(select jsonb_build_object('id',id,'game',game,'difficulty',difficulty,'stage',stage,'status',status,'created_at',created_at) r from public.family_game_sessions where owner_id=m.owner_id and (m.role='parent' or m.child_id=any(participants)) order by created_at desc limit 15) x;
 select coalesce(jsonb_agg(jsonb_build_object('child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',last_day,'points',points,'total_points',total_points,'daily_used',daily_used)),'[]') into progress from(select child_id,game,difficulty,stage,max(day) as last_day,coalesce(sum(points) filter(where reset_at is null and approval_status='approved'),0) total_points,coalesce(sum(points) filter(where day=v_day and reset_at is null and approval_status='approved'),0) points,coalesce(sum(points) filter(where day=v_day),0) daily_used from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) group by child_id,game,difficulty,stage) compact;
 select coalesce(jsonb_agg(r),'[]') into requests from(select jsonb_build_object('id',id,'child',child_id,'game',game,'difficulty',difficulty,'stage',stage,'day',day,'points',points,'status',approval_status,'note',review_note,'reset',reset_at is not null) r from public.family_game_completions where owner_id=m.owner_id and (m.role='parent' or child_id=m.child_id) order by (approval_status='pending' and reset_at is null) desc,created_at desc limit 200) q;
 select coalesce(jsonb_agg(e),'[]') into legacy from public.family_state f,jsonb_array_elements(f.data->'attempts') e where f.owner_id=m.owner_id and public.is_game_attempt(e) and (m.role='parent' or e->>'child'=m.child_id) and not exists(select 1 from public.family_game_completions g where g.owner_id=m.owner_id and g.id::text=e->>'id');
 return jsonb_build_object('settings',coalesce(cfg,'{"daily_cap":20,"max_difficulty":3,"enabled":true}'::jsonb),'can_reset',public.has_family_permission(m.owner_id,'reset_points'),'revision',(select revision from public.family_state where owner_id=m.owner_id),'legacy_attempts',legacy,'requests',requests,'children',roster,'sessions',rooms,'progress',progress,'day',v_day);
end $$;
revoke all on function public.game_overview() from public,anon;grant execute on function public.game_overview() to authenticated;
create or replace function public.criterion_to_deduction(p_criterion text,p_name text,p_description text,p_points integer,p_archive boolean,p_revision bigint) returns void language plpgsql security definer set search_path='' as $$
declare m public.family_members;d jsonb;c jsonb;rev bigint;
begin
 select * into m from public.family_members where user_id=auth.uid() and active and role='parent';if not found then raise exception 'Parent required' using errcode='42501';end if;
 if p_name is null or length(trim(p_name)) not between 1 and 100 or p_description is null or length(p_description)>300 or p_points is null or p_points not between 1 and 1000 or p_archive is null then raise exception 'Invalid deduction';end if;
 select data,revision into d,rev from public.family_state where owner_id=m.owner_id for update;if rev is distinct from p_revision then raise sqlstate 'PT409' using message='Revision conflict';end if;
 select value into c from jsonb_array_elements(d->'criteria') where value->>'id'=p_criterion and not coalesce((value->>'archived')::boolean,false);if not found then raise exception 'Unknown criterion';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(d->'deductionRules','[]')) r where r->>'source_criterion'=p_criterion and not coalesce((r->>'archived')::boolean,false)) then raise exception 'Criterion already linked to deduction';end if;
 d:=jsonb_set(d,'{deductionRules}',coalesce(d->'deductionRules','[]')||jsonb_build_array(jsonb_build_object('id',replace(gen_random_uuid()::text,'-',''),'name',trim(p_name),'description',p_description,'points',p_points,'source_criterion',p_criterion)));
 if p_archive then
  d:=jsonb_set(d,'{criteria}',(select jsonb_agg(case when x->>'id'=p_criterion then x||'{"archived":true}'::jsonb else x end) from jsonb_array_elements(d->'criteria') x));
  update public.point_requests set status='rejected',review_note='تم تحويل المعيار إلى بند خصم',reviewed_at=now() where owner_id=m.owner_id and criterion_id=p_criterion and status='pending';
 end if;
 if octet_length(d::text)>2000000 then raise exception 'Backup too large';end if;
 update public.family_state set data=d,revision=revision+1,updated_at=now() where owner_id=m.owner_id;
 perform public.log_family_event(m.owner_id,'تحويل معيار إلى بند خصم',null,trim(p_name)||' — '||p_points||' نقطة، دون خصم تلقائي');
end $$;
revoke all on function public.criterion_to_deduction(text,text,text,integer,boolean,bigint) from public,anon;
grant execute on function public.criterion_to_deduction(text,text,text,integer,boolean,bigint) to authenticated;

notify pgrst,'reload schema';
commit;
