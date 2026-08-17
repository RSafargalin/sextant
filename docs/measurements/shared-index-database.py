#!/usr/bin/env python3
"""Вред от общего каталога базы IndexStoreDB: замер, а не рассуждение.

Постановка. Каталог базы выводится из пути стора, поэтому два процесса на одном сторе
работают с одной базой. Проверяем три вещи:
  1. цена — время запроса при N одновременных процессах против одиночного тёплого;
  2. верность — совпадают ли ответы;
  3. состояние — остаётся ли база рабочей после одновременного доступа.

Контроль: те же N процессов на N КОПИЯХ стора (разные пути → разные базы). Если общая
база хуже раздельных, разница и есть вред.
"""
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

BINARY, PROJECT, SYMBOL = sys.argv[1], sys.argv[2], sys.argv[3]
STORE = sys.argv[4]
DB_ROOT = os.path.expanduser("~/Library/Caches/sextant/index-db")
ENV = {**os.environ, "SEXTANT_NO_DAEMON": "1"}


def db_path(store):
    return os.path.join(DB_ROOT, store.replace("/", "_"))


def query(store):
    """Один запрос. Возвращает (секунды, строка ответа)."""
    started = time.time()
    result = subprocess.run(
        [BINARY, "refs", SYMBOL, "--project", PROJECT, "--index-store", store],
        capture_output=True, text=True, env=ENV,
    )
    elapsed = time.time() - started
    answer = next((l.strip() for l in result.stdout.splitlines() if "usages:" in l), "НЕТ ОТВЕТА")
    return elapsed, answer


def concurrent(stores):
    """По одному процессу на каждый стор, одновременно."""
    with ThreadPoolExecutor(max_workers=len(stores)) as pool:
        return list(pool.map(query, stores))


def directory_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def report(label, results):
    times = [t for t, _ in results]
    answers = {a for _, a in results}
    print(f"  {label:<34} {min(times):5.2f}–{max(times):5.2f}с  медиана {statistics.median(times):5.2f}с"
          f"  ответов различных: {len(answers)}")
    return answers


print(f"стор: {STORE}")
print(f"юнитов: {len(os.listdir(os.path.join(STORE, 'v5', 'units')))}")
print()

# 1. Холодная база — цена импорта, то есть то, что теряется при переимпорте.
shutil.rmtree(db_path(STORE), ignore_errors=True)
cold, cold_answer = query(STORE)
print(f"  {'холодная база (импорт с нуля)':<34} {cold:5.2f}с   ответ: {cold_answer}")

# 2. Тёплая одиночная — базовая линия.
warm = [query(STORE) for _ in range(3)]
warm_answers = report("тёплая, один процесс (3 прогона)", warm)

# 2b. Главный случай: база холодная, и в неё ломятся сразу несколько процессов. Так бывает
#     после каждой пересборки — первая же пара команд (или демон и CLI) импортирует наперегонки.
for n in (2,):
    shutil.rmtree(db_path(STORE), ignore_errors=True)
    race = concurrent([STORE] * n)
    race_answers = report(f"{n} процесса в ХОЛОДНУЮ общую базу", race)
    if race_answers != warm_answers:
        print(f"      ⚠ ОТВЕТЫ РАСХОДЯТСЯ с одиночным: {race_answers} против {warm_answers}")

# 3. N процессов на ОДНОМ сторе → одна база.
for n in (2, 4):
    shared = concurrent([STORE] * n)
    shared_answers = report(f"{n} процесса, общая база", shared)
    if shared_answers != warm_answers:
        print(f"      ⚠ ОТВЕТЫ РАСХОДЯТСЯ с одиночным: {shared_answers} против {warm_answers}")

# 5. Демон держит базу открытой, а CLI в это же время импортирует её с нуля. Это и есть
#    реальная встреча двух процессов на одной базе: демон живёт, пользователь пересобрал проект.
daemon = subprocess.Popen([BINARY, "serve", "--project", PROJECT, "--index-store", STORE],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=ENV)
time.sleep(3)
try:
    shutil.rmtree(db_path(STORE), ignore_errors=True)
    with_daemon = [query(STORE)]
    daemon_answers = report("CLI в холодную базу, демон жив", with_daemon)
    if daemon_answers != warm_answers:
        print(f"      ⚠ ОТВЕТЫ РАСХОДЯТСЯ с одиночным: {daemon_answers} против {warm_answers}")
    # и наоборот: жив ли демон и верен ли его ответ после того, как базу под ним переимпортировали
    through_daemon = subprocess.run([BINARY, "refs", SYMBOL, "--project", PROJECT], capture_output=True,
                                    text=True, env={k: v for k, v in ENV.items() if k != "SEXTANT_NO_DAEMON"})
    answer = next((l.strip() for l in through_daemon.stdout.splitlines() if "usages:" in l), "НЕТ ОТВЕТА")
    print(f"  {'ответ демона после переимпорта':<34} {answer}")
finally:
    daemon.terminate()
    daemon.wait()

# 4. Контроль: N процессов на N копиях стора → N баз.
copies = []
for index in range(int(os.environ.get('COPIES', '4'))):
    copy = f"{STORE.rstrip('/')}-copy{index}"
    shutil.rmtree(copy, ignore_errors=True)
    shutil.copytree(STORE, copy)
    shutil.rmtree(db_path(copy), ignore_errors=True)
    copies.append(copy)
if copies:  # прогреваем каждую копию, чтобы сравнивать тёплое с тёплым
    concurrent(copies)
for n in [k for k in (2, 4) if k <= len(copies)]:
    report(f"{n} процесса, раздельные базы", concurrent(copies[:n]))

# 5. Состояние базы после одновременного доступа.
after, after_answer = query(STORE)
print()
print(f"  запрос после всего: {after:.2f}с, ответ: {after_answer}")
print(f"  размер общей базы: {directory_size(db_path(STORE)) / 1024:.0f} КБ, файлов: "
      f"{sum(len(f) for _, _, f in os.walk(db_path(STORE)))}")
for copy in copies:
    shutil.rmtree(copy, ignore_errors=True)
    shutil.rmtree(db_path(copy), ignore_errors=True)
