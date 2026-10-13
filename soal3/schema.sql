-- ============================================================
-- SOAL 3 : Voucher Kas Keluar - skema, audit trail & immutability
-- PostgreSQL 16 (kompatibel Supabase: tempel di SQL Editor)
-- ============================================================
DROP TABLE IF EXISTS audit_log, journal_lines, journal_headers, chart_of_accounts, app_users CASCADE;
DROP SEQUENCE IF EXISTS seq_post;

CREATE TABLE app_users (
    username   VARCHAR(30) PRIMARY KEY,
    full_name  VARCHAR(80) NOT NULL,
    pass_salt  TEXT NOT NULL,
    pass_hash  TEXT NOT NULL
);

CREATE TABLE chart_of_accounts (
    account_id     SERIAL PRIMARY KEY,
    account_code   VARCHAR(10) NOT NULL UNIQUE,
    account_name   VARCHAR(100) NOT NULL,
    normal_balance VARCHAR(6) NOT NULL CHECK (normal_balance IN ('DEBIT','KREDIT')),
    report_class   VARCHAR(20) NOT NULL CHECK (report_class IN ('ASET','LIABILITAS','EKUITAS','PENDAPATAN','BEBAN')),
    is_cash        BOOLEAN NOT NULL DEFAULT FALSE        -- akun Kas / Bank (kas & setara kas)
);

CREATE SEQUENCE seq_post;

CREATE TABLE journal_headers (
    journal_id         BIGSERIAL PRIMARY KEY,
    trx_date           DATE NOT NULL,
    reference_no       VARCHAR(30) NOT NULL UNIQUE,
    description        TEXT NOT NULL,
    journal_type       VARCHAR(12) NOT NULL DEFAULT 'KAS_KELUAR' CHECK (journal_type IN ('KAS_KELUAR','STORNO')),
    cash_flow_activity VARCHAR(10) CHECK (cash_flow_activity IN ('OPERASI','INVESTASI','PENDANAAN')),
    posting_status     VARCHAR(6) NOT NULL DEFAULT 'DRAFT' CHECK (posting_status IN ('DRAFT','POSTED')),
    reversal_of        BIGINT UNIQUE REFERENCES journal_headers(journal_id) ON DELETE RESTRICT,
    created_by         VARCHAR(60) NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    posted_at          TIMESTAMPTZ,
    post_seq           BIGINT UNIQUE,
    prev_hash          CHAR(64),
    hash_checksum      CHAR(64)
);

CREATE TABLE journal_lines (
    line_id    BIGSERIAL PRIMARY KEY,
    header_id  BIGINT NOT NULL REFERENCES journal_headers(journal_id) ON DELETE RESTRICT,
    account_id INT    NOT NULL REFERENCES chart_of_accounts(account_id) ON DELETE RESTRICT,
    debit      NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (debit  >= 0),
    credit     NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    CONSTRAINT chk_not_both_zero CHECK (NOT (debit = 0 AND credit = 0))
);
CREATE INDEX ON journal_lines(header_id);

CREATE TABLE audit_log (
    log_id     BIGSERIAL PRIMARY KEY,
    table_name TEXT NOT NULL,
    action     TEXT NOT NULL,
    record_id  TEXT,
    actor      TEXT,
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    old_data   JSONB,
    new_data   JSONB
);

-- ---------- utilitas ----------
CREATE OR REPLACE FUNCTION fn_actor() RETURNS TEXT LANGUAGE sql STABLE AS
$$ SELECT COALESCE(NULLIF(current_setting('app.user', true), ''), session_user) $$;

