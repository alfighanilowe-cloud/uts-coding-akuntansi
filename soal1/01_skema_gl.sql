-- ============================================================
-- SOAL 1 : Skema General Ledger dengan integritas berpasangan
-- ============================================================
DROP TABLE IF EXISTS journal_lines, journal_headers, chart_of_accounts CASCADE;

-- 1) Bagan akun
CREATE TABLE chart_of_accounts (
    account_id        SERIAL        PRIMARY KEY,
    account_code      VARCHAR(10)   NOT NULL UNIQUE,
    account_name      VARCHAR(100)  NOT NULL,
    normal_balance    VARCHAR(6)    NOT NULL
                      CHECK (normal_balance IN ('DEBIT', 'KREDIT')),
    report_class      VARCHAR(20)   NOT NULL
                      CHECK (report_class IN ('ASET','LIABILITAS','EKUITAS','PENDAPATAN','BEBAN'))
);

-- 2) Header jurnal
CREATE TABLE journal_headers (
    journal_id        BIGSERIAL     PRIMARY KEY,
    trx_date          DATE          NOT NULL,
    reference_no      VARCHAR(30)   NOT NULL UNIQUE,
    description       TEXT          NOT NULL,
    posting_status    VARCHAR(6)    NOT NULL DEFAULT 'DRAFT'
                      CHECK (posting_status IN ('DRAFT', 'POSTED'))
);

-- 3) Baris jurnal
CREATE TABLE journal_lines (
    line_id           BIGSERIAL     PRIMARY KEY,
    header_id         BIGINT        NOT NULL
                      REFERENCES journal_headers (journal_id) ON DELETE RESTRICT,
    account_id        INT           NOT NULL
                      REFERENCES chart_of_accounts (account_id) ON DELETE RESTRICT,
    debit             NUMERIC(18,2) NOT NULL DEFAULT 0,
    credit            NUMERIC(18,2) NOT NULL DEFAULT 0,
    CONSTRAINT chk_debit_nonneg   CHECK (debit  >= 0),
    CONSTRAINT chk_credit_nonneg  CHECK (credit >= 0),
    CONSTRAINT chk_not_both_zero  CHECK (NOT (debit = 0 AND credit = 0))
);
CREATE INDEX idx_lines_header  ON journal_lines (header_id);
CREATE INDEX idx_lines_account ON journal_lines (account_id);

-- 4) Penegakan Debit = Kredit di level database (bukan frontend)
--    Jurnal hanya boleh berstatus POSTED jika sum(debit) = sum(credit) dan >= 2 baris.
CREATE OR REPLACE FUNCTION fn_enforce_balanced_posting() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_debit  NUMERIC(18,2);
    v_credit NUMERIC(18,2);
    v_rows   INT;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.posting_status = 'POSTED' THEN
        RAISE EXCEPTION 'Jurnal % harus dibuat DRAFT lebih dulu, baru diposting setelah baris diisi.', NEW.reference_no;
    END IF;

    IF NEW.posting_status = 'POSTED' AND OLD.posting_status IS DISTINCT FROM 'POSTED' THEN
        SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0), COUNT(*)
          INTO v_debit, v_credit, v_rows
          FROM journal_lines WHERE header_id = NEW.journal_id;

        IF v_rows < 2 THEN
            RAISE EXCEPTION 'Posting ditolak: jurnal % hanya punya % baris (minimal 2).', NEW.reference_no, v_rows;
        END IF;
        IF v_debit <> v_credit THEN
            RAISE EXCEPTION 'Posting ditolak: jurnal % tidak seimbang (Debit % <> Kredit %).',
                            NEW.reference_no, v_debit, v_credit;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_balanced_posting
    BEFORE INSERT OR UPDATE OF posting_status ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_enforce_balanced_posting();

-- Baris tidak boleh ditambah/diubah/dihapus pada jurnal yang sudah POSTED
CREATE OR REPLACE FUNCTION fn_lock_posted_lines() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_hid BIGINT; v_status TEXT;
BEGIN
    v_hid := COALESCE(NEW.header_id, OLD.header_id);
    SELECT posting_status INTO v_status FROM journal_headers WHERE journal_id = v_hid;
    IF v_status = 'POSTED' THEN
        RAISE EXCEPTION 'Jurnal % sudah POSTED; baris tidak boleh di-% (gunakan jurnal pembalik).', v_hid, TG_OP;
    END IF;
    RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER trg_lock_posted_lines
    BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION fn_lock_posted_lines();

-- Data bagan akun contoh
INSERT INTO chart_of_accounts (account_code, account_name, normal_balance, report_class) VALUES
 ('1-1100','Kas',                         'DEBIT', 'ASET'),
 ('1-1200','Bank',                        'DEBIT', 'ASET'),
 ('1-1400','Persediaan Barang Dagang',    'DEBIT', 'ASET'),
 ('1-2900','Akumulasi Penyusutan',        'KREDIT','ASET'),
 ('2-1100','Utang Usaha',                 'KREDIT','LIABILITAS'),
 ('3-1100','Modal Disetor',               'KREDIT','EKUITAS'),
 ('4-1100','Penjualan',                   'KREDIT','PENDAPATAN'),
 ('5-1100','Beban Pokok Pendapatan',      'DEBIT', 'BEBAN'),
 ('6-1100','Beban Sewa',                  'DEBIT', 'BEBAN'),
 ('6-1200','Beban Listrik, Air & Telepon','DEBIT', 'BEBAN'),
 ('6-1300','Beban Transportasi',          'DEBIT', 'BEBAN');
