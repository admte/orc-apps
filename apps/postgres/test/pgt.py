#!/usr/bin/env python3
"""Postgres app test driver (ORC8R).

Runs on the operator's machine and drives one ORC8R zone over its API: the pool under
test, a client node in the same project that runs the writer/monitor/verifier
(writer.py, mon.py, verify.py, pushed to $PGT_DIR on it), and node exec for faults.
Each scenario appends one JSON result line to $PGT_RESULTS and prints it.

Environment:
  ORC_URL         API base (default https://v0.orc8r.com)
  ORC_TOKEN_FILE  file holding the bearer token (never printed)
  PGT_ORG, PGT_PROJECT, PGT_POOL   pool under test (default sys / pgtest / pgt)
  PGT_CLIENT      node id of the client node (same project network)
  PGT_HOST        name the writer dials (default <pool>.<project>.internal)
  PGT_DIR         work dir on the client (default /srv/pgt)
  PGT_RESULTS     local results file (default ./results.jsonl)

usage: pgt.py push | nodes | load SCALE | checksum | sh SLOT CMD | wstart TAG | wstop TAG |
              verify TAG | rp | <scenario> [args]
Scenarios: s1 s2agent s2reboot s3 s4 s5 s6 s7 s9 s15 s17 s18 s19 lag
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
URL = os.environ.get('ORC_URL', 'https://v0.orc8r.com')
TOKEN = open(os.environ['ORC_TOKEN_FILE']).read().strip()
ORG = os.environ.get('PGT_ORG', 'sys')
PROJ = os.environ.get('PGT_PROJECT', 'pgtest')
POOL = os.environ.get('PGT_POOL', 'pgt')
CLIENT = os.environ['PGT_CLIENT']
HOST = os.environ.get('PGT_HOST', f'{POOL}.{PROJ}.internal')
D = os.environ.get('PGT_DIR', '/srv/pgt')
RESULTS = os.environ.get('PGT_RESULTS', 'results.jsonl')
PGDATA = '/var/lib/orc-postgres/primary/pgdata'


def ts(t=None):
    return time.strftime('%H:%M:%S', time.gmtime(t if t is not None else time.time()))


def say(*a):
    print(ts(), *a, flush=True)


def api(method, path, body=None, timeout=60, retries=4):
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(retries):
        req = urllib.request.Request(URL + path, data=data, method=method)
        req.add_header('Authorization', 'Bearer ' + TOKEN)
        if data is not None:
            req.add_header('content-type', 'application/json')
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                return json.loads(raw) if raw.strip() else {}
        except urllib.error.HTTPError as e:
            msg = e.read().decode(errors='replace')[:400]
            if e.code >= 500 and attempt + 1 < retries:
                time.sleep(3)
                continue
            raise RuntimeError(f'{method} {path}: HTTP {e.code} {msg}') from None
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt + 1 < retries:
                time.sleep(3)
                continue
            raise


def nexec(node, cmd, stdin=None, timeout=40):
    if isinstance(cmd, str):
        cmd = ['sh', '-c', cmd]
    body = {'command': cmd, 'timeout_secs': timeout}
    if stdin is not None:
        body['stdin'] = stdin
    r = api('POST', f'/api/nodes/{node}/exec', body, timeout=timeout + 30, retries=1)
    return r.get('exit_code'), (r.get('stdout') or '') + (r.get('stderr') or '')


def csh(cmd, stdin=None, timeout=40):
    return nexec(CLIENT, cmd, stdin, timeout)


# ---------- pool and nodes ----------

def pool():
    return api('GET', f'/api/orgs/{ORG}/projects/{PROJ}/pools/{POOL}')


def nodes(all_states=False):
    out = []
    for n in api('GET', '/api/nodes/')['items']:
        if n['pool'] == POOL and n['project'] == PROJ and (all_states or n['state'] != 'ended'):
            out.append(n)
    return sorted(out, key=lambda n: (n.get('pool_slot') or 0, n['pool_index']))


def slot_node(slot, online=True):
    for n in nodes():
        if n.get('pool_slot') == slot and not n.get('baking') and (not online or n['state'] == 'online'):
            return n
    return None


def ssh(slot, cmd, timeout=40):
    n = slot_node(slot)
    if not n:
        raise RuntimeError(f'no online node in slot {slot}')
    return nexec(n['id'], cmd, timeout=timeout)


def put_pool(body):
    return api('PUT', f"/api/pools/{pool()['id']}", body)


def wait(pred, timeout, every=5, what=''):
    end = time.time() + timeout
    while time.time() < end:
        try:
            v = pred()
        except Exception as e:  # noqa: BLE001 - API hiccups while nodes come and go
            say('wait', what, 'error', str(e)[:120])
            v = None
        if v:
            return v
        time.sleep(every)
    raise TimeoutError(f'timed out after {timeout}s waiting for {what}')


def latest_rp(slot=1):
    r = api('GET', f'/api/orgs/{ORG}/projects/{PROJ}/pools/{POOL}/restore-points/?slot={slot}')
    pts = r.get('points', [])
    return max(pts, key=lambda p: p['committed_at']) if pts else None


def node_logs(node, since, grep=None, secs=25):
    """Retained node log lines (SSE `data:` JSON) from `since` (e.g. 10m)."""
    req = urllib.request.Request(f'{URL}/api/nodes/{node}/logs?mode=head&debug=true&since={since}')
    req.add_header('Authorization', 'Bearer ' + TOKEN)
    lines = []
    end = time.time() + secs
    try:
        with urllib.request.urlopen(req, timeout=secs) as r:
            for raw in r:
                if time.time() > end:
                    break
                raw = raw.decode(errors='replace').strip()
                if not raw.startswith('data:'):
                    continue
                try:
                    j = json.loads(raw[5:])
                except ValueError:
                    continue
                msg = j.get('message') or j.get('msg') or json.dumps(j)
                line = f"{j.get('ts') or j.get('time') or ''} {msg}"
                if j.get('fields'):
                    line += ' ' + json.dumps(j['fields'])
                if not grep or any(g in line for g in grep):
                    lines.append(line)
    except Exception:  # noqa: BLE001 - the stream ends by timeout
        pass
    return lines


# ---------- client side ----------

FILES = ['writer.py', 'mon.py', 'verify.py', 'gen-shop.sql', 'shop-checksum.sql']


def push():
    for f in FILES:
        code, out = csh(f'mkdir -p {D} && cat > {D}/{f}', stdin=open(os.path.join(HERE, f)).read())
        assert code == 0, out
    say('pushed', ' '.join(FILES), 'to', D)


def unit(name):
    return f'pgt-{name}'


def wstart(tag, host=None, sleep=0):
    start = int(time.time()) * 10_000_000
    code, out = csh(f'systemd-run --unit {unit("w-" + tag)} --property=WorkingDirectory={D} '
                    f'--setenv=PGT_DIR={D} python3 {D}/writer.py {host or HOST} {tag} {start} {sleep}')
    assert code == 0, out
    say('writer', tag, 'started', host or HOST)


def wstop(tag):
    csh(f'systemctl stop {unit("w-" + tag)}; systemctl reset-failed {unit("w-" + tag)} 2>/dev/null; true')


def mstart(tag, hosts):
    code, out = csh(f'systemd-run --unit {unit("m-" + tag)} --setenv=PGT_DIR={D} python3 {D}/mon.py {tag} '
                    + ' '.join(hosts))
    assert code == 0, out


def mstop(tag):
    csh(f'systemctl stop {unit("m-" + tag)}; systemctl reset-failed {unit("m-" + tag)} 2>/dev/null; true')


def ev(tag):
    # exec output is capped at 8 KiB: never cat the whole file (UNCERTAIN/PROGRESS lines pile up)
    code, out = csh(f"grep -E '^(START|DOWN|UP|CONN|AUTHFAIL) ' {D}/ev.{tag} | tail -n 60")
    return out.splitlines()


def acks_count(tag):
    code, out = csh(f'wc -l < {D}/acks.{tag}')
    return int(out.strip() or 0)


def verify(tag, host=None):
    def go():
        code, out = csh(f'PGT_DIR={D} python3 {D}/verify.py {host or HOST} {tag}', timeout=40)
        return json.loads(out.strip().splitlines()[-1]) if code == 0 else None
    return wait(go, 300, 10, f'verify {tag}')


def writer_state(tag):
    """'up' when the last DOWN has an UP after it (or none), else 'down'."""
    st = 'up'
    for line in ev(tag):
        if line.startswith('DOWN'):
            st = 'down'
        elif line.startswith('UP'):
            st = 'up'
    return st


def wait_outage_over(tag, timeout, min_downs=1):
    def done():
        lines = ev(tag)
        downs = sum(1 for x in lines if x.startswith('DOWN'))
        return downs >= min_downs and writer_state(tag) == 'up'
    return wait(done, timeout, 5, f'writer {tag} back up')


def wait_down(tag, timeout):
    return wait(lambda: any(x.startswith('DOWN') for x in ev(tag)), timeout, 2, f'writer {tag} down')


def checksum(host=None):
    code, out = csh(f'PGPASSWORD="$(cat {D}/pw)" psql -X -q "host={host or HOST} user=app dbname=app '
                    f'sslmode=require connect_timeout=5" -f {D}/shop-checksum.sql', timeout=45)
    return out.strip() if code == 0 else f'ERROR {out.strip()[:200]}'


def load(scale):
    code, out = csh(f'systemd-run --unit {unit("load")} --setenv=PGPASSWORD="$(cat {D}/pw)" '
                    f'--property=StandardOutput=file:{D}/load.log --property=StandardError=file:{D}/load.log '
                    f'psql -X "host={HOST} user=app dbname=app sslmode=require" -v scale={scale} '
                    f'-f {D}/gen-shop.sql')
    assert code == 0, out
    wait(lambda: csh(f'systemctl is-active {unit("load")} >/dev/null || echo done')[1].strip() == 'done',
         7200, 20, 'load')
    say(csh(f'tail -5 {D}/load.log')[1])
    csh(f'systemctl reset-failed {unit("load")} 2>/dev/null; true')


def record(res):
    res.setdefault('at', time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    with open(RESULTS, 'a') as f:
        f.write(json.dumps(res) + '\n')
    print(json.dumps(res, indent=1), flush=True)
    return res


def rto_max(v):
    return v.get('rto_max_s', max((o['rto_s'] for o in v['outages']), default=0))


def judge(name, v, rto_limit, rpo_limit=0, extra=None, notes=''):
    ok = v['lost_acked'] <= (0 if rpo_limit == 0 else 10**12) and v.get('rpo_s', 0) <= rpo_limit \
        and rto_max(v) <= rto_limit and v.get('still_down_since') is None
    r = {'scenario': name, 'pass': ok, 'rpo_rows': v['lost_acked'], 'rpo_s': v.get('rpo_s', 0),
         'rto_s': rto_max(v), 'acked': v['acked'], 'outages': v['outages'], 'notes': notes}
    if extra:
        r.update(extra)
    return record(r)


# ---------- scenarios ----------

def postmaster_pid(slot=1):
    code, out = ssh(slot, f'head -1 {PGDATA}/postmaster.pid')
    return int(out.strip())


def s1(n='1'):
    """kill -9 the postmaster under writes. Target RPO 0, RTO <= 30 s."""
    tag = f's1{n}-{int(time.time())}'
    wstart(tag)
    time.sleep(20)
    pid = postmaster_pid()
    code, out = ssh(1, f'kill -9 {pid}')
    say('killed postmaster', pid, code, out)
    wait_down(tag, 30)
    wait_outage_over(tag, 300)
    time.sleep(10)
    wstop(tag)
    return judge('S1 kill -9 postmaster', verify(tag), 30, extra={'pid': pid})


def s2agent():
    """Agent restart under writes: postgres must not notice. RPO 0, RTO <= 120 s."""
    tag = f's2a-{int(time.time())}'
    before = postmaster_pid()
    wstart(tag)
    time.sleep(15)
    code, out = ssh(1, 'systemd-run --on-active=2 systemctl restart orc-agent')
    say('agent restart scheduled', code, out.strip())
    time.sleep(90)
    wait(lambda: slot_node(1), 300, 5, 'node 1 online')
    after = postmaster_pid()
    wstop(tag)
    return judge('S2 agent restart', verify(tag), 120,
                 extra={'postmaster_restarted': before != after})


def s2reboot():
    """Guest reboot under writes, disk intact. RPO 0, RTO <= 120 s."""
    tag = f's2r-{int(time.time())}'
    n0 = slot_node(1)
    wstart(tag)
    time.sleep(15)
    code, out = nexec(n0['id'], 'systemd-run --on-active=3 systemctl reboot')
    say('reboot scheduled on', n0['name'], code, out.strip())
    wait_down(tag, 120)
    wait_outage_over(tag, 1500)
    time.sleep(10)
    wstop(tag)
    n1 = slot_node(1)
    return judge('S2 node reboot', verify(tag), 120,
                 extra={'node_before': n0['name'], 'node_after': n1 and n1['name'],
                        'replaced': not n1 or n1['id'] != n0['id']})


def s3(n='1'):
    """Graceful terminate of node 1 under writes. RPO 0, RTO <= 10 min."""
    tag = f's3{n}-{int(time.time())}'
    sum0 = checksum()
    n0 = slot_node(1)
    wstart(tag)
    time.sleep(20)
    t0 = time.time()
    api('POST', f"/api/nodes/{n0['id']}/terminate", {'reason': 'pg harness S3'})
    say('terminate', n0['name'])
    wait_down(tag, 120)
    wait_outage_over(tag, 1800)
    t1 = time.time()
    time.sleep(10)
    wstop(tag)
    sum1 = checksum()
    n1 = slot_node(1)
    v = verify(tag)
    return judge('S3 graceful terminate', v, 600,
                 extra={'node_before': n0['name'], 'node_after': n1 and n1['name'],
                        'dataset_intact': sum0 == sum1, 'terminate_to_up_s': round(t1 - t0, 1)})


def sysrq_off(node_id):
    return nexec(node_id, "systemd-run --on-active=3 /bin/sh -c "
                          "'echo 1 > /proc/sys/kernel/sysrq; echo o > /proc/sysrq-trigger'")


def s4(n='1', pre='30'):
    """Hard loss of the only node (guest power-off via sysrq) after PRE seconds of writes.

    Phase A: RPO ~ age of the newest restore point (~5 min typical). `loss_window_s` is that age
    at the loss; `rpo_s` is the span of the writer's own acknowledged writes that were lost."""
    tag = f's4{n}-{int(time.time())}'
    sum0 = checksum()
    n0 = slot_node(1)
    wstart(tag)
    time.sleep(int(pre))
    rp = latest_rp()
    code, out = sysrq_off(n0['id'])
    t_kill = time.time() + 3
    say('sysrq power-off scheduled on', n0['name'], code, out.strip(), 'newest point',
        rp and ts(rp['committed_at']))
    wait_down(tag, 180)
    wait_outage_over(tag, 2400)
    time.sleep(10)
    wstop(tag)
    n1 = slot_node(1)
    v = verify(tag)
    sum1 = checksum()
    rp_age = round(t_kill - rp['committed_at'], 1) if rp else None
    warn = n1.get('warnings') if n1 else None
    restore = node_logs(n1['id'], '40m', ['App data restored', 'app data: restored']) if n1 else []
    res = {'scenario': 'S4 hard loss, single node', 'rpo_rows': v['lost_acked'], 'rpo_s': v.get('rpo_s', 0),
           'rto_s': rto_max(v), 'acked': v['acked'], 'outages': v['outages'],
           'restore_point_age_at_loss_s': rp_age, 'pre_kill_writes_s': int(pre), 'node_before': n0['name'],
           'node_after': n1 and n1['name'], 'dataset_intact': sum0 == sum1, 'new_node_warnings': warn,
           'restore_lines': restore[-6:]}
    res['pass'] = res['rpo_s'] <= 360 and res['rto_s'] <= 900 + 120 and sum0 == sum1
    return record(res)