-- Hash SHA-256 sebuah jurnal (dipakai saat posting & saat verifikasi)
CREATE OR REPLACE FUNCTION fn_journal_hash(p_id BIGINT, p_prev TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT encode(sha256(convert_to(
      h.journal_id || '|' || h.trx_date || '|' || h.reference_no || '|' || h.description || '|' ||
      h.journal_type || '|' || COALESCE(h.cash_flow_activity,'-') || '|' || h.created_by || '|' ||
      to_char(h.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US') || '|' ||
      COALESCE(h.reversal_of::text,'-') || '|' ||
      COALESCE((SELECT string_agg(a.account_code || ':' || l.debit || ':' || l.credit, ';' ORDER BY l.line_id)
                  FROM journal_lines l JOIN chart_of_accounts a USING (account_id)
                 WHERE l.header_id = h.journal_id), '') || '|' || COALESCE(p_prev,'GENESIS'),
      'UTF8')), 'hex')
  FROM journal_headers h WHERE h.journal_id = p_id
$$;

-- ---------- trigger header ----------
CREATE OR REPLACE FUNCTION fn_header_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_d NUMERIC; v_c NUMERIC; v_n INT; v_prev TEXT;
BEGIN
  IF TG_OP = 'INSERT' THEN
     IF NEW.posting_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Jurnal baru wajib berstatus DRAFT; posting dilakukan setelah baris terisi.'; END IF;
     NEW.created_by := fn_actor();            -- nilai dari klien diabaikan
     NEW.created_at := now();                 -- jam server
     NEW.posted_at := NULL; NEW.post_seq := NULL; NEW.hash_checksum := NULL; NEW.prev_hash := NULL;  -- diisi hanya saat posting
     RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
     IF OLD.posting_status = 'POSTED' THEN
        RAISE EXCEPTION 'Jurnal % sudah POSTED dan tidak boleh di-DELETE. Gunakan jurnal pembalik (storno).', OLD.reference_no; END IF;
     RETURN OLD;
  END IF;

  -- UPDATE
  IF OLD.posting_status = 'POSTED' THEN
     RAISE EXCEPTION 'Jurnal % sudah POSTED dan tidak boleh di-UPDATE. Gunakan jurnal pembalik (storno).', OLD.reference_no; END IF;
  IF NEW.created_by IS DISTINCT FROM OLD.created_by OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
     RAISE EXCEPTION 'created_by dan created_at tidak dapat diubah.'; END IF;

  IF NEW.posting_status = 'POSTED' THEN          -- DRAFT -> POSTED : validasi lalu segel
     SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0), COUNT(*) INTO v_d, v_c, v_n
       FROM journal_lines WHERE header_id = NEW.journal_id;
     IF v_n < 2 THEN RAISE EXCEPTION 'Posting ditolak: minimal 2 baris jurnal.'; END IF;
     IF v_d <> v_c OR v_d = 0 THEN
        RAISE EXCEPTION 'Posting ditolak: jurnal tidak seimbang (Debit % <> Kredit %).', v_d, v_c; END IF;
     PERFORM pg_advisory_xact_lock(7771);        -- serialisasi rantai hash
     SELECT hash_checksum INTO v_prev FROM journal_headers
      WHERE posting_status='POSTED' ORDER BY post_seq DESC LIMIT 1;
     NEW.posted_at := now();
     NEW.post_seq  := nextval('seq_post');
     NEW.prev_hash := v_prev;
     -- hash membaca data header (tidak berubah sejak DRAFT) dan baris jurnal yang sudah final
     NEW.hash_checksum := fn_journal_hash(NEW.journal_id, v_prev);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_header_guard BEFORE INSERT OR UPDATE OR DELETE ON journal_headers
  FOR EACH ROW EXECUTE FUNCTION fn_header_guard();

-- ---------- trigger baris ----------
CREATE OR REPLACE FUNCTION fn_lines_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT := COALESCE(NEW.header_id, OLD.header_id); v_st TEXT;
BEGIN
  SELECT posting_status INTO v_st FROM journal_headers WHERE journal_id = v_id;
  IF v_st = 'POSTED' THEN
     RAISE EXCEPTION 'Baris milik jurnal POSTED tidak boleh di-% . Gunakan jurnal pembalik (storno).', TG_OP; END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER trg_lines_guard BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION fn_lines_guard();

-- TRUNCATE melewati trigger baris -> diblokir tersendiri
CREATE OR REPLACE FUNCTION fn_no_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'TRUNCATE pada tabel % dilarang (jejak audit).', TG_TABLE_NAME; END $$;
CREATE TRIGGER trg_nt_headers BEFORE TRUNCATE ON journal_headers FOR EACH STATEMENT EXECUTE FUNCTION fn_no_truncate();
CREATE TRIGGER trg_nt_lines   BEFORE TRUNCATE ON journal_lines   FOR EACH STATEMENT EXECUTE FUNCTION fn_no_truncate();
CREATE TRIGGER trg_nt_audit   BEFORE TRUNCATE ON audit_log       FOR EACH STATEMENT EXECUTE FUNCTION fn_no_truncate();

-- ---------- audit log (append-only) ----------
CREATE OR REPLACE FUNCTION fn_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO audit_log(table_name, action, record_id, actor, old_data, new_data)
  VALUES (TG_TABLE_NAME, TG_OP,
          COALESCE((to_jsonb(NEW)->>'journal_id'), (to_jsonb(NEW)->>'line_id'), (to_jsonb(OLD)->>'journal_id'), (to_jsonb(OLD)->>'line_id')),
          fn_actor(),
          CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END);
  RETURN NULL;
END $$;
CREATE TRIGGER trg_audit_h AFTER INSERT OR UPDATE OR DELETE ON journal_headers FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_l AFTER INSERT OR UPDATE OR DELETE ON journal_lines   FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE FUNCTION fn_audit_readonly() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'audit_log bersifat append-only: % ditolak.', TG_OP; END $$;
CREATE TRIGGER trg_audit_ro BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION fn_audit_readonly();

-- ---------- RPC / fungsi backend ----------
-- Voucher Kas Keluar. p_lines = [{"account_code":"6-1200","debit":"750000","credit":"0"}, ...]
CREATE OR REPLACE FUNCTION rpc_create_cash_voucher(
    p_date DATE, p_ref TEXT, p_desc TEXT, p_activity TEXT, p_lines JSONB)
RETURNS TABLE (journal_id BIGINT, reference_no TEXT, created_by TEXT, created_at TIMESTAMPTZ, hash_checksum TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; r JSONB; v_acc RECORD; v_d NUMERIC := 0; v_c NUMERIC := 0; v_dr NUMERIC; v_cr NUMERIC;
BEGIN
  IF p_date > CURRENT_DATE THEN RAISE EXCEPTION 'Tanggal transaksi tidak boleh di masa depan.'; END IF;
  IF COALESCE(btrim(p_ref),'') = '' OR COALESCE(btrim(p_desc),'') = '' THEN
     RAISE EXCEPTION 'No. bukti dan deskripsi wajib diisi.'; END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) < 2 THEN
     RAISE EXCEPTION 'Minimal 2 baris jurnal.'; END IF;

  -- validasi aturan bisnis kas keluar (ulang di sisi server)
  FOR r IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
     SELECT * INTO v_acc FROM chart_of_accounts WHERE account_code = r->>'account_code';
     IF NOT FOUND THEN RAISE EXCEPTION 'Akun % tidak ada di bagan akun.', r->>'account_code'; END IF;
     v_dr := COALESCE((r->>'debit')::numeric,0); v_cr := COALESCE((r->>'credit')::numeric,0);
     IF v_dr < 0 OR v_cr < 0 THEN RAISE EXCEPTION 'Nominal tidak boleh negatif.'; END IF;
     IF (v_dr > 0) = (v_cr > 0) THEN RAISE EXCEPTION 'Setiap baris harus diisi tepat satu sisi (debit ATAU kredit).'; END IF;
     IF v_acc.is_cash AND v_dr > 0 THEN
        RAISE EXCEPTION 'Akun kas/bank (%) hanya boleh di sisi KREDIT pada voucher kas keluar.', v_acc.account_code; END IF;
     v_d := v_d + v_dr; v_c := v_c + v_cr;
  END LOOP;
  IF v_d <> v_c THEN RAISE EXCEPTION 'Jurnal tidak seimbang: Debit % <> Kredit %.', v_d, v_c; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) e JOIN chart_of_accounts a ON a.account_code = e->>'account_code'
                  WHERE a.is_cash AND COALESCE((e->>'credit')::numeric,0) > 0) THEN
     RAISE EXCEPTION 'Voucher kas keluar harus mengkredit minimal satu akun kas/bank.'; END IF;

  INSERT INTO journal_headers(trx_date, reference_no, description, journal_type, cash_flow_activity, created_by)
       VALUES (p_date, p_ref, p_desc, 'KAS_KELUAR', p_activity, 'x') RETURNING journal_headers.journal_id INTO v_id;
  INSERT INTO journal_lines(header_id, account_id, debit, credit)
       SELECT v_id, a.account_id, COALESCE((e->>'debit')::numeric,0), COALESCE((e->>'credit')::numeric,0)
         FROM jsonb_array_elements(p_lines) WITH ORDINALITY t(e, n)
         JOIN chart_of_accounts a ON a.account_code = e->>'account_code' ORDER BY n;
  UPDATE journal_headers h SET posting_status='POSTED' WHERE h.journal_id = v_id;
  RETURN QUERY SELECT h.journal_id, h.reference_no::text, h.created_by::text, h.created_at, h.hash_checksum::text
                 FROM journal_headers h WHERE h.journal_id = v_id;
