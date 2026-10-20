// Athar AI backend. Keep OPENAI_API_KEY on the server; never put it in frontend code.
const http = require('http');
const fs = require('fs');
const path = require('path');
const PORT = Number(process.env.PORT || 8787);
const API_KEY = process.env.OPENAI_API_KEY;
const SUPABASE_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || '';
const MODEL = process.env.OPENAI_MODEL || 'gpt-4.1-mini';
const ROOT = __dirname;
const MIME = {'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.svg':'image/svg+xml','.webmanifest':'application/manifest+json','.json':'application/json','.png':'image/png','.ico':'image/x-icon','.txt':'text/plain; charset=utf-8'};
const SYSTEM = `أنت «أَثَر»، مساعد معرفي عربي داخل تطبيق يهتم بالقرآن والتدبر. كن ودودًا وواضحًا ومتواضعًا، وأجب بلغة المستخدم. في الأسئلة الدينية لا تخترع آيات أو أحاديث أو تخريجات أو أسماء كتب أو أرقام صفحات أو أحكامًا قطعية، ولا تنسب قولًا إلى عالم دون يقين. إذا لم تعرف فقل لا أعلم أو وضّح موضع عدم اليقين. فرّق بين النص القرآني، والتفسير المنقول، والتأمل الشخصي، والمعلومة العامة، والفتوى. لا تدّعِ أنك بحثت في مصادر مباشرة. اشرح المعاني العامة بحذر ولا تقدّمها كتفسير معتمد. في المسائل الفقهية الشخصية أو الحساسة نبّه إلى اختلاف التفاصيل والمذاهب ووجّه لسؤال عالم موثوق. لا تطلب بيانات شخصية حساسة. اجعل الإجابة مفيدة ومختصرة غالبًا، واستخدم نقاطًا عند الحاجة.`;
const requestCounts = new Map();
function rateLimited(req) { const ip=(req.headers['x-forwarded-for']||req.socket.remoteAddress||'unknown').toString().split(',')[0].trim(); const now=Date.now(); const old=requestCounts.get(ip)||[]; const recent=old.filter(t=>now-t<60_000); if(recent.length>=12){requestCounts.set(ip,recent);return true;} recent.push(now);requestCounts.set(ip,recent);return false; }
function send(res, status, data, headers={}) { res.writeHead(status, {'content-type':'application/json; charset=utf-8','cache-control':'no-store', ...headers}); res.end(JSON.stringify(data)); }
function readBody(req) { return new Promise((resolve,reject)=>{let s=''; req.on('data',c=>{s+=c; if(s.length>12000){reject(new Error('body too large'));req.destroy();}}); req.on('end',()=>{try{resolve(JSON.parse(s||'{}'));}catch(e){reject(e);}}); req.on('error',reject);}); }
const server = http.createServer(async (req,res)=>{
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  if (req.method==='GET' && url.pathname==='/api/health') return send(res,200,{ok:true,aiConfigured:Boolean(API_KEY && SUPABASE_URL && SUPABASE_ANON_KEY),model:MODEL});
  if (req.method==='POST' && url.pathname==='/api/ask') {
    if (rateLimited(req)) return send(res,429,{error:'وصلت إلى عدد كبير من الأسئلة خلال دقيقة. انتظر قليلًا ثم حاول مجددًا.'});
    if (!API_KEY) return send(res,503,{error:'المساعد لم يُفعّل بعد. أضف OPENAI_API_KEY إلى إعدادات الخادم ثم أعد تشغيله.'});
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return send(res,503,{error:'يلزم إكمال إعداد Supabase في الخادم لتفعيل المساعد المحمي.'});
    const authHeader = req.headers.authorization || '';
    const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
    if (!token || token.length > 5000) return send(res,401,{error:'سجّل الدخول إلى أَثَر أولًا لاستخدام المساعد.'});
    try {
      const authRes = await fetch(SUPABASE_URL + '/auth/v1/user', {headers:{'apikey':SUPABASE_ANON_KEY,'Authorization':'Bearer '+token}});
      if (!authRes.ok) return send(res,401,{error:'انتهت جلسة الدخول. سجّل الدخول مجددًا.'});
    } catch { return send(res,503,{error:'تعذر التحقق من جلسة الحساب. حاول مجددًا.'}); }
    let body; try { body=await readBody(req); } catch { return send(res,400,{error:'تعذر قراءة السؤال. حاول مرة أخرى.'}); }
    const question=String(body.question||'').trim();
    if (!question) return send(res,400,{error:'اكتب سؤالك أولًا.'});
    if (question.length>4000) return send(res,413,{error:'السؤال طويل جدًا. اختصره ثم أعد المحاولة.'});
    const history=Array.isArray(body.messages)?body.messages.slice(-10).filter(m=>m&&['user','assistant'].includes(m.role)&&typeof m.content==='string').map(m=>({role:m.role,content:m.content.slice(0,4000)})):[];
    const input=[...history,{role:'user',content:question}];
    try {
      const upstream=await fetch('https://api.openai.com/v1/responses',{method:'POST',headers:{'Authorization':`Bearer ${API_KEY}`,'Content-Type':'application/json'},body:JSON.stringify({model:MODEL,instructions:SYSTEM,input,max_output_tokens:1000})});
      const data=await upstream.json().catch(()=>({}));
      if(!upstream.ok){ console.error('OpenAI API error',upstream.status,JSON.stringify(data).slice(0,1000)); return send(res,502,{error:'تعذر الحصول على إجابة الآن. تحقق من إعدادات خدمة الذكاء الاصطناعي وحاول لاحقًا.'}); }
      let answer='';
      if (Array.isArray(data.output)) for (const item of data.output) if(item.type==='message'&&Array.isArray(item.content)) for(const c of item.content) if(c.type==='output_text') answer+=c.text;
      if(!answer.trim()) return send(res,502,{error:'لم تصل إجابة قابلة للعرض. حاول مرة أخرى.'});
      return send(res,200,{answer:answer.trim(),notice:'إجابة مولّدة بالذكاء الاصطناعي وليست فتوى أو مصدرًا دينيًا موثّقًا. تحقّق من النصوص والأحكام من مصادرها الأصلية.'});
    } catch(e) { console.error(e); return send(res,502,{error:'تعذر الاتصال بخدمة الذكاء الاصطناعي. تحقق من اتصال الخادم وحاول مجددًا.'}); }
  }
  // Serve app files; do not expose .env or hidden files.
  let pathname=decodeURIComponent(url.pathname==='/'?'/index.html':url.pathname);
  if(pathname.includes('..') || pathname.startsWith('/.')) return send(res,404,{error:'Not found'});
  const file=path.join(ROOT,pathname);
  fs.readFile(file,(err,buf)=>{ if(err) return send(res,404,{error:'الملف غير موجود'}); res.writeHead(200,{'content-type':MIME[path.extname(file)]||'application/octet-stream','x-content-type-options':'nosniff','referrer-policy':'strict-origin-when-cross-origin','x-frame-options':'DENY','permissions-policy':'camera=(), microphone=(), geolocation=()','cache-control':path.basename(file)==='index.html'?'no-cache':'public, max-age=3600'}); res.end(buf); });
});
server.listen(PORT,()=>console.log(`Athar running on http://localhost:${PORT} (AI configured: ${Boolean(API_KEY && SUPABASE_URL && SUPABASE_ANON_KEY)})`));
