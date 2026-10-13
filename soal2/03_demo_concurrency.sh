#!/bin/bash
# Simulasi dua kasir bersamaan, stok tersisa 1 unit (BRG-002)
PSQL="psql -h /tmp -p 5433 -U postgres -d uts_soal2 -q -X"
reset() { $PSQL -c "DELETE FROM inventory_transactions WHERE item_id='BRG-002';" -c "UPDATE inventory_items SET stock_qty=1 WHERE item_id='BRG-002';" >/dev/null 2>&1; }
$PSQL -c "CREATE TABLE IF NOT EXISTS sales_log(id serial, kasir text, qty int);" >/dev/null 2>&1

echo "##### DEMO A - TANPA PENGUNCIAN (baca-cek-tulis di sisi aplikasi)"
reset; $PSQL -c "TRUNCATE sales_log;" >/dev/null
kasir_a() { $PSQL <<SQL
SELECT stock_qty AS s FROM inventory_items WHERE item_id='BRG-002' \gset
\echo [Kasir $1] membaca stok = :s
SELECT pg_sleep(2) \gset
UPDATE inventory_items SET stock_qty = :s - 1 WHERE item_id='BRG-002';
INSERT INTO sales_log(kasir, qty) VALUES ('$1', 1);
\echo [Kasir $1] penjualan BERHASIL
SQL
}
kasir_a A & sleep 0.5; kasir_a B & wait
$PSQL -c "SELECT (SELECT stock_qty FROM inventory_items WHERE item_id='BRG-002') AS stok_akhir, (SELECT SUM(qty) FROM sales_log) AS unit_terjual;"
echo ">> MASALAH: 2 unit terjual padahal stok awal hanya 1 (overselling)."

echo; echo "##### DEMO B - SELECT ... FOR UPDATE di dalam trigger"
reset
ts() { date +%H:%M:%S.%3N; }
kasir_b() {
  echo "[Kasir $1] $(ts) BEGIN + INSERT SALE 1 unit BRG-002"
  $PSQL -v ON_ERROR_STOP=1 <<SQL 2>&1 | grep -v "CONTEXT\|HINT"
BEGIN;
INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG-002','SALE',1);
SELECT pg_sleep(3) \gset
COMMIT;
SQL
  if [ ${PIPESTATUS[0]} -eq 0 ]; then echo "[Kasir $1] $(ts) COMMIT - penjualan BERHASIL"; else echo "[Kasir $1] $(ts) ROLLBACK - penjualan DITOLAK (setelah menunggu kunci Kasir A)"; fi
}
kasir_b A & sleep 0.5; kasir_b B & wait
$PSQL -c "SELECT stock_qty AS stok_akhir FROM inventory_items WHERE item_id='BRG-002';" -c "SELECT trx_id, trx_type, qty FROM inventory_transactions WHERE item_id='BRG-002';"
echo ">> HASIL: Kasir B tertahan sampai Kasir A selesai, lalu ditolak karena stok sudah 0. Hanya 1 penjualan tersimpan."

echo; echo "##### DEMO C - ISOLASI SERIALIZABLE"
reset; $PSQL -c "TRUNCATE sales_log;" >/dev/null
kasir_c() {
  echo "[Kasir $1] $(ts) BEGIN ISOLATION LEVEL SERIALIZABLE"
  $PSQL -v ON_ERROR_STOP=1 <<SQL 2>&1 | grep -v "CONTEXT\|HINT\|DETAIL"
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT stock_qty FROM inventory_items WHERE item_id='BRG-002';
SELECT pg_sleep(2) \gset
UPDATE inventory_items SET stock_qty = stock_qty - 1 WHERE item_id='BRG-002';
INSERT INTO sales_log(kasir, qty) VALUES ('$1', 1);
COMMIT;
SQL
  if [ ${PIPESTATUS[0]} -eq 0 ]; then echo "[Kasir $1] $(ts) COMMIT - penjualan BERHASIL"; else echo "[Kasir $1] $(ts) ROLLBACK - harus diulang (retry)"; fi
}
kasir_c A & sleep 0.5; kasir_c B & wait
$PSQL -c "SELECT stock_qty AS stok_akhir, (SELECT SUM(qty) FROM sales_log) AS unit_terjual FROM inventory_items WHERE item_id='BRG-002';"
echo ">> HASIL: salah satu kasir menerima ERROR 40001 (serialization failure) dan harus mengulang; tidak ada overselling."