def s15():
    """Password rotation via param under writes: old rejected, new accepted, RPO 0."""
    import secrets
    tag = f's15-{int(time.time())}'
    new = 'pgt-' + secrets.token_urlsafe(18)
    old = csh(f'cat {D}/pw')[1].strip()
    csh(f'umask 077; cat > {D}/pw.alt', stdin=new)
    wstart(tag)
    time.sleep(15)
    p = pool()
    apps = p['apps']
    for a in apps:
        if a['name'].startswith('postgres'):
            a['params']['password'] = new
    put_pool({'apps': apps})
    say('password param changed; pool version', pool()['version'])
    wait(lambda: any('pwfile=' + D + '/pw.alt' in x for x in ev(tag)), 900, 5, 'writer on new password')
    time.sleep(10)
    wstop(tag)
    code_old, out_old = csh(f'PGPASSWORD="$(cat {D}/pw)" psql -X -c "select 1" '
                            f'"host={HOST} user=app dbname=app sslmode=require connect_timeout=5"')
    code_new, out_new = csh(f'PGPASSWORD="$(cat {D}/pw.alt)" psql -X -tAc "select 1" '
                            f'"host={HOST} user=app dbname=app sslmode=require connect_timeout=5"')
    v = verify(tag)
    ok = code_old != 0 and 'password authentication failed' in out_old and code_new == 0
    csh(f'mv {D}/pw {D}/pw.prev && mv {D}/pw.alt {D}/pw')
    r = judge('S15 password rotation', v, 120,
              extra={'old_rejected': code_old != 0, 'old_error': out_old.strip()[-120:],
                     'new_accepted': code_new == 0})
    if not ok:
        r['pass'] = False
        record({'scenario': 'S15 password rotation (auth check)', 'pass': False, 'notes': 'see previous'})
    del old
    return r


