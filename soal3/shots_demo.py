from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b=p.chromium.launch(); pg=b.new_page(viewport={"width":1280,"height":900})
    errs=[]; pg.on("pageerror", lambda e: errs.append(str(e))); pass
    pg.goto("file:///home/claude/uts/soal3/public/index.html")
    pg.click("text=Masuk >> nth=1"); pg.wait_for_selector("#app:not(.hide)")
    pg.fill("#fDesc","Bayar listrik dan ongkos kirim")
    sel=pg.locator("#lines select"); ins=pg.locator("#lines input")
    sel.nth(0).select_option("6-1300"); ins.nth(0).fill("750000"); sel.nth(1).select_option("1-1200"); ins.nth(3).fill("750000")
    print("disabled:", pg.is_disabled("#btnSubmit"))
    pg.click("#btnSubmit"); pg.wait_for_selector("#msg.good"); print(pg.inner_text("#msg"))
    pg.click("text=Coba UBAH"); pg.wait_for_selector("#vmsg.err"); print(pg.inner_text("#vmsg"))
    pg.fill("#reason","Salah input"); pg.click("text=Buat jurnal pembalik"); pg.wait_for_selector("#vmsg.good"); pg.click("text=Verifikasi hash"); pg.wait_for_timeout(300); print(pg.inner_text("#vmsg"))
    pg.click("#tabA"); print(pg.inner_text("#paneA")[:120].replace("\n"," | "))
    print("errors:", errs); b.close()
