import {can} from './family.mjs';
import {balance,isGameAttempt} from './core.mjs';
export const DIFFICULTIES=['','سهل','متوسط','صعب'];
export const GAME_NAMES={memory:'ذاكرة الصور',space:'مهمة الفضاء'};
export const MEMORY_ICONS=['🦊','🐼','🦁','🐰','🦋','🐬','🦉','🐢','🐝','🐙'];
export const memoryPairs=(difficulty,stage)=>difficulty+stage+1;
export const stageReward=(difficulty,stage)=>difficulty+stage;
export function unlocked(progress,child,game,difficulty,stage){return stage===1||progress.some(p=>p.child===child&&p.game===game&&p.difficulty===difficulty&&p.stage===stage-1)}
export function rewardAmount(progress,child,game,difficulty,stage,day,cap){if(progress.some(p=>p.child===child&&p.game===game&&p.difficulty===difficulty&&p.stage===stage&&p.day===day))return 0;const used=progress.filter(p=>p.child===child&&p.day===day).reduce((n,p)=>n+p.points,0);return Math.max(0,Math.min(stageReward(difficulty,stage),cap-used))}
const demoId=()=>globalThis.crypto?.randomUUID?.()||`demo-${Date.now()}-${Math.random().toString(36).slice(2)}`;
const shuffle=rows=>{for(let i=rows.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[rows[i],rows[j]]=[rows[j],rows[i]]}return rows};
// Local demo adapter. It never calls Supabase and is reset whenever a fresh demo starts.
export function createDemoGames(C){let settings={daily_cap:20,max_difficulty:3,enabled:true},sessions=[],progress=[];
 const roster=()=>[...C.state.children.map(c=>({...c,role:'child'})),{id:'parent:demo-primary',name:'ولي أمر تجريبي',age:30,role:'parent'},{id:'parent:demo-secondary',name:'ولي أمر ثانٍ تجريبي',age:30,role:'parent'}];
 const view=(s,m)=>{if(!s||m.role==='child'&&!s.participants.includes(m.child_id))throw Error('هذه اللعبة ليست لك');const data=s.game==='memory'?{cards:s.deck.map((v,i)=>s.matched.includes(i)||s.open.includes(i)?v:null),matched:s.matched,open:s.open,moves:s.moves,limit:s.limit}:{players:s.players.map(p=>({child:p.child,name:p.name,index:p.index,total:p.questions.length,question:m.role==='parent'||m.child_id===p.child?((({correct,...q})=>q)(p.questions[p.index]||{})):null}))};return structuredClone({id:s.id,game:s.game,difficulty:s.difficulty,stage:s.stage,participants:s.participants,status:s.status,revision:s.revision,data,awards:s.awards||[]})};
 const award=s=>{s.awards=[];for(const child of s.participants){const day=C.today(),amount=rewardAmount(progress,child,s.game,s.difficulty,s.stage,day,settings.daily_cap);if(progress.some(p=>p.child===child&&p.game===s.game&&p.difficulty===s.difficulty&&p.stage===s.stage&&p.day===day))continue;const id=demoId();progress.push({id,child,game:s.game,difficulty:s.difficulty,stage:s.stage,day,points:amount,status:'pending',note:''});s.awards.push({id,child,points:amount,status:'pending'})}};
 return {reset(){sessions=[];progress=[];settings={daily_cap:20,max_difficulty:3,enabled:true}},async call(name,a={}){const m=C.membership,parent=m.role==='parent';
  if(name==='game_overview')return structuredClone({settings,can_reset:can(m,'reset_points'),revision:0,children:roster().filter(c=>parent||c.id===m.child_id).map(({id,name,age,role})=>({id,name,age,role})),sessions:sessions.filter(s=>parent||s.participants.includes(m.child_id)).slice(-15).reverse(),progress:progress.filter(p=>parent||p.child===m.child_id).map(p=>({...p,points:p.reset||p.status!=='approved'?0:p.points,total_points:p.reset||p.status!=='approved'?0:p.points,daily_used:p.points})),requests:progress.filter(p=>parent||p.child===m.child_id).map(p=>({...p})),day:C.today()});
  if(name==='review_game_points'){
   if(!parent)throw Error('اعتماد نقاط الألعاب لولي الأمر فقط');const r=progress.find(p=>p.id===a.p_id);
   if(!r||r.status!=='pending'||r.reset)throw Error('تمت مراجعة هذا الطلب');
   if(a.p_approve&&!r.child.startsWith('parent:')){const total=r.game==='memory'?memoryPairs(r.difficulty,r.stage):2+r.stage;C.state.attempts.push({id:r.id,child:r.child,quiz:`game_${r.game}_${r.difficulty}_${r.stage}`,kind:'game',name:`${GAME_NAMES[r.game]} — مرحلة ${r.stage} — صعوبة ${r.difficulty}`,date:r.day,correct:total,total,points:r.points,note:a.p_note||''})}
   r.status=a.p_approve?'approved':'rejected';r.note=a.p_note||'';for(const s of sessions)for(const award of s.awards||[])if(award.id===r.id)award.status=r.status;return;
  }
  if(name==='reset_game_points'){
   if(!can(m,'reset_points'))throw Error('ليست لديك صلاحية تصفير النقاط');
   if(!a.p_reason?.trim())throw Error('أدخل سبب التصفير');
   if(a.p_player&&!roster().some(c=>c.id===a.p_player))throw Error('اختر مشاركًا صحيحًا');
   const next=structuredClone(C.state),removed=next.attempts.filter(e=>isGameAttempt(e)&&(!a.p_player||e.child===a.p_player));
   next.attempts=next.attempts.filter(e=>!removed.some(r=>r.id===e.id));
   if(next.children.some(c=>(!a.p_player||c.id===a.p_player)&&balance(next,c.id)<0))throw Error('لا يمكن التصفير لأن بعض نقاط الألعاب صُرفت على مكافآت؛ راجع سجل المكافآت أولًا.');
   for(const child of new Set(removed.map(e=>e.child)))(next.resetArchive??=[]).push({id:demoId(),child,date:C.today(),kind:'game_reset',note:a.p_reason,records:{attempts:removed.filter(e=>e.child===child)}});
   C.state.attempts=next.attempts;C.state.resetArchive=next.resetArchive;
   for(const p of progress)if(!a.p_player||p.child===a.p_player){p.reset=true;if(p.status==='pending')p.status='rejected'};
   for(const s of sessions)for(const a2 of s.awards||[])if(!a.p_player||a2.child===a.p_player){a2.reset=true;a2.points=0}
   return;
  }
  if(name==='configure_games'){if(!parent)throw Error('لولي الأمر فقط');settings={daily_cap:a.p_cap,max_difficulty:a.p_max,enabled:a.p_enabled};return}
  if(name==='start_game'){if(!settings.enabled||a.p_difficulty>settings.max_difficulty)throw Error('اللعبة غير متاحة');const ids=a.p_children;if(!ids.length||!parent&&(a.p_game!=='memory'||ids.length!==1||ids[0]!==m.child_id))throw Error('اختر اللاعبين');if(a.p_game==='space'&&ids.length<2)throw Error('اختر مشاركين على الأقل');for(const id of ids)if(!unlocked(progress,id,a.p_game,a.p_difficulty,a.p_stage))throw Error('أكمل المرحلة السابقة أولًا');const pairs=memoryPairs(a.p_difficulty,a.p_stage);const s={id:demoId(),game:a.p_game,difficulty:a.p_difficulty,stage:a.p_stage,participants:ids,status:'active',revision:0,deck:shuffle(Array.from({length:pairs},(_,i)=>[i,i]).flat()),matched:[],open:[],moves:0,limit:a.p_difficulty===1?0:pairs*(a.p_difficulty===2?4:3),players:ids.map(id=>{const c=roster().find(c=>c.id===id);return {child:id,name:c.name,index:0,questions:Array.from({length:2+a.p_stage},(_,i)=>{const n=c.age<8?i+1:(i+1)*(a.p_difficulty+2);return {text:`${n} + ${a.p_stage} = ؟`,options:[n+a.p_stage,n+a.p_stage+1,n+a.p_stage+2],correct:0}})}})};sessions.push(s);return s.id}
  const s=sessions.find(s=>s.id===a.p_session);if(name==='game_view')return view(s,m);if(!s||s.status!=='active')throw Error('انتهت هذه اللعبة');if(!parent&&!s.participants.includes(m.child_id))throw Error('هذه اللعبة ليست لك');let correct=false;
  if(s.game==='memory'){if(s.revision!==a.p_revision)throw Error('حدّث اللعبة');if(s.open.length===2)s.open=[];if(s.matched.includes(a.p_choice)||s.open.includes(a.p_choice))throw Error('اختر بطاقة مغلقة');s.open.push(a.p_choice);if(s.open.length===2){s.moves++;if(s.deck[s.open[0]]===s.deck[s.open[1]]){s.matched.push(...s.open);s.open=[]}if(s.matched.length===s.deck.length)s.status='completed';else if(s.limit&&s.moves>=s.limit)s.status='failed'}}
  else {const id=parent?a.p_child:m.child_id,p=s.players.find(p=>p.child===id);if(!p||p.index!==a.p_question)throw Error('تغيّر السؤال');correct=a.p_choice===p.questions[p.index].correct;if(correct)p.index++;if(s.players.every(p=>p.index===p.questions.length))s.status='completed'}
  s.revision++;if(s.status==='completed')award(s);return {correct,view:view(s,m)};
 }};
}