def s17():
    """TLS required: plain TCP refused; network superuser and replication role refused."""
    res = {}
    for name, conn in [('plain_tcp', f'host={HOST} user=app dbname=app sslmode=disable'),
                       ('superuser_tls', f'host={HOST} user=postgres dbname=postgres sslmode=require'),
                       ('superuser_plain', f'host={HOST} user=postgres dbname=postgres sslmode=disable'),
                       ('app_tls', f'host={HOST} user=app dbname=app sslmode=require')]:
        code, out = csh(f'PGPASSWORD="$(cat {D}/pw)" psql -X -tAc "select current_user, ssl from '
                        f'pg_stat_ssl where pid=pg_backend_pid()" "{conn} connect_timeout=5"')
        res[name] = {'ok': code == 0, 'out': out.strip()[-200:]}
    code, out = csh(f'PGPASSWORD="$(cat {D}/pw)" psql -X "host={HOST} user=replicator dbname=replication '
                    f'replication=true sslmode=require connect_timeout=5" -c "IDENTIFY_SYSTEM"')
    res['replication_no_cert'] = {'ok': code == 0, 'out': out.strip()[-200:]}
    ok = (not res['plain_tcp']['ok'] and not res['superuser_tls']['ok'] and not res['superuser_plain']['ok']
          and res['app_tls']['ok'] and not res['replication_no_cert']['ok'])
    return record({'scenario': 'S17 TLS required', 'pass': ok, 'checks': res})


