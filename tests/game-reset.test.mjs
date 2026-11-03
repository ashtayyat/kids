import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
import {blank,balance,validate} from '../core.mjs';
test('game resets respect delegation, isolate a participant, archive only game points, preserve caps and stages, and reset all atomically',async()=>{
 const db=new PGlite();try{
 await db.exec(`create schema auth;create role anon;create role authenticated;create table auth.users(id uuid primary key,raw_app_meta_data jsonb default '{}');create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);
 await db.exec(readFileSync(new URL('../upgrade-latest.sql',import.meta.url),'utf8'));
 await db.exec(readFileSync(new URL('../migration-v14.sql',import.meta.url),'utf8'));
 const p='d0000000-0000-0000-0000-000000000001',p2='d0000000-0000-0000-0000-000000000002',a='d0000000-0000-0000-0000-000000000003',o='d0000000-0000-0000-0000-000000000004';
 for(const id of[p,p2,a,o])await db.query('insert into auth.users(id) values($1)',[id]);
 async function as(id){await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated')}
 const overview=async()=>(await db.query('select public.game_overview() d')).rows[0].d;
 const load=async()=>(await db.query('select public.load_family() d')).rows[0].d;
 const reset=(player,rev,reason='تنظيف التجربة')=>db.query('select public.reset_game_points($1,$2,$3) d',[player,reason,rev]);
 await as(p);await db.query('select public.my_membership()');
 const day=(await overview()).day,d=blank();d.children=[{id:'a',name:'أ',age:12,goal:100},{id:'b',name:'ب',age:5,goal:50}];
 d.evaluations=d.children.map(c=>({child:c.id,criterion:'study',level:2,points:4,date:day}));
 d.attempts=d.children.flatMap(c=>[{id:'quiz-'+c.id,child:c.id,quiz:'practice',name:'اختبار',date:day,correct:1,total:1,points:3},{id:'game-'+c.id,child:c.id,quiz:'game_memory',kind:'game',name:'لعبة',date:day,correct:1,total:1,points:c.id==='a'?4:6}]);
 d.rewards=[{id:'r',name:'مكافأة',cost:2}];d.redemptions=[{id:'ra',child:'a',reward:'r',name:'مكافأة',cost:2,date:day},{id:'rb',child:'b',reward:'r',name:'مكافأة',cost:10,date:day}];
 await db.query('select public.save_family($1,0)',[JSON.stringify(d)]);
 await db.exec('reset role');await db.query("insert into public.family_members(user_id,owner_id,role,display_name,child_id,created_by) values($1,$3,'parent','ولي أمر ثان',null,$3),($2,$3,'child','أ','a',$3)",[p2,a,p]);
 for(const [child,game,difficulty,stage,points] of [['a','memory',3,1,4],['b','space',3,3,6],['parent:'+p,'memory',3,4,7],['parent:'+p2,'space',3,5,8]])await db.query('insert into public.family_game_completions(owner_id,child_id,game,difficulty,stage,day,points) values($1,$2,$3,$4,$5,$6,$7)',[p,child,game,difficulty,stage,day,points]);
 await as(o);await db.query('select public.my_membership()');await db.exec('reset role');await db.query("insert into public.family_game_completions(owner_id,child_id,game,difficulty,stage,day,points) values($1,$2,'memory',1,1,$3,2)",[o,'parent:'+o,day]);
 await as(a);assert.equal((await overview()).can_reset,false);await assert.rejects(reset('a',1));
 await as(p2);let ov=await overview();assert.equal(ov.can_reset,false);await assert.rejects(reset(null,ov.revision));
 await as(p);ov=await overview();assert.equal(ov.can_reset,true);await assert.rejects(reset('parent:'+o,ov.revision));await assert.rejects(reset('a',ov.revision,''));
 await reset('a',ov.revision);let state=(await load()).data;validate(state);assert.equal(balance(state,'a'),5);assert.equal(balance(state,'b'),3);assert.equal(state.attempts.filter(e=>e.child==='b'&&e.kind==='game').length,1);assert.equal(state.attempts.filter(e=>e.kind!=='game').length,2);assert.equal(state.resetArchive[0].records.attempts[0].points,4);await assert.rejects(reset('a',ov.revision));
 ov=await overview();let ap=ov.progress.find(x=>x.child==='a');assert.equal(ap.total_points,0);assert.equal(ap.daily_used,4);assert.equal(ap.stage,1);assert.equal(ov.progress.find(x=>x.child==='parent:'+p).total_points,7);
 // A bulk reset that would erase already spent game points rolls back for EVERY participant.
 await assert.rejects(reset(null,ov.revision),/Game reset would reduce spent points/);assert.equal((await overview()).revision,ov.revision);assert.equal((await overview()).progress.find(x=>x.child==='parent:'+p).total_points,7);
 // Replaying after a reset still earns no duplicate points; the next stage respects the original cap usage.
 await db.query('select public.configure_games(4,3,true)');
 async function completeMemory(stage){await as(a);const id=(await db.query("select public.start_game('memory',3,$1,array['a']) id",[stage])).rows[0].id;await db.exec('reset role');const deck=(await db.query('select data from public.family_game_sessions where id=$1',[id])).rows[0].data.deck;await as(a);for(const value of new Set(deck))for(const i of deck.flatMap((x,i)=>x===value?[i]:[])){const v=(await db.query('select public.game_view($1) d',[id])).rows[0].d;await db.query('select public.game_step($1,null,$2,$3,0)',[id,i,v.revision])}return(await db.query('select public.game_view($1) d',[id])).rows[0].d}
 assert.equal((await completeMemory(1)).awards.length,0);const next=await completeMemory(2);assert.equal(next.awards[0].points,0);assert.equal((await overview()).progress.find(x=>x.child==='a'&&x.stage===2).stage,2);
 await as(p);let family=await load();family.data.redemptions=family.data.redemptions.filter(x=>x.child!=='b');await db.query('select public.save_family($1,$2)',[JSON.stringify(family.data),family.revision]);
 await db.query('select public.set_parent_permissions($1,array[\'reset_points\'])',[p2]);await as(p2);ov=await overview();assert.equal(ov.can_reset,true);await reset(null,ov.revision);state=(await load()).data;validate(state);assert.equal(state.attempts.filter(x=>x.kind==='game').length,0);assert.equal(state.attempts.length,2);assert.equal(state.evaluations.length,2);assert.equal(state.redemptions.length,1);assert.ok((await overview()).progress.every(x=>x.total_points===0));assert.ok((await overview()).progress.length>=5);
 await as(p);state=(await load()).data;const archivedCount=state.resetArchive.length;await reset(null,(await overview()).revision);assert.equal((await load()).data.resetArchive.length,archivedCount);
 await as(o);assert.equal((await overview()).progress[0].total_points,2);
 await db.exec('reset role;set role anon');await assert.rejects(reset(null,1));
 }finally{await db.close()}
});
