let TOKEN = null, ACC = [], rows = [];
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const cents = v => Math.round((Number(String(v).replace(/[^0-9.]/g,'')) || 0) * 100);      // hindari galat desimal
const rp = c => (c/100).toLocaleString('id-ID');
const today = () => { const d = new Date(); return new Date(d - d.getTimezoneOffset()*60000).toISOString().slice(0,10); };

let DEMO = false;
async function api(path, method='GET', body) {
  if (DEMO) return demoApi(path, method, body);
  let r, j;
  try {
    r = await fetch(path, {method, headers:{'Content-Type':'application/json', ...(TOKEN?{Authorization:'Bearer '+TOKEN}:{})}, body: body?JSON.stringify(body):undefined});
    j = await r.json();
  } catch (e) { const err = new Error('Backend tidak tersedia'); err.noBackend = true; throw err; }
  if (!r.ok) throw new Error(j.error || 'Gagal'); return j;
}

/* ===== Mode DEMO (tanpa server): aturan yang sama dijalankan di memori browser =====
   Dipakai otomatis bila backend Flask/PostgreSQL tidak ditemukan (mis. dibuka dari hosting statis).
   Pada mode ini data hilang saat halaman dimuat ulang; versi penuh memakai PostgreSQL. */
const D = { seq: 0, posted: [], audit: [], user: '', accounts: [
  ['1-1100','Kas',1],['1-1200','Bank',1],['1-3100','Peralatan Kantor',0],['2-1100','Utang Usaha',0],['2-2100','Utang Bank',0],
  ['6-1100','Beban Gaji',0],['6-1200','Beban Sewa',0],['6-1300','Beban Listrik, Air & Telepon',0],['6-1400','Beban Transportasi',0],['6-1500','Beban Perlengkapan Kantor',0]
].map(a=>({account_code:a[0],account_name:a[1],is_cash:!!a[2]})) };
const f2 = c => (c/100).toFixed(2);
async function sha(t){ const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t)); return [...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,'0')).join(''); }
const hashInput = (v, prev) => [v.journal_id, v.trx_date, v.reference_no, v.description, v.journal_type, v.cash_flow_activity||'-', v.created_by, v.created_at, v.reversal_of||'-',
  v.lines.map(l=>`${l.code}:${f2(Math.round(l.debit*100))}:${f2(Math.round(l.credit*100))}`).join(';'), prev||'GENESIS'].join('|');