def s18():
    """Exhaust max_connections from a second process, then confirm a clean error and recovery."""
    tag = f's18-{int(time.time())}'
    wstart(tag)
    time.sleep(5)
    hog = (f"import psycopg2,time\npw=open('{D}/pw').read().strip()\ncs=[]\n"
           f"while len(cs)<400:\n"
           f"  try: cs.append(psycopg2.connect(host='{HOST}',user='app',dbname='app',password=pw,"
           f"sslmode='require',connect_timeout=5))\n"
           f"  except Exception as e: print(len(cs),'FULL',str(e).strip()[:200],flush=True); break\n"
           f"time.sleep(60)\n")
    csh(f'cat > {D}/hog.py', stdin=hog)
    csh(f'systemd-run --unit {unit("hog")} --property=StandardOutput=file:{D}/hog.log python3 {D}/hog.py')
    wait(lambda: 'FULL' in csh(f'cat {D}/hog.log')[1], 120, 3, 'connections exhausted')
    hog_out = csh(f'cat {D}/hog.log')[1].strip()
    code, newconn = csh(f'PGPASSWORD="$(cat {D}/pw)" psql -X -tAc "select 1" '
                        f'"host={HOST} user=app dbname=app sslmode=require connect_timeout=5"')
    alive_during = acks_count(tag)
    time.sleep(5)
    alive_during = acks_count(tag) - alive_during
    csh(f'systemctl stop {unit("hog")}; systemctl reset-failed {unit("hog")} 2>/dev/null; true')
    time.sleep(3)
    code2, after = csh(f'PGPASSWORD="$(cat {D}/pw)" psql -X -tAc "select 1" '
                       f'"host={HOST} user=app dbname=app sslmode=require connect_timeout=5"')
    wstop(tag)
    v = verify(tag)
    ok = code != 0 and code2 == 0 and v['lost_acked'] == 0
    return record({'scenario': 'S18 max_connections exhausted', 'pass': ok, 'hog': hog_out,
                   'new_conn_while_full': newconn.strip()[-200:], 'existing_writer_acks_in_5s': alive_during,
                   'new_conn_after_release_ok': code2 == 0, 'rpo_rows': v['lost_acked'],
                   'rto_s': rto_max(v)})


