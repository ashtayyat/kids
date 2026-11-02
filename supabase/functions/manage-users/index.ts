import {createClient} from 'npm:@supabase/supabase-js@2';
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'};
function normalize(value:unknown){const n=String(value).normalize('NFKC').trim().toLowerCase();if(!/^[\p{L}\p{N}_-]{3,32}$/u.test(n))throw Error('اسم المستخدم غير صالح');return n;}
async function emailFor(n:string){const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(n));return Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join('')+'@accounts.kids.invalid';}
Deno.serve(async req=>{
 const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...headers,'Content-Type':'application/json'}});
 if(req.method==='OPTIONS')return new Response('ok',{headers});if(req.method!=='POST')return reply({error:'الطريقة غير مدعومة'},405);
 try{
  const token=req.headers.get('Authorization')?.replace(/^Bearer /,'');if(!token)return reply({error:'يلزم تسجيل الدخول'},401);
  const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:auth,error:authError}=await admin.auth.getUser(token);if(authError||!auth.user)return reply({error:'جلسة غير صالحة'},401);
  const {data:actor,error:actorError}=await admin.from('family_members').select('*').eq('user_id',auth.user.id).single();
  if(actorError||actor?.role!=='parent'||!actor.active||actor.user_id!==actor.owner_id)return reply({error:'إدارة المستخدمين لولي الأمر الرئيسي (مدير الموقع) فقط'},403);
  const raw=await req.text();if(raw.length>4096)return reply({error:'طلب كبير جدًا'},400);const body=JSON.parse(raw),action=body.action||'create';
  let logChild:string|null=action==='create'&&body.role==='child'?body.childId:null;
  const log=async(kind:string)=>{await admin.from('family_audit').insert({owner_id:actor.owner_id,actor_id:actor.user_id,child_id:action==='delete'?null:logChild,kind,detail:action==='delete'?'حذف حساب كامل':String(body.displayName||body.username||'').slice(0,100)})};
  if(action!=='create'){
   const {data:target,error}=await admin.from('family_members').select('*').eq('user_id',body.userId).eq('owner_id',actor.owner_id).single();if(error||!target)return reply({error:'الحساب غير موجود ضمن أسرتك'},404);
   logChild=target.child_id;
   if(target.user_id===actor.owner_id&&['delete','suspend','role'].includes(action))return reply({error:'لا يمكن حذف أو تعطيل أو خفض صلاحية مدير الموقع الأساسي'},400);
   if(action==='delete'){
    if(body.confirmation!=='حذف نهائي')return reply({error:'التأكيد مطلوب'},400);
    // BEFORE DELETE trigger removes the linked child profile, records, requests and archives atomically.
    const {error:e}=await admin.auth.admin.deleteUser(target.user_id,false);if(e)return reply({error:'تعذر الحذف الكامل. لم يتم تأكيد حذف الحساب؛ راجع سجل الدالة.'},400);await log('حذف حساب كامل');return reply({ok:true});
   }
   if(action==='password'){
    if(typeof body.password!=='string'||body.password.length<10||body.password.length>128)return reply({error:'كلمة المرور من ١٠ إلى ١٢٨ محرفًا'},400);
    const {error:e}=await admin.auth.admin.updateUserById(target.user_id,{password:body.password});if(e)return reply({error:'تعذر تحديث كلمة المرور'},400);await log('تغيير كلمة مرور');return reply({ok:true});
   }
   if(action==='suspend'||action==='activate'){
    const active=action==='activate';const {error:e}=await admin.from('family_members').update({active}).eq('user_id',target.user_id).eq('owner_id',actor.owner_id);if(e)return reply({error:'تعذر تحديث الحالة'},400);
    // Database access is blocked by active checks immediately, including existing sessions.
    const {error:banError}=await admin.auth.admin.updateUserById(target.user_id,{ban_duration:active?'none':'876000h'});if(banError)return reply({error:'حُدثت صلاحية الوصول؛ تعذر تحديث حظر تسجيل الدخول. أعد تنفيذ العملية.'},400);await log(active?'تفعيل حساب':'تعطيل حساب');return reply({ok:true});
   }
   if(action==='role'){
    if(!['parent','child'].includes(body.role))return reply({error:'صلاحية غير صالحة'},400);
    if(body.role==='child'){const {data:f}=await admin.from('family_state').select('data').eq('owner_id',actor.owner_id).single();if(!f?.data.children.some((c:{id:string})=>c.id===body.childId))return reply({error:'اختر ملف طفل من أسرتك'},400)}
    const {error:e}=await admin.from('family_members').update({role:body.role,child_id:body.role==='child'?body.childId:null}).eq('user_id',target.user_id).eq('owner_id',actor.owner_id);if(e)return reply({error:'تعذر تغيير الصلاحية؛ قد يكون الملف مرتبطًا بحساب آخر'},400);await log('تغيير صلاحية حساب');return reply({ok:true});
   }
   if(action==='edit'){
    const name=String(body.displayName||'').trim();if(name.length<1||name.length>80)return reply({error:'الاسم غير صالح'},400);
    // Usernames remain stable login identifiers; display names can be edited freely.
    const {error:e}=await admin.from('family_members').update({display_name:name}).eq('user_id',target.user_id).eq('owner_id',actor.owner_id);if(e)return reply({error:'تعذر تعديل الاسم'},400);await log('تعديل اسم حساب');return reply({ok:true});
   }
   return reply({error:'عملية غير مدعومة'},400);
  }
  const username=normalize(body.username),password=String(body.password||'');if(password.length<10||password.length>128)return reply({error:'كلمة المرور من ١٠ إلى ١٢٨ محرفًا'},400);
  if(!['parent','child'].includes(body.role))return reply({error:'دور غير صالح'},400);const displayName=String(body.displayName||username).trim();if(!displayName||displayName.length>80)return reply({error:'الاسم غير صالح'},400);
  const {data:family,error:familyError}=await admin.from('family_state').select('data').eq('owner_id',actor.owner_id).single();if(familyError)return reply({error:'احفظ ملف العائلة أولًا'},400);
  if(body.role==='child'&&!family.data.children.some((c:{id:string})=>c.id===body.childId))return reply({error:'اختر طفلًا من عائلتك'},400);
  const {data:created,error:createError}=await admin.auth.admin.createUser({email:await emailFor(username),password,email_confirm:true,app_metadata:{managed_family_account:true},user_metadata:{display_name:displayName}});
  if(createError||!created.user)return reply({error:'تعذر إنشاء الحساب. قد يكون الاسم مستخدمًا أو كلمة المرور غير مقبولة.'},400);
  const {error:insertError}=await admin.from('family_members').insert({user_id:created.user.id,owner_id:actor.owner_id,username,display_name:displayName,role:body.role,child_id:body.role==='child'?body.childId:null,created_by:actor.user_id});
  if(insertError){await admin.auth.admin.deleteUser(created.user.id,false);return reply({error:'تعذر ربط الحساب. قد يكون للطفل حساب بالفعل.'},400)}
  await log('إنشاء حساب');return reply({ok:true});
 }catch{return reply({error:'تعذر تنفيذ العملية، تحقق من المدخلات وتحديث قاعدة البيانات'},400)}
});
