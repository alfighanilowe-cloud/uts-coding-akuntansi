\set ON_ERROR_STOP off
\echo '=== UJI 1: PURCHASE 15 rak @275.000'
INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('BRG-001','PURCHASE',15);
\echo '=== UJI 2: SALE 6 rak'
INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('BRG-001','SALE',6);
\echo '=== UJI 3: ADJUSTMENT -2 (rusak saat opname)'
INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('BRG-001','ADJUSTMENT',-2);
\echo '=== UJI 4: SALE 9 padahal stok 7 -> HARUS DITOLAK'
INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('BRG-001','SALE',9);
\echo '=== UJI 5: SALE qty negatif -> HARUS DITOLAK'
INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('BRG-001','SALE',-3);
\echo '=== UJI 6: Dua SALE (4+4) dalam satu transaksi -> yang kedua gagal, semua rollback'
BEGIN;
INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('BRG-001','SALE',4);
INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('BRG-001','SALE',4);
COMMIT;
\echo '=== UJI 7: UPDATE langsung stok jadi negatif (bypass trigger) -> DITOLAK CHECK'
UPDATE inventory_items SET stock_qty = -1 WHERE item_id='BRG-001';
\echo '=== POSISI STOK'
SELECT item_id, item_name, stock_qty, unit_cost, stock_qty*unit_cost AS nilai FROM inventory_items ORDER BY 1;
\echo '=== JURNAL OTOMATIS'
SELECT h.reference_no, a.account_code, a.account_name, l.debit, l.credit
 FROM journal_headers h JOIN journal_lines l ON l.header_id=h.journal_id
 JOIN chart_of_accounts a USING (account_id) WHERE h.reference_no LIKE 'INV-%' ORDER BY h.journal_id, l.line_id;
\echo '=== REKONSILIASI: saldo GL Persediaan vs nilai stok fisik'
SELECT (SELECT SUM(l.debit-l.credit) FROM journal_lines l JOIN chart_of_accounts a USING(account_id) WHERE a.account_code='1-1400') AS saldo_gl,
       (SELECT SUM(stock_qty*unit_cost) FROM inventory_items) AS nilai_stok_fisik;