def s19(version):
    """App version change under writes. RPO 0, one short writer outage."""
    tag = f's19-{int(time.time())}'
    wstart(tag)
    time.sleep(15)
    p = pool()
    v0 = p['version']
    apps = p['apps']
    for a in apps:
        if a['name'].startswith('postgres'):
            a['version'] = version
    r = put_pool({'apps': apps})
    say('pool version', v0, '->', r.get('version'))
    wait_down(tag, 900)
    wait_outage_over(tag, 900)
    wait(lambda: not pool().get('park_reason'), 900, 10, 'pool settled')
    time.sleep(10)
    wstop(tag)
    return judge('S19 app version change', verify(tag), 120, extra={'to_version': version})


def resize(n):
    put_pool({'size': n})
    say('resize to', n)


def all_streaming(n):
    """node 1 reports n-1 streaming replicas."""
    code, out = ssh(1, "sudo -u postgres psql -X -tAc \"select count(*) from pg_stat_replication "
                       "where state='streaming'\" -h /var/run/postgresql")
    return code == 0 and out.strip().isdigit() and int(out.strip()) >= n - 1


def s7(seq='3,1'):
    """Resize through SEQ (e.g. 3,1 or 1,3) under writes: RPO 0, writer never down."""
    tag = f's7-{int(time.time())}'
    wstart(tag)
    time.sleep(10)
    steps = []
    for target in [int(x) for x in seq.split(',')]:
        t0 = time.time()
        resize(target)
        if target > 1:
            wait(lambda: all_streaming(target), 2400, 15, f'{target - 1} replicas streaming')
        wait(lambda: len([n for n in nodes() if not n.get('baking')]) == target
             and all(n['state'] == 'online' for n in nodes()), 1800, 10, f'{target} nodes')
        steps.append({'to': target, 'took_s': round(time.time() - t0)})
        say('reached', target, 'in', steps[-1]['took_s'], 's')
        time.sleep(20)
    wstop(tag)
    return judge(f'S7 scale {seq} under writes', verify(tag), 0, extra={'steps': steps})


