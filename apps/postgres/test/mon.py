#!/usr/bin/env python3
"""Per-node availability monitor.

usage: mon.py TAG HOST...

Every 0.5 s per host: UP/DOWN transitions, postmaster start time changes (a restart) and
the recovery flag (writer vs standby), with timestamps, to $PGT_DIR/mon.TAG.
"""
import os
import sys
import threading
import time

import psycopg2

D = os.environ.get('PGT_DIR', '/srv/pgt')
tag = sys.argv[1]
hosts = sys.argv[2:]
out = open(f'{D}/mon.{tag}', 'a', buffering=1)
lk = threading.Lock()


def log(s):
    with lk:
        out.write(f'{time.time():.3f} {s}\n')


def pws():
    r = []
    for f in (f'{D}/pw', f'{D}/pw.alt'):
        try:
            v = open(f).read().strip()
            if v:
                r.append(v)
        except OSError:
            pass
    return r


def run(h):
    conn = None
    state = start = rec = None
    while True:
        try:
            if conn is None:
                e2 = None
                for pw in pws():
                    try:
                        conn = psycopg2.connect(host=h, user='app', dbname='app', password=pw, sslmode='require',
                                                connect_timeout=2, keepalives=1, keepalives_idle=2,
                                                keepalives_interval=1, keepalives_count=2, tcp_user_timeout=2000)
                        break
                    except psycopg2.OperationalError as e:
                        e2 = e
                if conn is None:
                    raise e2 or RuntimeError('no password')
                conn.autocommit = True
            cur = conn.cursor()
            cur.execute('select pg_postmaster_start_time()::text, pg_is_in_recovery()')
            st, r = cur.fetchone()
            if state != 'UP':
                log(f'{h} UP')
                state = 'UP'
            if st != start:
                log(f'{h} POSTMASTER_START {st}')
                start = st
            if r != rec:
                log(f'{h} RECOVERY {r}')
                rec = r
        except Exception as e:  # noqa: BLE001
            if state != 'DOWN':
                log(f'{h} DOWN {type(e).__name__}: {str(e).strip()[:120]}')
                state = 'DOWN'
            try:
                if conn:
                    conn.close()
            except Exception:  # noqa: BLE001
                pass
            conn = None
        time.sleep(0.5)


for h in hosts:
    threading.Thread(target=run, args=(h,), daemon=True).start()
while True:
    time.sleep(3600)
