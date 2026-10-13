import json
from playwright.sync_api import sync_playwright
G="/home/claude/uts/gambar/"
log=[]
with sync_playwright() as p:
    b=p.chromium.launch(); pg=b.new_page(viewport={"width":1280,"height":900})
    errs=[]; pg.on("pageerror", lambda e: errs.append(str(e))); pass
    pg.goto("http://localhost:5000/"); pg.screenshot(path=G+"w1_login.png")
    pg.click("text=Masuk >> nth=1"); pg.wait_for_selector("#app:not(.hide)")
    pg.fill("#fDesc","Pembayaran listrik, telepon, dan ongkos kirim Oktober 2026")
    sel=pg.locator("#lines select"); ins=pg.locator("#lines input")
    sel.nth(0).select_option("6-1300"); ins.nth(0).fill("750000")
    sel.nth(1).select_option("1-1200"); ins.nth(3).fill("900000")
    pg.click("text=+ Tambah baris"); pg.locator("#lines select").nth(2).select_option("6-1400"); pg.locator("#lines input").nth(4).fill("250000")
    pg.screenshot(path=G+"w2_tidak_seimbang.png", full_page=True)
    log.append(("tidak seimbang: submit disabled =", pg.is_disabled("#btnSubmit")))
    pg.locator("#lines input").nth(3).fill("1000000")
    pg.screenshot(path=G+"w3_seimbang.png", full_page=True)
    log.append(("seimbang: submit disabled =", pg.is_disabled("#btnSubmit")))
    # uji: akun kas didebit
    pg.locator("#lines select").nth(1).select_option("1-1200")
    pg.click("#btnSubmit"); pg.wait_for_selector("#msg.good"); pg.screenshot(path=G+"w4_terposting.png", full_page=True)
    # coba ubah / hapus
    pg.click("text=Coba UBAH"); pg.wait_for_selector("#vmsg.err"); pg.screenshot(path=G+"w5_tolak_ubah.png", full_page=True)
    pg.click("text=Coba HAPUS"); pg.wait_for_timeout(500); log.append(("hapus:", pg.inner_text("#vmsg")))
    pg.fill("#reason","Salah input nominal listrik"); pg.click("text=Buat jurnal pembalik"); pg.wait_for_selector("#vmsg.good"); pg.wait_for_timeout(300)
    pg.click("text=Verifikasi hash"); pg.wait_for_timeout(500); pg.screenshot(path=G+"w6_storno_verifikasi.png", full_page=True)
    log.append(("verifikasi:", pg.inner_text("#vmsg")))
    pg.click("#tabA"); pg.screenshot(path=G+"w7_audit_log.png", full_page=True)
    pg.set_viewport_size({"width":390,"height":844}); pg.click("#tabJ"); pg.screenshot(path=G+"w8_hp.png")
    log.append(("sw>cw (scroll horizontal) =", pg.evaluate("document.documentElement.scrollWidth>document.documentElement.clientWidth")))
    log.append(("js errors", errs)); b.close()
for l in log: print(l)