def s6():
    """Terminate a replica under writes: writer unaffected, replica rebuilt."""
    tag = f's6-{int(time.time())}'
    wstart(tag)
    time.sleep(10)
    r = slot_node(2)
    t0 = time.time()
    api('POST', f"/api/nodes/{r['id']}/terminate", {'reason': 'pg harness S6'})
    say('terminated replica', r['name'])
    wait(lambda: (slot_node(2) or {}).get('id') not in (None, r['id']), 1800, 10, 'replacement slot 2 online')
    wait(lambda: all_streaming(3), 1200, 10, 'replica streaming again')
    t1 = time.time()
    wstop(tag)
    return judge('S6 replica loss', verify(tag), 0, extra={'rebuild_s': round(t1 - t0), 'replica': r['name']})


def s5():
    """Hard loss of node 1 with 2 replicas: RPO = replication lag (~0), RTO measured."""
    tag = f's5-{int(time.time())}'
    n0 = slot_node(1)
    wstart(tag)
    time.sleep(30)
    sysrq_off(n0['id'])
    say('sysrq power-off of node 1', n0['name'])
    wait_down(tag, 180)
    wait_outage_over(tag, 2400)
    time.sleep(10)
    wstop(tag)
    n1 = slot_node(1)
    decided = node_logs(n1['id'], '40m', ['postgres start:']) if n1 else []
    v = verify(tag)
    return judge('S5 writer loss, 2 replicas', v, 900, extra={'node_before': n0['name'],
                                                              'node_after': n1 and n1['name'],
                                                              'decision': decided[-4:]})


