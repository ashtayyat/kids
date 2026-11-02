// Deploy to Supabase. Service-role key is read ONLY from server environment.
import {createClient} from 'npm:@supabase/supabase-js@2';
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'};
function normalize(value:unknown){const n=String(value).normalize('NFKC').trim().toLowerCase();if(!/^[\p{L}\p{N}_-]{3,32}$/u.test(n))throw Error('اسم المستخدم غير صالح');return n;}
async function emailFor(n:string){const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(n));return Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join('')+'@accounts.kids.invalid';}
Deno.serve(async req=>{
 const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...headers,'Content-Type':'application/json'}});
 if(req.method==='OPTIONS')return new Response('ok',{headers});
 if(req.method!=='POST')return reply({error:'الطريقة غير مدعومة'},405);
 try{
  const token=req.headers.get('Authorization')?.replace(/^Bearer /,'');if(!token)return reply({error:'يلزم تسجيل الدخول'},401);
  const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:auth,error:authError}=await admin.auth.getUser(token);if(authError||!auth.user)return reply({error:'جلسة غير صالحة'},401);
  const {data:actor,error:actorError}=await admin.from('family_members').select('owner_id,role').eq('user_id',auth.user.id).single();
  if(actorError||actor?.role!=='parent')return reply({error:'إنشاء الحسابات متاح لولي الأمر فقط'},403);
  const text=await req.text();if(text.length>4096)return reply({error:'طلب كبير جدًا'},400);
  const body=JSON.parse(text),username=normalize(body.username),password=String(body.password||'');
  if(password.length<10||password.length>128)return reply({error:'كلمة المرور من ١٠ إلى ١٢٨ حرفًا'},400);
  if(!['parent','child'].includes(body.role))return reply({error:'دور غير صالح'},400);
  const displayName=String(body.displayName||username).trim();if(!displayName||displayName.length>80)return reply({error:'الاسم غير صالح'},400);
  const {data:family,error:familyError}=await admin.from('family_state').select('data').eq('owner_id',actor.owner_id).single();
  if(familyError)return reply({error:'احفظ ملف العائلة أولًا'},400);
  if(body.role==='child'&&!family.data.children.some((c:{id:string})=>c.id===body.childId))return reply({error:'اختر طفلًا من عائلتك'},400);
  const {data:created,error:createError}=await admin.auth.admin.createUser({email:await emailFor(username),password,email_confirm:true,app_metadata:{managed_family_account:true},user_metadata:{display_name:displayName}});
  if(createError||!created.user)return reply({error:'تعذر إنشاء الحساب. قد يكون اسم المستخدم مستخدمًا أو كلمة المرور غير مقبولة.'},400);
  const {error:insertError}=await admin.from('family_members').insert({user_id:created.user.id,owner_id:actor.owner_id,username,display_name:displayName,role:body.role,child_id:body.role==='child'?body.childId:null});
  if(insertError){await admin.auth.admin.deleteUser(created.user.id);return reply({error:'تعذر ربط الحساب. قد يكون للطفل حساب بالفعل.'},400)}
  return reply({ok:true,message:'تم إنشاء الحساب'});
 }catch{return reply({error:'تعذر إنشاء الحساب، تحقق من المدخلات وإعداد الدالة'},400)}
});
