#!/usr/bin/env python3
"""Verify a writer run: RPO and RTO.

usage: verify.py HOST TAG

RPO = acknowledged ids missing from `ledger` (rows), and the span of acknowledged time they
cover (seconds from the last surviving ack before the first lost one to the last lost ack).
RTO = for each outage in ev.TAG, first failed write (DOWN) -> first successful write (UP).
Prints one JSON object.
"""
import json
import os
import sys

import psycopg2

D = os.environ.get('PGT_DIR', '/srv/pgt')
host, tag = sys.argv[1], sys.argv[2]
acked = {}
for line in open(f'{D}/acks.{tag}'):
    p = line.split()
    if p:
        acked[int(p[0])] = float(p[1])
unc = set()
outages = []
down = None
for line in open(f'{D}/ev.{tag}'):
    p = line.split()
    if not p:
        continue
    if p[0] == 'UNCERTAIN':
        unc.add(int(p[1]))
    elif p[0] == 'DOWN':
        down = (float(p[1]), ' '.join(p[3:])[:120])
    elif p[0] == 'UP' and down:
        outages.append({'down': down[0], 'up': float(p[1]), 'rto_s': round(float(p[1]) - down[0], 2),
                        'error': down[1]})
        down = None
pw = None
for f in (f'{D}/pw', f'{D}/pw.alt'):
    try:
        cand = open(f).read().strip()
        c = psycopg2.connect(host=host, user='app', dbname='app', password=cand, sslmode='require',
                             connect_timeout=5)
        pw = cand
        break
    except Exception:  # noqa: BLE001
        continue
if pw is None:
    print(json.dumps({'tag': tag, 'error': 'cannot connect'}))
    sys.exit(2)
cur = c.cursor()
cur.execute('select id from ledger where writer=%s', (tag,))
have = {r[0] for r in cur.fetchall()}
lost = sorted(set(acked) - have)
res = {
    'tag': tag,
    'acked': len(acked),
    'in_db': len(have),
    'lost_acked': len(lost),
    'unacked_present': len(have - set(acked)),
    'uncertain': len(unc),
    'uncertain_present': len(unc & have),
    'first_ack': min(acked.values()) if acked else None,
    'last_ack': max(acked.values()) if acked else None,
    'outages': outages,
    'still_down_since': down[0] if down else None,
}
if lost:
    survived_before = [t for i, t in acked.items() if i < lost[0] and i in have]
    base = max(survived_before) if survived_before else acked[lost[0]]
    res.update(first_lost_id=lost[0], last_lost_id=lost[-1], first_lost_at=acked[lost[0]],
               last_lost_at=acked[lost[-1]], rpo_s=round(acked[lost[-1]] - base, 2))
else:
    res['rpo_s'] = 0
print(json.dumps(res))