PROBE = r'''
import socket,ssl,struct,sys
host=sys.argv[1]; port=int(sys.argv[2]) if len(sys.argv)>2 else 5432
try:
    ip=socket.getaddrinfo(host,port,proto=socket.IPPROTO_TCP)[0][4][0]
except Exception as e:
    print('DNS_FAIL',e); sys.exit(3)
try:
    s=socket.create_connection((ip,port),timeout=5)
    s.sendall(struct.pack('!ii',8,80877103))
    r=s.recv(1)
    print('REACHED',ip,'sslrequest_reply',r)
except Exception as e:
    print('TCP_FAIL',ip,e); sys.exit(4)
'''


def probe_from(node_id, host, port=5432):
    """Postgres-level reachability from any node (python3 only): DNS, TCP, SSLRequest -> b'S'."""
    return nexec(node_id, ['python3', '-c', PROBE, host, str(port)])


def set_expose(expose, name=None):
    p = pool()
    apps = p['apps']
    for a in apps:
        if a['name'].startswith('postgres'):
            ep = {'expose': expose}
            if name:
                ep['name'] = name
            a['endpoints'] = {'pg': ep}
    r = put_pool({'apps': apps})
    say('expose', expose, name, 'pool version', r.get('version'))
    return r


def endpoints():
    return api('GET', f"/api/pools/{pool()['id']}/endpoints")['items']


FILL = '/var/lib/orc-postgres/primary/pgt-fill.bin'


