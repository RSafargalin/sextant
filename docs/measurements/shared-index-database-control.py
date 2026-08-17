#!/usr/bin/env python3
"""Контроль к замеру общей базы: те же N одновременных процессов, но каждый со своей базой.

Без этого контроля замедление при N процессах приписать общей базе нельзя — четыре запроса
по 25 секунд насыщают диск и процессор сами по себе.
"""
import os
import shutil
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

BINARY, PROJECT, SYMBOL, STORE = sys.argv[1:5]
COPIES = int(sys.argv[5]) if len(sys.argv) > 5 else 4
DB_ROOT = os.path.expanduser("~/Library/Caches/sextant/index-db")
ENV = {**os.environ, "SEXTANT_NO_DAEMON": "1"}
WORK = "/private/tmp/sextant-dbroot-control"


def db_path(store):
    return os.path.join(DB_ROOT, store.replace("/", "_"))


def query(store):
    started = time.time()
    result = subprocess.run([BINARY, "refs", SYMBOL, "--project", PROJECT, "--index-store", store],
                            capture_output=True, text=True, env=ENV)
    answer = next((l.strip() for l in result.stdout.splitlines() if "usages:" in l), "НЕТ ОТВЕТА")
    return time.time() - started, answer


def concurrent(stores):
    with ThreadPoolExecutor(max_workers=len(stores)) as pool:
        return list(pool.map(query, stores))


def report(label, results):
    times = [t for t, _ in results]
    print(f"  {label:<38} {min(times):5.2f}–{max(times):5.2f}с  медиана {statistics.median(times):5.2f}с"
          f"  ответов различных: {len({a for _, a in results})}")


shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
copies = []
for index in range(COPIES):
    copy = os.path.join(WORK, f"store{index}")
    started = time.time()
    shutil.copytree(STORE, copy, symlinks=True)
    shutil.rmtree(db_path(copy), ignore_errors=True)
    copies.append(copy)
    print(f"  копия {index + 1}/{COPIES} готова за {time.time() - started:.0f}с", flush=True)

print("  прогреваем каждую базу…", flush=True)
concurrent(copies)

for n in (1, 2, 4):
    if n <= len(copies):
        report(f"{n} процесс(а), РАЗДЕЛЬНЫЕ базы", concurrent(copies[:n]))

for copy in copies:
    shutil.rmtree(db_path(copy), ignore_errors=True)
shutil.rmtree(WORK, ignore_errors=True)