function audit(action, v){ D.audit.unshift({log_id: D.audit.length+1, table_name:'journal_headers', action, record_id: v.journal_id, actor: D.user, logged_at: new Date().toISOString()}); D.audit.forEach((a,i)=>a.log_id = D.audit.length-i); }
async function seal(v){ const prev = D.posted.length ? D.posted[D.posted.length-1].hash_checksum : null; v.prev_hash = prev; v.post_seq = ++D.seq; v.hash_checksum = await sha(hashInput(v, prev)); D.posted.push(v); audit('INSERT', v); audit('UPDATE', v); }
async function demoApi(path, method, body){
  if (path === '/api/accounts') return D.accounts;
  if (path === '/api/vouchers' && method === 'GET') return D.posted.slice().reverse().map(v=>({...v, reversed: D.posted.some(x=>x.reversal_of===v.journal_id)}));
  if (path === '/api/audit') return D.audit.slice(0,30);
  if (path === '/api/verify') { let prev = null; const out = []; for (const v of D.posted) { out.push({reference_no:v.reference_no, post_seq:v.post_seq, hash_valid: v.hash_checksum === await sha(hashInput(v, v.prev_hash)), chain_valid: v.prev_hash === prev}); prev = v.hash_checksum; } return out; }
  if (path === '/api/vouchers' && method === 'POST') {
    const b = body, L = b.lines || [], d0 = new Date(), today0 = new Date(d0 - d0.getTimezoneOffset()*60000).toISOString().slice(0,10);
    if (b.trx_date > today0) throw new Error('Tanggal transaksi tidak boleh di masa depan.');
    if (!b.reference_no || !b.description) throw new Error('No. bukti dan deskripsi wajib diisi.');
    if (L.length < 2) throw new Error('Minimal 2 baris jurnal.');
    if (D.posted.some(x=>x.reference_no===b.reference_no)) throw new Error('No. bukti sudah dipakai.');
    let td=0, tc=0, cashCredit=false; const lines=[];
    for (const l of L) { const a = D.accounts.find(x=>x.account_code===l.account_code); if(!a) throw new Error('Akun '+l.account_code+' tidak ada di bagan akun.');
      const dr = cents(l.debit), cr = cents(l.credit);
      if ((dr>0) === (cr>0)) throw new Error('Setiap baris harus diisi tepat satu sisi (debit ATAU kredit).');
      if (a.is_cash && dr>0) throw new Error('Akun kas/bank ('+a.account_code+') hanya boleh di sisi KREDIT pada voucher kas keluar.');
      if (a.is_cash && cr>0) cashCredit = true; td+=dr; tc+=cr; lines.push({code:a.account_code, name:a.account_name, debit:dr/100, credit:cr/100}); }
    if (td !== tc) throw new Error('Jurnal tidak seimbang: Debit '+f2(td)+' <> Kredit '+f2(tc)+'.');
    if (!cashCredit) throw new Error('Voucher kas keluar harus mengkredit minimal satu akun kas/bank.');
    const v = {journal_id: D.posted.length+1, reference_no:b.reference_no, trx_date:b.trx_date, description:b.description, journal_type:'KAS_KELUAR', cash_flow_activity:b.activity,
      created_by: D.user, created_at: new Date().toISOString(), reversal_of: null, lines};
    await seal(v); return {journal_id:v.journal_id, reference_no:v.reference_no, created_by:v.created_by, created_at:v.created_at, hash_checksum:v.hash_checksum};
  }
  let m;
  if ((m = path.match(/^\/api\/vouchers\/(\d+)\/reverse$/))) {
    const o = D.posted.find(x=>x.journal_id===+m[1]);
    if (!o) throw new Error('Jurnal tidak ditemukan.');
    if (o.journal_type==='STORNO') throw new Error('Jurnal pembalik tidak boleh dibalik lagi.');
    if (!body.reason || !body.reason.trim()) throw new Error('Alasan storno wajib diisi.');
    if (D.posted.some(x=>x.reversal_of===o.journal_id)) throw new Error('Jurnal '+o.reference_no+' sudah pernah dibalik.');
    const d0 = new Date(), t0 = new Date(d0 - d0.getTimezoneOffset()*60000).toISOString().slice(0,10);
    const v = {journal_id: D.posted.length+1, reference_no:'STORNO-'+o.reference_no, trx_date:t0, description:'Pembalik atas '+o.reference_no+': '+body.reason, journal_type:'STORNO',
      cash_flow_activity:o.cash_flow_activity, created_by:D.user, created_at:new Date().toISOString(), reversal_of:o.journal_id,
      lines:o.lines.map(l=>({code:l.code,name:l.name,debit:l.credit,credit:l.debit}))};
    await seal(v); return {id:v.journal_id};
  }
  if ((m = path.match(/^\/api\/vouchers\/(\d+)$/))) {
    const o = D.posted.find(x=>x.journal_id===+m[1]);
    throw new Error('Jurnal '+o.reference_no+' sudah POSTED dan tidak boleh di-'+(method==='PUT'?'UPDATE':'DELETE')+'. Gunakan jurnal pembalik (storno).');
  }
  throw new Error('Endpoint tidak dikenal');
}

function show(el, cls, text){ el.className = 'msg ' + cls; el.textContent = text; }

async function login(){
  try {
    let j;
    try { j = await api('/api/login','POST',{username:$('lu').value,password:$('lp').value}); }
    catch(e){ if(!e.noBackend) throw e;
      if ($('lu').value !== 'rina@diponegoro-logistik.id' || $('lp').value !== 'kas12345') throw new Error('Username atau password salah.');
      DEMO = true; D.user = $('lu').value; j = {token:'demo', username:D.user, full_name:'Rina Kusuma (Staf Kas) · MODE DEMO'}; }
    TOKEN = j.token; $('whoName').textContent = j.full_name; $('who').classList.remove('hide');
    $('login').classList.add('hide'); $('app').classList.remove('hide'); await init();
  } catch(e){ show($('lmsg'),'err',e.message); }
}
function logout(){ TOKEN=null; location.reload(); }