END $$;

-- Jurnal pembalik (storno)
CREATE OR REPLACE FUNCTION rpc_reverse_journal(p_id BIGINT, p_reason TEXT) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE o journal_headers%ROWTYPE; v_new BIGINT;
BEGIN
  SELECT * INTO o FROM journal_headers WHERE journal_id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jurnal % tidak ditemukan.', p_id; END IF;
  IF o.posting_status <> 'POSTED' THEN RAISE EXCEPTION 'Hanya jurnal POSTED yang dapat dibalik.'; END IF;
  IF o.journal_type = 'STORNO' THEN RAISE EXCEPTION 'Jurnal pembalik tidak boleh dibalik lagi.'; END IF;
  IF COALESCE(btrim(p_reason),'') = '' THEN RAISE EXCEPTION 'Alasan storno wajib diisi.'; END IF;
  IF EXISTS (SELECT 1 FROM journal_headers WHERE reversal_of = p_id) THEN
     RAISE EXCEPTION 'Jurnal % sudah pernah dibalik.', o.reference_no; END IF;

  INSERT INTO journal_headers(trx_date, reference_no, description, journal_type, cash_flow_activity, reversal_of, created_by)
       VALUES (CURRENT_DATE, 'STORNO-' || o.reference_no, 'Pembalik atas ' || o.reference_no || ': ' || p_reason,
               'STORNO', o.cash_flow_activity, p_id, 'x') RETURNING journal_id INTO v_new;
  INSERT INTO journal_lines(header_id, account_id, debit, credit)
       SELECT v_new, account_id, credit, debit FROM journal_lines WHERE header_id = p_id ORDER BY line_id;
  UPDATE journal_headers SET posting_status='POSTED' WHERE journal_id = v_new;
  RETURN v_new;
