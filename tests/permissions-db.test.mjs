import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
import {blank} from '../core.mjs';

test('primary delegates reset and deduction independently, revokes live access and isolates families',async()=>{
 const db=new PGlite();
 try {
  await db.exec(`create schema auth;create role anon;create role authenticated;create table auth.users(id uuid primary key,raw_app_meta_data jsonb default '{}');create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);
  await db.exec(readFileSync(new URL('../upgrade-latest.sql',import.meta.url),'utf8'));
  await db.exec(readFileSync(new URL('../migration-v6.sql',import.meta.url),'utf8'));
  const p='60000000-0000-0000-0000-000000000001',s='60000000-0000-0000-0000-000000000002',c='60000000-0000-0000-0000-000000000003',o='60000000-0000-0000-0000-000000000004';
  for(const id of [p,s,c,o])await db.query('insert into auth.users(id) values($1)',[id]);
  async function as(id){await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated')}
  const load=async()=>(await db.query('select public.load_family() d')).rows[0].d;
  async function op(action,child='a',criterion=null){const {revision}=await load();return db.query('select public.manage_points($1,$2,$3,$4,$5,$6)',[child,action,criterion,action==='deduct'?1:0,'اختبار التفويض',revision])}
  const grant=permissions=>db.query('select public.set_parent_permissions($1,$2)',[s,permissions]);
  await as(p);await db.query('select public.my_membership()');
  const data=blank();data.children=[{id:'a',name:'تجربة',age:10,goal:100},{id:'b',name:'آخر',age:11,goal:100}];data.evaluations=[{child:'a',criterion:'study',date:'2026-01-01',points:20,level:2},{child:'b',criterion:'study',date:'2026-01-01',points:20,level:2}];await db.query('select public.save_family($1,0)',[JSON.stringify(data)]);
  await db.exec('reset role');await db.query("insert into public.family_members(user_id,owner_id,role,display_name,child_id,created_by) values($1,$3,'parent','ثانوي',null,$3),($2,$3,'child','طفل','a',$3)",[s,c,p]);
  await as(o);await db.query('select public.my_membership()');const other=blank();other.children=[{id:'foreign',name:'أسرة أخرى',age:10,goal:10}];await db.query('select public.save_family($1,0)',[JSON.stringify(other)]);
  await assert.rejects(grant(['reset_points']));
  await as(s);await assert.rejects(grant(['reset_points']));await assert.rejects(op('reset'));await assert.rejects(op('deduct'));await assert.rejects(db.query("update public.family_members set permissions=array['reset_points'] where user_id=$1",[s]));
  await as(p);await assert.rejects(grant(['accounts']));await assert.rejects(grant([null]));await assert.rejects(db.query("select public.set_parent_permissions($1,array['reset_points'])",[c]));await assert.rejects(db.query("select public.set_parent_permissions($1,array['reset_points'])",[p]));await assert.rejects(db.query("select public.set_parent_permissions($1,array['reset_points'])",[o]));
  await grant(['reset_points']);await as(s);assert.deepEqual((await db.query('select public.my_membership() d')).rows[0].d.permissions,['reset_points']);
  await assert.rejects(op('deduct'));await assert.rejects(op('reset','foreign'));await assert.rejects(db.query('select public.save_family($1,$2)',[JSON.stringify({...data,children:[]}),(await load()).revision]));
  await op('reset','a','study');let result=await load();assert.equal(result.data.evaluations.some(e=>e.child==='a'),false);assert.equal(result.data.evaluations.some(e=>e.child==='b'),true);assert.equal(result.data.resetArchive,undefined);
  await as(p);result=await load();assert.equal(result.data.resetArchive.length,1);assert.equal((await db.query("select actor_id from public.family_audit where kind='تصفير نقاط'")).rows[0].actor_id,s);
  await grant([]);await as(s);await assert.rejects(op('reset','b')); // Same session identity, no new login required.
  await as(p);await grant(['deduct_points']);await as(s);await assert.rejects(op('reset','b'));await op('deduct','b');assert.equal((await load()).data.adjustments[0].points,-1);
  await as(p);await grant(['deduct_points','reset_points']);await as(s);await op('reset','b');assert.equal((await load()).data.evaluations.length,0);
  await as(p);await db.exec('reset role');await db.query('update public.family_members set active=false where user_id=$1',[s]);await as(s);assert.equal((await db.query("select public.has_family_permission($1,'reset_points') ok",[p])).rows[0].ok,false);await assert.rejects(db.query("select public.manage_points('b','reset',null,0,'قديم',0)"));
  await db.exec('reset role');await db.query("update public.family_members set role='child',child_id='b',active=true where user_id=$1",[s]);await db.query("update public.family_members set role='parent',child_id=null where user_id=$1",[s]);await as(s);assert.deepEqual((await db.query('select public.my_membership() d')).rows[0].d.permissions,[]);
  await as(c);await assert.rejects(grant(['reset_points']));await assert.rejects(op('reset'));await as(o);assert.equal((await load()).data.children[0].id,'foreign');
 } finally {await db.close()}
});