async function init(){ ACC = await api('/api/accounts'); resetForm(); await loadV(); await loadA(); }
function newRef(){ const d=new Date(); return 'BKK-'+String(d.getFullYear()).slice(2)+String(d.getMonth()+1).padStart(2,'0')+'-'+String(Date.now()).slice(-4); }
function resetForm(){ $('fDate').value=today(); $('fRef').value=newRef(); $('fDesc').value=''; $('fAct').value='OPERASI'; rows=[{a:'',d:'',c:''},{a:'',d:'',c:''}]; drawLines(); calc(); $('msg').className='msg'; }
function addLine(){ rows.push({a:'',d:'',c:''}); drawLines(); calc(); }
function delLine(i){ if(rows.length>2){ rows.splice(i,1); drawLines(); calc(); } }
function drawLines(){
  $('lines').innerHTML = rows.map((r,i)=>`<tr><td>${i+1}</td>
   <td><select onchange="rows[${i}].a=this.value;calc()"><option value="">— pilih akun —</option>${ACC.map(a=>`<option value="${a.account_code}" ${a.account_code===r.a?'selected':''}>${a.account_code} · ${esc(a.account_name)}</option>`).join('')}</select></td>
   <td><input class="n" inputmode="decimal" value="${esc(r.d)}" placeholder="0" oninput="rows[${i}].d=this.value;calc()"></td>
   <td><input class="n" inputmode="decimal" value="${esc(r.c)}" placeholder="0" oninput="rows[${i}].c=this.value;calc()"></td>
   <td><button class="x" title="Hapus baris" onclick="delLine(${i})">×</button></td></tr>`).join('');
}
const isCash = code => (ACC.find(a=>a.account_code===code)||{}).is_cash;

function calc(){
  const tD = rows.reduce((s,r)=>s+cents(r.d),0), tC = rows.reduce((s,r)=>s+cents(r.c),0);
  $('tD').textContent = rp(tD); $('tC').textContent = rp(tC);
  const filled = rows.filter(r=>r.a || cents(r.d) || cents(r.c));
  const rules = [
    ['Tanggal, No. bukti, dan deskripsi terisi', $('fDate').value && $('fRef').value.trim() && $('fDesc').value.trim()],
    ['Tanggal tidak di masa depan', $('fDate').value && $('fDate').value <= today()],
    ['Minimal 2 baris jurnal terisi', filled.length >= 2],
    ['Tiap baris punya akun dan tepat satu sisi nominal (> 0)', filled.length>0 && filled.every(r=>r.a && ((cents(r.d)>0) !== (cents(r.c)>0)))],
    ['Akun kas/bank hanya di sisi KREDIT (kas keluar)', !filled.some(r=>isCash(r.a) && cents(r.d)>0)],
    ['Ada pengkreditan akun kas/bank', filled.some(r=>isCash(r.a) && cents(r.c)>0)],
    ['Total Debit = Total Kredit (zero-discrepancy)', tD>0 && tD===tC],
  ];
  $('rules').innerHTML = rules.map(r=>`<li class="${r[1]?'ok':''}">${r[0]}</li>`).join('');
  const bal = tD>0 && tD===tC;
  $('badge').className = 'badge ' + (bal?'ok':'bad');
  $('bTxt').textContent = bal ? 'SEIMBANG (BALANCED)' : 'TIDAK SEIMBANG';
  $('bDiff').textContent = 'Selisih: Rp ' + rp(Math.abs(tD-tC)) + (tD>tC?' (debit lebih)':tC>tD?' (kredit lebih)':'');
  $('btnSubmit').disabled = !rules.every(r=>r[1]);
}
['fDate','fRef','fDesc'].forEach(id=>document.addEventListener('input',e=>{ if(e.target.id===id) calc(); }));

async function submitV(){
  const lines = rows.filter(r=>r.a).map(r=>({account_code:r.a, debit:(cents(r.d)/100).toFixed(2), credit:(cents(r.c)/100).toFixed(2)}));
  try { const j = await api('/api/vouchers','POST',{trx_date:$('fDate').value, reference_no:$('fRef').value.trim(), description:$('fDesc').value.trim(), activity:$('fAct').value, lines});
    show($('msg'),'good',`Tersimpan & POSTED: ${j.reference_no} · dicatat oleh ${j.created_by} · hash ${j.hash_checksum.slice(0,12)}…`);
    resetForm(); show($('msg'),'good',`Tersimpan & POSTED: ${j.reference_no} · dicatat oleh ${j.created_by} · hash ${j.hash_checksum.slice(0,12)}…`);
    await loadV(); await loadA();
  } catch(e){ show($('msg'),'err','Ditolak database: '+e.message); }
}

