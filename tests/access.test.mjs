import test from 'node:test';import assert from 'node:assert/strict';import{readFileSync}from'node:fs';import{PGlite}from'@electric-sql/pglite';import{blank}from'../core.mjs';
test('database enforces family isolation, parent roles and atomic approval',async()=>{
 const db=new PGlite();try{
 await db.exec(`create schema auth;create role anon;create role authenticated;create table auth.users(id uuid primary key,raw_app_meta_data jsonb default '{}');create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;grant usage on schema auth to authenticated,anon;`);
 await db.exec(readFileSync(new URL('../schema.sql',import.meta.url),'utf8'));
 await db.exec(readFileSync(new URL('../migration-v2.sql',import.meta.url),'utf8'));
 // Re-running migration must preserve all records and remain safe.
 await db.exec(readFileSync(new URL('../migration-v2.sql',import.meta.url),'utf8'));
 const parent='10000000-0000-0000-0000-000000000001',child='10000000-0000-0000-0000-000000000002',outsider='10000000-0000-0000-0000-000000000003',parent2='10000000-0000-0000-0000-000000000004';
 for(const id of [parent,child,outsider,parent2])await db.query('insert into auth.users(id) values($1)',[id]);
 await db.query("update auth.users set raw_app_meta_data='{\"managed_family_account\":true}' where id=$1",[child]);
 async function as(id){await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated')}
 await as(parent);await db.query('select public.my_membership()');const s=blank();s.children=[{id:'a',name:'طفل افتراضي',age:10,avatar:'🦊',goal:100},{id:'b',name:'آخر',age:12,avatar:'🐼',goal:100}];
 await db.query('select public.save_family($1,0)',[JSON.stringify(s)]);
 await db.exec('reset role');await db.query("insert into public.family_members(user_id,owner_id,display_name,role,child_id) values($1,$2,'طفل','child','a'),($3,$2,'ولي أمر آخر','parent',null)",[child,parent,parent2]);
 await as(child);const loaded=(await db.query('select public.load_family() d')).rows[0].d;assert.equal(loaded.data.children.length,1);assert.equal(loaded.data.children[0].id,'a');
 assert.equal((await db.query('select * from public.family_state')).rows.length,0);
 await assert.rejects(db.query('select public.save_family($1,1)',[JSON.stringify(s)]));
 await assert.rejects(db.query("update public.family_members set role='parent'"));
 await db.query("select public.submit_point_request('study','2026-01-01',2,'قرأت درسي')");
 await db.query("select public.submit_point_request('study','2026-01-01',1,'مع مساعدة')");
 let req=(await db.query('select * from public.point_requests')).rows[0];assert.equal(req.level,1);assert.equal(req.status,'pending');
 assert.equal((await db.query('select public.load_family() d')).rows[0].d.data.evaluations.length,0);
 await assert.rejects(db.query("select public.review_point_request($1,true,2,'')",[req.id]));
 await as(outsider);await db.query('select public.my_membership()');assert.equal((await db.query('select * from public.point_requests')).rows.length,0);assert.equal((await db.query('select public.load_family() d')).rows[0].d.data,null);
 await assert.rejects(db.query("select public.review_point_request($1,true,2,'')",[req.id]));
 await as(parent2);await db.query("select public.review_point_request($1,true,2,'أحسنت')",[req.id]);
 await assert.rejects(db.query("select public.review_point_request($1,true,2,'')",[req.id]));
 let updated=(await db.query('select public.load_family() d')).rows[0].d;assert.equal(updated.data.evaluations.length,1);assert.equal(updated.data.evaluations[0].points,4);assert.equal(updated.revision,2);
 await assert.rejects(db.query('select public.save_family($1,1)',[JSON.stringify(s)]));
 await as(child);updated=(await db.query('select public.load_family() d')).rows[0].d;assert.equal(updated.data.evaluations[0].points,4);
 await assert.rejects(db.query("select public.submit_point_request('study','2026-01-01',2,'محاولة مكررة')"));
 await db.query("select public.submit_point_request('read','2026-01-01',2,'قراءة')");req=(await db.query("select * from public.point_requests where criterion_id='read'")).rows[0];
 await as(parent);await db.query("select public.review_point_request($1,false,0,'حاول مرة أخرى')",[req.id]);await as(child);await db.query("select public.submit_point_request('read','2026-01-01',2,'حاولت مجددًا')");
 assert.equal((await db.query("select * from public.point_requests where criterion_id='read'")).rows[0].status,'pending');
 // No missing membership may turn a managed child into a parent.
 await db.exec('reset role');await db.query('delete from public.family_members where user_id=$1',[child]);await as(child);await assert.rejects(db.query('select public.my_membership()'));
 await db.exec("reset role;set role anon");await assert.rejects(db.query('select public.load_family()'));await assert.rejects(db.query('select * from public.family_state'));
 }finally{await db.close()}
});