END $$;

-- Verifikasi integritas seluruh jurnal POSTED (hash + rantai)
CREATE OR REPLACE FUNCTION rpc_verify_integrity()
RETURNS TABLE (reference_no TEXT, post_seq BIGINT, hash_valid BOOLEAN, chain_valid BOOLEAN)
LANGUAGE sql STABLE AS $$
  SELECT h.reference_no::text, h.post_seq,
         h.hash_checksum = fn_journal_hash(h.journal_id, h.prev_hash),
         h.prev_hash IS NOT DISTINCT FROM LAG(h.hash_checksum) OVER (ORDER BY h.post_seq)
    FROM journal_headers h WHERE h.posting_status='POSTED' ORDER BY h.post_seq
$$;

-- ---------- data awal ----------
INSERT INTO chart_of_accounts(account_code, account_name, normal_balance, report_class, is_cash) VALUES
 ('1-1100','Kas','DEBIT','ASET',TRUE),
 ('1-1200','Bank','DEBIT','ASET',TRUE),
 ('1-3100','Peralatan Kantor','DEBIT','ASET',FALSE),
 ('2-1100','Utang Usaha','KREDIT','LIABILITAS',FALSE),
 ('2-2100','Utang Bank','KREDIT','LIABILITAS',FALSE),
 ('6-1100','Beban Gaji','DEBIT','BEBAN',FALSE),
 ('6-1200','Beban Sewa','DEBIT','BEBAN',FALSE),
 ('6-1300','Beban Listrik, Air & Telepon','DEBIT','BEBAN',FALSE),
 ('6-1400','Beban Transportasi','DEBIT','BEBAN',FALSE),
 ('6-1500','Beban Perlengkapan Kantor','DEBIT','BEBAN',FALSE);
