\set ON_ERROR_STOP off
\echo '=== UJI 1: Jurnal seimbang (Beban Sewa 2.500.000 / Kas 2.500.000) -> DITERIMA'
INSERT INTO journal_headers (trx_date, reference_no, description) VALUES ('2026-10-01','JU-001','Bayar sewa gudang Oktober');
INSERT INTO journal_lines (header_id, account_id, debit, credit)
  SELECT 1, account_id, 2500000, 0 FROM chart_of_accounts WHERE account_code='6-1100';
INSERT INTO journal_lines (header_id, account_id, debit, credit)
  SELECT 1, account_id, 0, 2500000 FROM chart_of_accounts WHERE account_code='1-1100';
UPDATE journal_headers SET posting_status='POSTED' WHERE journal_id=1;

\echo '=== UJI 2: Jurnal TIDAK seimbang (Debit 1.200.000 vs Kredit 1.000.000) -> DITOLAK saat POSTING'
INSERT INTO journal_headers (trx_date, reference_no, description) VALUES ('2026-10-02','JU-002','Uji tidak seimbang');
INSERT INTO journal_lines (header_id, account_id, debit, credit)
  SELECT 2, account_id, 1200000, 0 FROM chart_of_accounts WHERE account_code='6-1200';
INSERT INTO journal_lines (header_id, account_id, debit, credit)
  SELECT 2, account_id, 0, 1000000 FROM chart_of_accounts WHERE account_code='1-1100';
UPDATE journal_headers SET posting_status='POSTED' WHERE journal_id=2;

\echo '=== UJI 3: Header langsung dikirim berstatus POSTED (bypass API) -> DITOLAK'
INSERT INTO journal_headers (trx_date, reference_no, description, posting_status) VALUES ('2026-10-03','JU-003','Bypass','POSTED');

\echo '=== UJI 4: Posting jurnal tanpa baris / 1 baris -> DITOLAK'
INSERT INTO journal_headers (trx_date, reference_no, description) VALUES ('2026-10-04','JU-004','Kosong');
UPDATE journal_headers SET posting_status='POSTED' WHERE reference_no='JU-004';

\echo '=== UJI 5: Debit negatif -> DITOLAK (chk_debit_nonneg)'
INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES (2, 1, -5000, 0);

\echo '=== UJI 6: Debit = 0 dan Kredit = 0 -> DITOLAK (chk_not_both_zero)'
INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES (2, 1, 0, 0);

\echo '=== UJI 7: Hapus akun Kas yang sudah dipakai -> DITOLAK (ON DELETE RESTRICT)'
DELETE FROM chart_of_accounts WHERE account_code='1-1100';

\echo '=== UJI 8: Hapus header yang masih punya baris -> DITOLAK (ON DELETE RESTRICT)'
DELETE FROM journal_headers WHERE journal_id=1;

\echo '=== UJI 9: Tambah baris ke jurnal POSTED -> DITOLAK'
INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES (1, 1, 100, 0);

\echo '=== UJI 10: Baris dengan akun yang tidak ada -> DITOLAK (foreign key)'
INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES (2, 999, 100, 0);

\echo '=== HASIL AKHIR: jurnal POSTED dan saldo'
SELECT h.reference_no, h.posting_status, a.account_code, a.account_name, l.debit, l.credit
  FROM journal_headers h JOIN journal_lines l ON l.header_id=h.journal_id
  JOIN chart_of_accounts a ON a.account_id=l.account_id WHERE h.posting_status='POSTED' ORDER BY l.line_id;
SELECT h.reference_no, h.posting_status, SUM(l.debit) AS total_debit, SUM(l.credit) AS total_kredit
  FROM journal_headers h LEFT JOIN journal_lines l ON l.header_id=h.journal_id GROUP BY 1,2 ORDER BY 1;
