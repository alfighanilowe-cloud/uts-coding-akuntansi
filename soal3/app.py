"""Backend Voucher Kas Keluar (Python + Flask) - prototipe.
Seluruh aturan inti (seimbang, immutability, hash, audit) ada di database PostgreSQL.
Server hanya: login, meneruskan identitas pengguna dari SESI, dan memanggil fungsi RPC.
Catatan: untuk lingkungan tanpa driver, query dijalankan lewat psql (nilai dikirim sebagai
variabel psql :'nama' sehingga otomatis ter-quote -> aman dari SQL injection)."""
import hashlib, json, os, secrets, subprocess
from flask import Flask, request, jsonify, send_from_directory

PG = ["psql", "-h", os.environ.get("PGHOST", "/tmp"), "-p", os.environ.get("PGPORT", "5433"),
      "-U", "postgres", "-d", os.environ.get("PGDATABASE", "uts_soal3"),
      "-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1"]
app = Flask(__name__, static_folder="public", static_url_path="")
SESSIONS = {}

class DbError(Exception): pass

def run(sql, params=None, user=None, write=False):
    """Jalankan SQL (satu transaksi). Mengembalikan hasil JSON dari query terakhir."""
    params = params or {}
    script = ""
    if user is not None:
        script += "\\o /dev/null\nBEGIN;\nSELECT set_config('app.user', :'_user', true);\n\\o\n"
        params = {**params, "_user": user}
    script += sql.strip().rstrip(";") + ";\n"
    if user is not None: script += "COMMIT;\n"
    cmd = PG[:]
    for k, v in params.items(): cmd += ["-v", f"{k}={v}"]
    p = subprocess.run(cmd, input=script, capture_output=True, text=True)
    if p.returncode != 0:
        msg = next((l for l in p.stderr.splitlines() if "ERROR:" in l), p.stderr).split("ERROR:", 1)[-1].strip()
        raise DbError(msg)
    out = p.stdout.strip()
    return json.loads(out) if out else None

def pw_hash(pw, salt): return hashlib.scrypt(pw.encode(), salt=salt.encode(), n=2**14, r=8, p=1).hex()

def current_user():
    tok = request.headers.get("Authorization", "").replace("Bearer ", "")
    return SESSIONS.get(tok)

def guarded(fn):
    def w(*a, **k):
        u = current_user()
        if not u: return jsonify(error="Belum login."), 401
        try: return fn(u, *a, **k)
        except DbError as e: return jsonify(error=str(e)), 400
    w.__name__ = fn.__name__
    return w

@app.get("/")
def index(): return send_from_directory("public", "index.html")

@app.post("/api/login")
def login():
    b = request.get_json()
    row = run("SELECT row_to_json(u) FROM app_users u WHERE username = :'u'", {"u": b.get("username", "")})
    if not row or pw_hash(b.get("password", ""), row["pass_salt"]) != row["pass_hash"]:
        return jsonify(error="Username atau password salah."), 401
    tok = secrets.token_hex(24); SESSIONS[tok] = row["username"]
    return jsonify(token=tok, username=row["username"], full_name=row["full_name"])

@app.get("/api/accounts")
@guarded
def accounts(u):
    return jsonify(run("SELECT json_agg(a ORDER BY account_code) FROM (SELECT account_code, account_name, is_cash FROM chart_of_accounts) a"))

@app.post("/api/vouchers")
@guarded
def create(u):
    b = request.get_json()   # created_by dari klien (jika ada) DIABAIKAN; identitas dari sesi
    r = run("SELECT row_to_json(t) FROM rpc_create_cash_voucher(:'d', :'ref', :'desc', :'act', :'lines'::jsonb) t",
            {"d": b["trx_date"], "ref": b["reference_no"], "desc": b["description"],
             "act": b["activity"], "lines": json.dumps(b["lines"])}, user=u)
    return jsonify(r)

@app.get("/api/vouchers")
@guarded
def vouchers(u):
    return jsonify(run("""
      SELECT COALESCE(json_agg(x ORDER BY x.post_seq DESC), '[]') FROM (
        SELECT h.journal_id, h.reference_no, h.trx_date::text AS trx_date, h.description, h.journal_type,
               h.cash_flow_activity, h.created_by, h.created_at, h.post_seq, h.hash_checksum, h.prev_hash, h.reversal_of,
               EXISTS (SELECT 1 FROM journal_headers z WHERE z.reversal_of = h.journal_id) AS reversed,
               (SELECT json_agg(json_build_object('code', a.account_code, 'name', a.account_name, 'debit', l.debit, 'credit', l.credit) ORDER BY l.line_id)
                  FROM journal_lines l JOIN chart_of_accounts a USING (account_id) WHERE l.header_id = h.journal_id) AS lines
          FROM journal_headers h WHERE h.posting_status = 'POSTED') x"""))

@app.post("/api/vouchers/<int:jid>/reverse")
@guarded
def reverse(u, jid):
    r = run("SELECT json_build_object('id', rpc_reverse_journal(:'id'::bigint, :'reason'))",
            {"id": str(jid), "reason": request.get_json().get("reason", "")}, user=u)
    return jsonify(r)

# Endpoint uji: mencoba UBAH / HAPUS jurnal POSTED -> harus ditolak trigger database
@app.put("/api/vouchers/<int:jid>")
@guarded
def try_update(u, jid):
    run("UPDATE journal_headers SET description = :'d' WHERE journal_id = :'id'::bigint",
        {"d": "diubah diam-diam", "id": str(jid)}, user=u)
    return jsonify(ok=True)

@app.delete("/api/vouchers/<int:jid>")
@guarded
def try_delete(u, jid):
    run("DELETE FROM journal_headers WHERE journal_id = :'id'::bigint", {"id": str(jid)}, user=u)
    return jsonify(ok=True)

@app.get("/api/verify")
@guarded
def verify(u):
    return jsonify(run("SELECT COALESCE(json_agg(v), '[]') FROM rpc_verify_integrity() v"))

@app.get("/api/audit")
@guarded
def audit(u):
    return jsonify(run("""SELECT COALESCE(json_agg(a), '[]') FROM (
        SELECT log_id, table_name, action, record_id, actor, logged_at FROM audit_log
         WHERE table_name = 'journal_headers' ORDER BY log_id DESC LIMIT 30) a"""))

if __name__ == "__main__":
    app.run(port=int(os.environ.get("PORT", 5000)))
