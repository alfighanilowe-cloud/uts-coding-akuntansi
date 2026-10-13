import hashlib, subprocess, secrets
def h(pw, salt): return hashlib.scrypt(pw.encode(), salt=salt.encode(), n=2**14, r=8, p=1).hex()
for u, n, p in [("rina@diponegoro-logistik.id", "Rina Kusuma (Staf Kas)", "kas12345"),
                ("auditor@diponegoro-logistik.id", "Auditor Internal", "audit12345")]:
    s = secrets.token_hex(8)
    subprocess.run(["psql","-h","/tmp","-p","5433","-U","postgres","-d","uts_soal3","-q","-v",f"u={u}","-v",f"n={n}","-v",f"s={s}","-v",f"h={h(p,s)}"],
        input="INSERT INTO app_users VALUES (:'u',:'n',:'s',:'h') ON CONFLICT DO NOTHING;", text=True, check=True)