def s9_fill():
    """Fill node 1's App-data file system (fallocate, nothing written to the host) under writes."""
    tag = f's9-{int(time.time())}'
    wstart(tag)
    time.sleep(10)
    code, out = ssh(1, f"avail=$(df -B1 --output=avail /var/lib/orc-postgres/primary | tail -1); "
                       f"fallocate -l $((avail - 8*1024*1024)) {FILL}; df -h /var/lib/orc-postgres/primary | tail -1")
    say('filled', code, out.strip())
    try:
        wait_down(tag, 300)
    except TimeoutError:
        say('writer never failed while full')
    time.sleep(20)
    print('\n'.join(ev(tag)[-6:]))
    return tag


def lag_load(rows=3_000_000, pad=2000):
    """One big INSERT on the writer (WAL burst) from the client, as a unit."""
    sql = (f"INSERT INTO ledger(id,writer,pad) SELECT 9000000000000000000-g,'lag',repeat(md5(g::text),{pad // 32}) "
           f"FROM generate_series(1,{rows}) g")
    code, out = csh(f'systemd-run --unit {unit("lag")} --setenv=PGPASSWORD="$(cat {D}/pw)" '
                    f'--property=StandardOutput=file:{D}/lag.log --property=StandardError=file:{D}/lag.log '
                    f'psql -X "host={HOST} user=app dbname=app sslmode=require" -c "{sql}"')
    assert code == 0, out


def lag(rows='3000000', secs='240'):
    """WAL burst on the writer; sample replica lag on node 1 and look for the lag warning."""
    tag = f'lag-{int(time.time())}'
    t0 = time.time()
    wstart(tag)
    lag_load(int(rows))
    samples = []
    end = time.time() + int(secs)
    q = ("select coalesce(max(extract(epoch from flush_lag)),0)::numeric(10,2), "
         "coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(),flush_lsn)),0)::bigint from pg_stat_replication")
    while time.time() < end:
        code, out = ssh(1, f'sudo -u postgres psql -X -tA -F " " -h /var/run/postgresql -c "{q}"')
        if code == 0 and out.strip():
            f, b = out.split()[:2]
            samples.append((round(time.time() - t0), float(f), int(b)))
        time.sleep(5)
    csh(f'systemctl stop {unit("lag")}; systemctl reset-failed {unit("lag")} 2>/dev/null; true')
    wstop(tag)
    n1 = slot_node(1)
    lines = node_logs(n1['id'], f'{int(time.time() - t0) + 60}s', ['postgres lag:'])
    warns = [n.get('warnings') for n in nodes()]
    sustained = max((s[1] for s in samples), default=0)
    v = verify(tag)
    return record({'scenario': 'replication lag under load', 'max_flush_lag_s': sustained,
                   'max_bytes_behind': max((s[2] for s in samples), default=0), 'samples': samples[::3],
                   'lag_log_lines': lines[-8:], 'node_warnings': warns, 'rpo_rows': v['lost_acked'],
                   'load': csh(f'cat {D}/lag.log')[1].strip()[-200:],
                   'pass': (sustained < 1) or any('WARNING' in x for x in lines)})


SCENARIOS = {'lag', 's9_fill','s1', 's2agent', 's2reboot', 's3', 's4', 's5', 's6', 's7', 's15', 's17', 's18', 's19'}


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else 'help'
    if cmd == 'push':
        push()
    elif cmd == 'nodes':
        for n in nodes():
            print(n['id'], n['name'], n.get('pool_slot'), n['state'], n.get('baking'), n.get('ip'),
                  n.get('warnings'))
    elif cmd == 'load':
        load(a[1])
    elif cmd == 'checksum':
        print(checksum())
    elif cmd == 'sh':
        print(*ssh(int(a[1]), ' '.join(a[2:])))
    elif cmd == 'wstart':
        wstart(a[1])
    elif cmd == 'wstop':
        wstop(a[1])
    elif cmd == 'verify':
        print(json.dumps(verify(a[1])))
    elif cmd == 'rp':
        print(latest_rp())
    elif cmd in SCENARIOS:
        globals()[cmd](*a[1:])
    else:
        print(__doc__)


if __name__ == '__main__':
    main()
