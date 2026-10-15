#!/usr/bin/env python3
"""Ack-logging writer.

usage: writer.py HOST TAG START_ID [SLEEP_SECS]

Autocommit INSERTs into `ledger`, one row per statement, ids counting up from START_ID.
An id is written to acks.TAG (with the time) only after the server acknowledged the
commit, so every line of acks.TAG must survive any event the target promises RPO 0 for.
ev.TAG records DOWN (first failed statement), UP (first success after it), UNCERTAIN ids
(the statement whose outcome is unknown) and which password file worked (CONN/AUTHFAIL),
so a password rotation can be followed by writing the new one to pw.alt.

TCP keepalive and tcp_user_timeout make a dead peer surface within ~3 s instead of
hanging on a half-open connection, which is what makes RTO measurable on hard loss.
Files live in $PGT_DIR (default /srv/pgt); the password is read from pw, then pw.alt.
"""
import os
import sys
import time

import psycopg2

D = os.environ.get('PGT_DIR', '/srv/pgt')
host, tag, start = sys.argv[1], sys.argv[2], int(sys.argv[3])
slp = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
user = os.environ.get('PGT_USER', 'app')
db = os.environ.get('PGT_DB', 'app')
ack = open(f'{D}/acks.{tag}', 'a', buffering=1)
ev = open(f'{D}/ev.{tag}', 'a', buffering=1)
nid = start
conn = None
down_since = None
n = 0
lastpw = None


def now():
    return time.time()


def pws():
    out = []
    for f in (f'{D}/pw', f'{D}/pw.alt'):
        try:
            v = open(f).read().strip()
            if v:
                out.append((f, v))
        except OSError:
            pass
    return out


def connect():
    global lastpw
    err = None
    for f, pw in pws():
        try:
            c = psycopg2.connect(host=host, user=user, dbname=db, password=pw, sslmode='require',
                                 connect_timeout=3, keepalives=1, keepalives_idle=2,
                                 keepalives_interval=1, keepalives_count=2, tcp_user_timeout=3000)
            if f != lastpw:
                ev.write(f'CONN {now():.3f} pwfile={f}\n')
                lastpw = f
            return c
        except psycopg2.OperationalError as e:
            err = e
            if 'password authentication failed' in str(e):
                ev.write(f'AUTHFAIL {now():.3f} pwfile={f}\n')
                continue
            raise
    raise err or RuntimeError('no password file')


ev.write(f'START {now():.3f} host={host} start={start}\n')
while True:
    try:
        if conn is None:
            conn = connect()
            conn.autocommit = True
            cur = conn.cursor()
            cur.execute("CREATE TABLE IF NOT EXISTS ledger(id bigint PRIMARY KEY, writer text NOT NULL,"
                        " pad text, at timestamptz NOT NULL DEFAULT now())")
            if down_since:
                ev.write(f'UP {now():.3f} downtime={now() - down_since:.2f}\n')
                down_since = None
        cur.execute("INSERT INTO ledger(id,writer,pad) VALUES(%s,%s,repeat('x',200))", (nid, tag))
        ack.write(f'{nid} {now():.3f}\n')
        nid += 1
        n += 1
        if n % 5000 == 0:
            ev.write(f'PROGRESS {now():.3f} {nid}\n')
        if slp:
            time.sleep(slp)
    except Exception as e:  # noqa: BLE001 - every failure is a DOWN for the writer
        if down_since is None:
            down_since = now()
            msg = str(e).strip().replace('\n', ' ')[:160]
            ev.write(f'DOWN {down_since:.3f} at_id={nid} {type(e).__name__}: {msg}\n')
        ev.write(f'UNCERTAIN {nid}\n')
        nid += 1
        try:
            if conn:
                conn.close()
        except Exception:  # noqa: BLE001
            pass
        conn = None
        time.sleep(0.5)