async function loadV(){
  const list = await api('/api/vouchers');
  $('paneJ').innerHTML = list.length ? list.map(v=>`<div class="v ${v.journal_type==='STORNO'?'st':''}">
    <div class="row" style="justify-content:space-between"><b>${esc(v.reference_no)}</b>
      <span><span class="tag">${esc(v.cash_flow_activity||'-')}</span>${v.journal_type==='STORNO'?'<span class="tag s">STORNO</span>':''}${v.reversed?'<span class="tag r">dibalik</span>':''}</span></div>
    <div>${esc(v.trx_date)} · ${esc(v.description)}</div>
    <div style="margin:6px 0">${v.lines.map(l=>`<div class="vl"><span>${l.credit>0?'&nbsp;&nbsp;&nbsp;&nbsp;':''}${esc(l.code)} ${esc(l.name)}</span><span>${l.debit>0?rp(l.debit*100):rp(l.credit*100)} ${l.debit>0?'D':'K'}</span></div>`).join('')}</div>
    <div class="mono">created_by: ${esc(v.created_by)} · created_at: ${new Date(v.created_at).toLocaleString('id-ID')}<br>hash: ${esc(v.hash_checksum)}<br>prev: ${esc(v.prev_hash||'GENESIS')}</div>
    <div class="row" style="margin-top:8px">
      ${v.journal_type==='KAS_KELUAR'&&!v.reversed?`<button class="sm" onclick="storno(${v.journal_id})">Buat jurnal pembalik</button>`:''}
      <button class="sm" onclick="tryEdit(${v.journal_id})">Coba UBAH</button><button class="sm" onclick="tryDel(${v.journal_id})">Coba HAPUS</button></div></div>`).join('')
    : '<div style="color:var(--mut)">Belum ada jurnal terposting.</div>';
}
async function loadA(){
  const a = await api('/api/audit');
  $('paneA').innerHTML = a.length ? `<table><thead><tr><th>#</th><th>Aksi</th><th>Rekaman</th><th>Pengguna</th><th>Waktu</th></tr></thead><tbody>${a.map(r=>`<tr><td>${r.log_id}</td><td>${r.action}</td><td>${r.record_id}</td><td class="mono">${esc(r.actor)}</td><td class="mono">${new Date(r.logged_at).toLocaleTimeString('id-ID')}</td></tr>`).join('')}</tbody></table>` : '<div style="color:var(--mut)">Belum ada catatan.</div>';
}
function tab(t){ $('paneJ').classList.toggle('hide',t!=='J'); $('paneA').classList.toggle('hide',t!=='A'); $('tabJ').classList.toggle('on',t==='J'); $('tabA').classList.toggle('on',t==='A'); }
async function storno(id){ const reason = $('reason').value.trim(); if(!reason){ show($('vmsg'),'err','Isi alasan jurnal pembalik terlebih dahulu.'); $('reason').focus(); return; }
  try{ await api(`/api/vouchers/${id}/reverse`,'POST',{reason}); $('reason').value=''; show($('vmsg'),'good','Jurnal pembalik (storno) berhasil dibuat; jurnal asli tetap utuh sebagai jejak audit.'); await loadV(); await loadA(); }catch(e){ show($('vmsg'),'err','Ditolak: '+e.message); } }
async function tryEdit(id){ try{ await api('/api/vouchers/'+id,'PUT',{}); }catch(e){ show($('vmsg'),'err','UPDATE ditolak database: '+e.message); } }
async function tryDel(id){ try{ await api('/api/vouchers/'+id,'DELETE'); }catch(e){ show($('vmsg'),'err','DELETE ditolak database: '+e.message); } }
async function verify(){ const r = await api('/api/verify'); const bad = r.filter(x=>!x.hash_valid||!x.chain_valid);
  show($('vmsg'), bad.length?'err':'good', bad.length ? `PERINGATAN: ${bad.length} jurnal gagal verifikasi hash/rantai.` : `${r.length} jurnal terverifikasi: hash SHA-256 dan rantai prev_hash cocok.`); }
