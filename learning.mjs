export const STANDARD_LEVELS=['لم يُنجز','أُنجز بمساعدة','أُنجز باستقلالية'];
export const levelLabels=c=>Array.isArray(c?.labels)&&c.labels.length===3?c.labels:STANDARD_LEVELS;
export const CATEGORIES=['معلومات عامة','رياضة','رياضيات','إنجليزي','للمبتدئين'];
export function assessmentSummary(state,child,date,requests=[]){
 const criteria=state.criteria.filter(c=>!c.archived&&(!c.assigned_child||c.assigned_child===child));
 const evaluations=new Map(state.evaluations.filter(e=>e.child===child&&e.date===date).map(e=>[e.criterion,e]));
 const maxPoints=c=>Math.max(0,...c.points);
 const dailyMax=criteria.reduce((n,c)=>n+maxPoints(c),0);
 const missing=criteria.filter(c=>!evaluations.has(c.id)).map(c=>({...c,maxPoints:maxPoints(c),requestStatus:requests.find(r=>r.child_id===child&&r.criterion_id===c.id&&r.day===date)?.status||null}));
 return {total:criteria.length,assessed:criteria.length-missing.length,dailyMax,weeklyMax:dailyMax*7,earned:criteria.reduce((n,c)=>n+(evaluations.get(c.id)?.points||0),0),missing,remainingMax:missing.reduce((n,c)=>n+c.maxPoints,0)};
}
export function archiveCriterion(state,id){const c=state.criteria.find(c=>c.id===id&&!c.archived);if(!c)throw Error('المعيار غير موجود أو حُذف بالفعل');c.archived=true;return c;}
export const extraCriteria=()=>[
 {id:'homework',name:'حل الواجبات',points:[0,2,4]},
 ...[['fajr','الفجر'],['dhuhr','الظهر'],['asr','العصر'],['maghrib','المغرب'],['isha','العشاء']].map(([id,name])=>({id:'prayer_'+id,name:'صلاة '+name,labels:['في وقتها','جماعة','قضاء'],points:[3,5,1]}))
];
const question=(text,a,b,c,correct)=>({text,options:[a,b,c],correct});
export const starterQuizzes=()=>[
 {id:'starter_general',name:'تحدي المعلومات العامة',category:'معلومات عامة',min_age:8,max_age:18,points:10,questions:[question('أي كوكب نعيش عليه؟','المريخ','الأرض','زحل',1),question('ما عاصمة الأردن؟','عمّان','العقبة','إربد',0),question('أي عضو نستخدمه للسمع؟','العين','اليد','الأذن',2),question('كم عدد أيام الأسبوع؟','خمسة','سبعة','تسعة',1)]},
 {id:'starter_sport',name:'تحدي الرياضة',category:'رياضة',min_age:8,max_age:18,points:10,questions:[question('كم لاعبًا يبدأ بهم فريق كرة القدم داخل الملعب؟','٩','١١','١٣',1),question('أي رياضة تُمارَس في الماء؟','السباحة','التنس','الجري',0),question('أي أداة تُستخدم في التنس؟','مضرب','دراجة','قفاز ملاكمة',0),question('أي نشاط يقوّي مهارة ركوب الدراجة؟','القراءة','الرسم','التوازن',2)]},
 {id:'starter_math',name:'تحدي الرياضيات',category:'رياضيات',min_age:8,max_age:18,points:10,questions:[question('ما ناتج ٧ × ٦؟','٣٦','٤٢','٤٨',1),question('ما نصف العدد ٥٠؟','٢٠','٢٥','٣٠',1),question('ما ناتج ١٢٠ ÷ ١٠؟','١٢','١٠٢','٢١',0),question('كم ضلعًا للمثلث؟','٤','٥','٣',2)]},
 {id:'starter_english',name:'تحدي اللغة الإنجليزية',category:'إنجليزي',min_age:8,max_age:18,points:10,questions:[question('ما معنى Book؟','كتاب','قلم','باب',0),question('أكمل: She ___ a student.','are','is','am',1),question('ما جمع child؟','childs','childes','children',2),question('ما عكس hot؟','cold','big','new',0)]},
 {id:'starter_junior',name:'تحدي الصغار: ألوان وأعداد',category:'للمبتدئين',min_age:4,max_age:7,points:6,questions:[question('كم يساوي ١ + ١؟','١','٢','٣',1),question('ما لون الموز الناضج عادةً؟','أزرق','بنفسجي','أصفر',2),question('أي حيوان يقول مياو؟','القطة','الحصان','البقرة',0)]}
];
