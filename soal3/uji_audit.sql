\set ON_ERROR_STOP off
SELECT set_config('app.user','rina@diponegoro-logistik.id',false) \gset
\echo '=== UJI 1: Voucher seimbang via RPC (Beban Listrik 750.000 + Beban Transportasi 250.000 / Bank 1.000.000)'
SELECT journal_id, reference_no, created_by, left(hash_checksum,16)||'...' AS hash FROM rpc_create_cash_voucher('2026-10-12','BKK-2610-001','Bayar listrik & transport Oktober','OPERASI',
 '[{"account_code":"6-1300","debit":"750000","credit":"0"},{"account_code":"6-1400","debit":"250000","credit":"0"},{"account_code":"1-1200","debit":"0","credit":"1000000"}]');
\echo '=== UJI 2: Tidak seimbang -> DITOLAK'
SELECT * FROM rpc_create_cash_voucher('2026-10-12','BKK-2610-002','Uji tidak seimbang','OPERASI',
 '[{"account_code":"6-1300","debit":"900000","credit":"0"},{"account_code":"1-1100","debit":"0","credit":"800000"}]');
\echo '=== UJI 3: Mendebit akun Kas -> DITOLAK'
SELECT * FROM rpc_create_cash_voucher('2026-10-12','BKK-2610-003','Uji debit kas','OPERASI',
 '[{"account_code":"1-1100","debit":"500000","credit":"0"},{"account_code":"1-1200","debit":"0","credit":"500000"}]');
\echo '=== UJI 4: Tanggal masa depan -> DITOLAK'
SELECT * FROM rpc_create_cash_voucher('2027-01-01','BKK-2610-004','Uji tanggal','OPERASI',
 '[{"account_code":"6-1300","debit":"100","credit":"0"},{"account_code":"1-1100","debit":"0","credit":"100"}]');
\echo '=== UJI 5: UPDATE jurnal POSTED -> DITOLAK'
UPDATE journal_headers SET description='diubah diam-diam' WHERE reference_no='BKK-2610-001';
\echo '=== UJI 6: DELETE jurnal POSTED -> DITOLAK'
DELETE FROM journal_headers WHERE reference_no='BKK-2610-001';
\echo '=== UJI 7: UPDATE & INSERT baris pada jurnal POSTED -> DITOLAK'
UPDATE journal_lines SET debit = 1 WHERE header_id = 1;
INSERT INTO journal_lines(header_id, account_id, debit, credit) VALUES (1, 1, 5, 0);
\echo '=== UJI 8: TRUNCATE -> DITOLAK'
TRUNCATE journal_lines;
\echo '=== UJI 9: Klien memalsukan created_by (direktur@palsu.com) lewat INSERT langsung -> dioverride server'
INSERT INTO journal_headers(trx_date, reference_no, description, created_by, created_at) VALUES ('2026-10-12','DRAFT-X','uji palsu','direktur@palsu.com','2020-01-01');
SELECT reference_no, created_by, created_at::date AS created_at FROM journal_headers WHERE reference_no='DRAFT-X';
\echo '=== UJI 10: Storno jurnal POSTED -> BERHASIL; storno kedua kali -> DITOLAK'
SELECT rpc_reverse_journal(1, 'Salah input nominal listrik');
SELECT rpc_reverse_journal(1, 'Coba lagi');
\echo '=== UJI 11: Isi jurnal pembalik (debit/kredit tertukar)'
SELECT h.reference_no, h.journal_type, h.reversal_of, a.account_code, l.debit, l.credit FROM journal_headers h JOIN journal_lines l ON l.header_id=h.journal_id JOIN chart_of_accounts a USING(account_id) WHERE h.posting_status='POSTED' ORDER BY h.journal_id, l.line_id;
\echo '=== UJI 12: Verifikasi hash seluruh jurnal POSTED'
SELECT reference_no, post_seq, hash_valid, chain_valid FROM rpc_verify_integrity();
\echo '=== UJI 13: Simulasi peretas/DBA mematikan trigger lalu mengubah nominal langsung'
BEGIN;
ALTER TABLE journal_lines DISABLE TRIGGER trg_lines_guard;
UPDATE journal_lines SET debit = 70000, credit = 0 WHERE line_id = 1;
SELECT reference_no, hash_valid, chain_valid FROM rpc_verify_integrity() WHERE NOT hash_valid;
ROLLBACK;
\echo '=== UJI 14: UPDATE/DELETE audit_log -> DITOLAK'
UPDATE audit_log SET actor='hacker' WHERE log_id=1;
DELETE FROM audit_log;
\echo '=== UJI 15: Cuplikan audit_log'
SELECT log_id, table_name, action, record_id, actor FROM audit_log ORDER BY log_id LIMIT 8;
