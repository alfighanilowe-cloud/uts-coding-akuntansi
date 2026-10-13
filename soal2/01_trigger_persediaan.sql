-- ============================================================
-- SOAL 2 : Trigger persediaan perpetual + jurnal otomatis
-- Prasyarat: skema GL dari Soal 1 (01_skema_gl.sql) sudah dimuat
-- ============================================================
DROP TABLE IF EXISTS inventory_transactions, inventory_items CASCADE;

CREATE TABLE inventory_items (
    item_id    VARCHAR(10) PRIMARY KEY,
    item_name  VARCHAR(100),
    stock_qty  INT NOT NULL DEFAULT 0,
    unit_cost  NUMERIC(15,2) NOT NULL,
    CONSTRAINT chk_stock_nonneg CHECK (stock_qty >= 0)      -- lapis pengaman terakhir
);

CREATE TABLE inventory_transactions (
    trx_id    SERIAL PRIMARY KEY,
    item_id   VARCHAR(10) REFERENCES inventory_items(item_id),
    trx_type  VARCHAR(10) CHECK (trx_type IN ('PURCHASE','SALE','ADJUSTMENT')),
    qty       INT NOT NULL,
    trx_date  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Akun tambahan untuk selisih persediaan
INSERT INTO chart_of_accounts (account_code, account_name, normal_balance, report_class) VALUES
 ('4-9100','Pendapatan Selisih Persediaan','KREDIT','PENDAPATAN'),
 ('6-9100','Beban Selisih Persediaan','DEBIT','BEBAN')
ON CONFLICT (account_code) DO NOTHING;

-- Fungsi pembantu: membuat jurnal 2 baris dan langsung memposting
CREATE OR REPLACE FUNCTION fn_post_two_line_journal(
    p_ref TEXT, p_desc TEXT, p_dr_code TEXT, p_cr_code TEXT, p_amount NUMERIC)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO journal_headers (trx_date, reference_no, description)
         VALUES (CURRENT_DATE, p_ref, p_desc) RETURNING journal_id INTO v_id;
    INSERT INTO journal_lines (header_id, account_id, debit, credit)
         SELECT v_id, account_id, p_amount, 0 FROM chart_of_accounts WHERE account_code = p_dr_code;
    INSERT INTO journal_lines (header_id, account_id, debit, credit)
         SELECT v_id, account_id, 0, p_amount FROM chart_of_accounts WHERE account_code = p_cr_code;
    UPDATE journal_headers SET posting_status = 'POSTED' WHERE journal_id = v_id;
END $$;

CREATE OR REPLACE FUNCTION trg_update_stock_and_journal() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_item   inventory_items%ROWTYPE;
    v_delta  INT;
    v_new    INT;
    v_value  NUMERIC(18,2);
    v_ref    TEXT := 'INV-' || LPAD(NEW.trx_id::TEXT, 6, '0');
BEGIN
    -- validasi kuantitas
    IF NEW.trx_type IN ('PURCHASE','SALE') AND NEW.qty <= 0 THEN
        RAISE EXCEPTION 'Qty % untuk % harus lebih dari 0', NEW.qty, NEW.trx_type;
    ELSIF NEW.trx_type = 'ADJUSTMENT' AND NEW.qty = 0 THEN
        RAISE EXCEPTION 'Qty ADJUSTMENT tidak boleh 0';
    END IF;

    -- kunci baris barang agar transaksi lain menunggu (anti race condition)
    SELECT * INTO v_item FROM inventory_items WHERE item_id = NEW.item_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Barang % tidak ditemukan', NEW.item_id;
    END IF;

    v_delta := CASE NEW.trx_type WHEN 'SALE' THEN -NEW.qty ELSE NEW.qty END;
    v_new   := v_item.stock_qty + v_delta;

    -- (b) cegah persediaan negatif
    IF v_new < 0 THEN
        RAISE EXCEPTION 'Transaksi % dibatalkan: stok % hanya % unit, diminta % unit.',
            NEW.trx_type, v_item.item_id, v_item.stock_qty, ABS(v_delta)
            USING HINT = 'Periksa stok fisik atau catat PURCHASE terlebih dahulu.';
    END IF;

    -- (a) mutakhirkan stok
    UPDATE inventory_items SET stock_qty = v_new WHERE item_id = NEW.item_id;

    -- jurnal otomatis ke buku besar (satu transaksi yang sama)
    v_value := ABS(v_delta) * v_item.unit_cost;
    IF NEW.trx_type = 'PURCHASE' THEN
        PERFORM fn_post_two_line_journal(v_ref, 'Pembelian '||v_item.item_name, '1-1400','2-1100', v_value);
    ELSIF NEW.trx_type = 'SALE' THEN
        PERFORM fn_post_two_line_journal(v_ref, 'HPP penjualan '||v_item.item_name, '5-1100','1-1400', v_value);
    ELSIF v_delta > 0 THEN
        PERFORM fn_post_two_line_journal(v_ref, 'Selisih lebih opname '||v_item.item_name, '1-1400','4-9100', v_value);
    ELSE
        PERFORM fn_post_two_line_journal(v_ref, 'Selisih kurang opname '||v_item.item_name, '6-9100','1-1400', v_value);
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_update_stock_and_journal
    BEFORE INSERT ON inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION trg_update_stock_and_journal();

INSERT INTO inventory_items VALUES
 ('BRG-001','Rak Besi Gudang',0,275000),
 ('BRG-002','Lakban Industri',0,18000),
 ('BRG-003','Bubble Wrap Roll',0,95000);
