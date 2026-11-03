-- إضافة الصلاة والواجبات والتحديات التعليمية. شغّل بعد v8.
begin;
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
commit;
