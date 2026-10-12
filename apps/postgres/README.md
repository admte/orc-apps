# postgres

PostgreSQL as a managed service. One node holds the data and takes writes; add more
nodes and each one streams from it as a hot standby.

Nodes are told apart by a number: **node 1 is the writer**, and every other node is a
replica that streams from it and keeps its copy across restarts. A single node is node 1, so
one node needs no configuration beyond a password.

## Quick start

One node, on a Debian or Ubuntu host:

```bash
printf 'choose-a-password' | sudo tee /root/pg.password >/dev/null
sudo chmod 600 /root/pg.password

sudo orc install postgres --password=@/root/pg.password
sudo orc start postgres
```

That installs PostgreSQL, creates a cluster, creates the `app` role and the `app`
database, generates a server certificate, and runs the server. Connections are encrypted
from the first one: the listener is TLS-only and plain TCP is refused.

```bash
# from another host
psql "host=<this-host> user=app dbname=app sslmode=require"

# on the node itself
sudo -u postgres psql                       # superuser, over the Unix socket
psql -h /var/run/postgresql -U app -d app   # the application role
```

## Which PostgreSQL version

The package installs one PostgreSQL major version per node, chosen by the version the
deployment selects. The runtime passes it to every phase as `APP_VERSION`, and the major
is all that matters, so `17` and `17.6` mean the same thing. With no version named the
package installs 17.

The major decides the packages (`postgresql-<major>`) and the binary path, so changing it
is a reinstall, not a restart. A node that already holds a cluster refuses to start
against a different major rather than attempting an in-place upgrade, since `pg_upgrade`
is a migration this package does not run for you.

The recipe declares no version discovery, so the catalog offers only what is published.
Add a `versions:` block to make a set of majors selectable.

Sensitive parameters must be passed as a file (`--password=@<path>`) or a secret URI,
never as a literal on the command line. `orc start` reuses the parameters given to
`orc install`, so they are only typed once. `orc status postgres`, `orc stop postgres`,
and `orc uninstall postgres` do what they say.

The generated certificate is self-signed, so `sslmode=require` encrypts but verifies
nothing. Supply your own certificate and CA to get a verifiable one — see
[TLS and trust](#tls-and-trust).

## Parameters

Required:

- `password` - the application role's password, presented over TLS with SCRAM.

Optional, with defaults:

- `app_user` - the application role, default `app`.
- `app_db` - the application database, owned by `app_user`, default `app`.
- `max_connections` - PostgreSQL `max_connections`, default `100`.

Optional, and only needed for more than one node or for verifiable TLS:

- `slot` - this node's number, 1-based and stable for its life. Default `1`.
- `pool` - a name shared by the nodes of one database; used as `cluster_name` in logs.
- `writer` - the host name of node 1. Required on a replica.
- `peers` - one host name per node of the database, one per line, node 1 included. On
  node 1 this is what turns on the freshness check of
  [Recovery and durability](#recovery-and-durability); without it node 1 trusts its own
  data.
- `ca` - PEM chain of the CA that issued the certificates below. Supplying it is what
  turns replication on.
- `server_cert`, `server_key` - the certificate the listener presents.
- `client_cert`, `client_key` - a replica's identity towards the writer. Required on a
  replica.

There is deliberately **no superuser password**. The `postgres` role has none and is
reachable only over the Unix socket, so administration is a shell on the node. Both the
superuser and the replication role are refused over the network ahead of every other
rule.

## Running more than one node

Replication is authenticated by certificate, so it needs a CA whose certificates the
nodes present to each other. Issue a server certificate per node, valid for the name
other nodes will dial it by, and one client certificate per replica.

On node 1:

```bash
sudo orc install postgres \
  --password=@/root/pg.password \
  --slot=1 --pool=db \
  --ca=@/etc/pki/ca.pem \
  --server-cert=@/etc/pki/node1.crt --server-key=@/etc/pki/node1.key
sudo orc start postgres
```

On node 2:

```bash
sudo orc install postgres \
  --password=@/root/pg.password \
  --slot=2 --pool=db --writer=node1.example.com \
  --ca=@/etc/pki/ca.pem \
  --server-cert=@/etc/pki/node2.crt --server-key=@/etc/pki/node2.key \
  --client-cert=@/etc/pki/node2-client.crt --client-key=@/etc/pki/node2-client.key
sudo orc start postgres
```

Node 2 seeds itself with `pg_basebackup` against the writer (`sslmode=verify-full`) and
follows it as a hot standby; on later starts it keeps its copy and resumes streaming. The
order you start the nodes in does not matter. What a node does when its copy and the
writer's disagree is in [Recovery and durability](#recovery-and-durability).

**Any client certificate the CA issued may replicate.** The writer maps every
certificate that CA signed onto the replication role; which certificates exist is the
CA's business. Use a CA scoped to this database, not a company-wide one.

Writes go to node 1. Replicas are read-only, and there is no automatic failover: if node
1 is lost, its replacement takes over as node 1, first making sure it holds the newest data
any node has. Replicas are never promoted. See
[Recovery and durability](#recovery-and-durability).

## Recovery and durability

Replication is asynchronous: node 1 acknowledges a commit once it is on its own disk, and
the replicas receive it a moment later. So **losing node 1 loses at most the replication
lag** — provided the newest copy is never thrown away. Three rules make sure of that.

1. **Node 1 is always the writer.** No replica is ever promoted and nothing moves the
   writer. The app never asks a control plane for permission to keep serving: a running
   writer keeps running whatever else is unreachable.
2. **A node 1 that cannot be sure it is the newest proves it before taking writes.** If a
   replica is ahead, node 1 copies from the freshest one. If it cannot ask a node that may
   hold newer data, it **waits**.
3. **A replica never deletes data node 1 does not have.**

### Positions

Every node can say where its data ends: the cluster's system identifier, its timeline, and
the last WAL position it holds. Node 1 asks each other node with `IDENTIFY_SYSTEM` over a
replication connection, authenticated by the same certificates replication uses; a standby
answers with the newer of what it received and what it replayed, and `TIMELINE_HISTORY`
says where each earlier timeline was left. A node asks its own cluster the same way over
the Unix socket, after letting it replay all the WAL it holds. That replay is required, not
a convenience: the control file (`pg_controldata`) records the last checkpoint, not the
end of the WAL, and a restored cluster holds WAL past its checkpoint — a node 1 that
under-read its own end would copy from a replica that is in fact behind it.

Data A **contains** data B when they share the system identifier and B's position lies on
A's history: the same timeline and not past A's position, or an earlier timeline that A
left at or after B's position. Otherwise B is **diverged** from A.

A node with no cluster answers too, as **empty**. Slot names answer while the machine is
online, whether or not PostgreSQL is listening, so without a positive answer an online
node with nothing listening could be a replica that holds data and is still starting —
and a new pool, or a pool that lost every node, would wait forever. So a node waiting to
be seeded runs a small stand-in server (its own throwaway cluster outside the data
directories) that accepts the replication role only, rejects everything else, and answers
`SHOW cluster_name` with the fixed marker `orc-postgres-empty`.

### Node 1 at start

`peers` (one name per allocated node, filled in by the orchestrator) is read at start and
is what turns the check on; with it, node 1 also needs `client_cert`, `client_key` and
`ca`. Without `peers`, node 1 trusts its own data, as a single node does.

- **It was the writer on this machine before** — a marker outside the durable root, keyed
  by the cluster's system identifier, says this machine opened this cluster (a service
  restart, a reboot with the disk intact). Its data is the newest by construction:
  replicas only ever receive WAL it has already written to its own disk. It starts at once
  and asks nobody.
- **Otherwise** (a replacement with a restored cluster, a replacement with nothing
  restored, a first start) it asks every other node in `peers`. Each answers one of:
  - data **contained in** node 1's — behind or equal, fine;
  - data **containing** node 1's and ahead of it — newer; the freshest such node is the
    source;
  - **empty** — holds nothing;
  - **diverged** data, or another cluster — logged and not used. Only a forced start
    (below) creates these, and that replica parks itself;
  - no answer: the name answers nothing (the machine is down), or nothing accepts the
    connection, or the server refuses it — **unknown**.

  Then:
  - **any node unknown → WAIT.** Node 1 does not open. It asks again after a pause that
    doubles from 5 s to 60 s, logging every round which nodes it waits for and why. An
    online replica whose server stays down keeps node 1 waiting indefinitely: read that
    replica's log, and force (below) if its data is not needed.
  - **a newer node → copy.** Node 1 copies the source with `pg_basebackup`, then strips the
    source's standby settings from the copy. The durable root holds one cluster, so node
    1's own cluster is discarded first; it is provably contained in the source's, so
    nothing is lost. If the source is lost mid-copy, node 1 now holds nothing and decides
    again from the beginning, against the nodes that remain.
  - **no data anywhere** (no local cluster, and every other node answered empty) →
    `initdb`, as for a new database.
  - With existing data, node 1 replays what it holds and **starts a new timeline** before
    opening. The new timeline begins at or after every replica's position, so every
    replica can follow it, and a replica holding anything past that point (only possible
    after a forced start) cannot follow it by accident: PostgreSQL refuses to follow a
    timeline that forked before its own position.

  A new pool of several nodes therefore opens once its replicas have booted and answered
  empty; a single-node pool asks nobody.

### Replicas at start

A replica keeps its cluster across restarts. It replays what it holds, reads its own
position, and asks node 1 for its position and history:

- **no local cluster, or one whose control file cannot be read** → seed from node 1 with
  `pg_basebackup`, answering *empty* until node 1 is open.
- **node 1 contains the replica's data** → keep it and stream. Before opening, streaming
  has to start and reach node 1's position as observed at that moment; if node 1 no longer
  holds the WAL needed to catch up, the replica's data is provably a subset of node 1's,
  and it re-seeds.
- **node 1 does not answer** → keep the data and run as a standby pointed at node 1. It
  streams once node 1 is back, and the timeline rule above stops it from following a node
  1 that forked behind it.
- **the replica holds data node 1 does not** — ahead on the same timeline, on a newer
  timeline, past the point node 1 left its timeline, or another cluster → **PARKED.** The
  data is kept, and the replica runs as a disconnected, read-only standby: an operator can
  read it, a later node 1 can still ask it for its position, and its readiness probe
  fails, so the node's endpoint shows **unready** and stops answering reads. Endpoint
  readiness feeds name resolution only, never node replacement, so a parked node is not
  replaced away.

Every replica holds a physical replication slot on node 1 (`replica_<N>`), so node 1 keeps
the WAL a restarting replica needs, up to `max_slot_wal_keep_size`; past that bound the slot
is given up rather than letting `pg_wal` fill the disk, and that replica re-seeds.

### Operator escape hatches

Both are one-shot files on the node itself: no control plane is involved, and a replacement
machine never inherits them.

- `touch /var/lib/orc-postgres/force-start` on a waiting node 1: it stops waiting for the
  unknown nodes and goes on with the freshest data among the nodes that answered, its own
  included. **Committed writes held only by the nodes it did not hear from are given up.**
  If no node that answered holds data, this **creates a new, empty database** — and the
  log says so before it does. The file is consumed by the decision it unblocks; if that
  decision ends back in WAIT (a copy failed), force again.
- `touch /var/lib/orc-postgres/release-parked` on a parked replica: its cluster is moved
  aside to `/var/lib/orc-postgres/replica/parked-<time>` (kept, not deleted; remove it once
  you have what you need from it) and the replica re-seeds from node 1.

### What an operator sees

Each decision is a log line in the app's log prefixed `postgres start:`, naming every node
and its position, for example:

```
postgres start: WAIT round 4: 1 of 2 nodes unknown: db-3.shop.internal offline; to stop waiting: touch /var/lib/orc-postgres/force-start
postgres start: copying from db-2.shop.internal (timeline 1, 0/C46EBE0; this node 0/C1E98A8)
postgres start: PARKED: this replica holds WAL past node 1's history (timeline 1, 0/C46EBE0; node 1 left timeline 1 at 0/C1E98A8)
```

While node 1 waits or copies, nothing listens for clients: its endpoint is unready and the
database name answers nothing, so clients see no writer rather than an old one. Captures of
the durable root are skipped (the capture hook exits non-zero) while node 1 recovers, so a
half-built cluster never becomes a restore point; a long wait therefore also shows up as
restore points not arriving.

Node 1 logs replication lag per replica as `postgres lag:` lines, with the lag in seconds
and bytes — every minute while any replica is more than 1 s behind or disconnected,
otherwise every ten minutes. A small watcher started next to the server writes them, in
the same service and to the same log.

## TLS and trust

The listener is always TLS. `pg_hba.conf` has no plain `host` rule, only `hostssl`, so
an unencrypted network connection is refused rather than downgraded.

| Supplied | Listener certificate | Clients should use |
|---|---|---|
| nothing | generated once, self-signed, reused across restarts | `sslmode=require` |
| `server_cert` + `server_key` + `ca` | yours | `sslmode=verify-full sslrootcert=<ca>` |

Certificates are re-staged on every start, so renewing one is a restart. Switching
between a supplied certificate and a generated one works in both directions: the app
never keeps serving a certificate that is no longer supplied.

## Where things live

| | Path |
|---|---|
| Durable root (the writer's data) | `/var/lib/orc-postgres/primary` |
| Writer cluster (`PGDATA`) | `/var/lib/orc-postgres/primary/pgdata` |
| Replica cluster (`PGDATA`) | `/var/lib/orc-postgres/replica/pgdata` |
| Certificates and keys | `/var/lib/orc-postgres/tls` |
| Node-local state (never restored elsewhere) | `/var/lib/orc-postgres/state` |
| Managed settings | `$PGDATA/conf.d/orc.conf`, `$PGDATA/pg_hba.conf`, `$PGDATA/pg_ident.conf` |
| Socket | `/var/run/postgresql` |
| Binaries | `/usr/lib/postgresql/<major>/bin` |
| Runs as | the `postgres` system account |

The managed files are rewritten on every start; edits to them do not survive a restart.
Anything else in `postgresql.conf` or `postgresql.auto.conf` is left alone.

Only the durable root is worth backing up. A replica's cluster is a copy of the writer,
so it is deliberately kept outside it; it is still never discarded while it holds
something the writer lacks (see [Recovery and durability](#recovery-and-durability)).

## Lifecycle

**install** adds the PGDG apt repository, turns off `postgresql-common`'s automatic
`main` cluster, installs `postgresql-<major>` and `postgresql-client-<major>`, and disables the
packaged `postgresql` umbrella unit. It writes no data, no secret, and no node identity,
so the result is identical on every node and safe to snapshot into a machine image.

**start** stages the certificates into the postgres account's own directory, then, by
node number:

- *Node 1* creates the cluster if the durable root is empty (`initdb`, data checksums, no
  superuser password) or adopts the one already there, refusing a cluster from another
  major version. It writes the managed settings, then creates the replication role, the
  application role and the application database on a socket-only postmaster, sets the
  application password, and `exec`s the real server. Because that runs on every start, an
  edited `password` or `max_connections` takes effect on the restart the edit triggers.
  A start with no password supplied and a cluster already present leaves the roles alone
  rather than failing, so a bare service restart after the parameter file is withdrawn
  does not turn into a crash loop.
- *Any other node* keeps its cluster when the writer's contains it, seeds from the
  writer with `pg_basebackup` when it has none, and `exec`s the server as a hot standby;
  [Recovery and durability](#recovery-and-durability) has every case.

**stop** is `SIGINT` — PostgreSQL's fast shutdown — with a 120s grace before the kill. A
kill past the grace costs crash recovery on the next start, never committed data.

**hook_pre** runs before a capture of the durable root, for deployments that snapshot app
data. A snapshot of the volume is crash-consistent without help, so the hook only bounds
how much WAL a restored cluster replays: on the writer it issues `CHECKPOINT` when more
than 64 MB of WAL (`CHECKPOINT_AFTER_MB`) has been written since the last checkpoint, and
otherwise only syncs. An idle database therefore writes nothing between captures, and a
busy one is not pushed into extra checkpoints, each of which makes the next write to every
page a full-page image in the WAL. A failed checkpoint skips that capture rather than
taking an inconsistent one.

**Sizing** comes from the machine on every start: `shared_buffers` a quarter of memory,
`effective_cache_size` three quarters, `max_wal_size` a quarter of the data directory's
file system (96 MB to 8 GB), `checkpoint_timeout` 15 minutes. A node that cannot have
replicas (no `ca`, or `peers` naming only itself) keeps no extra WAL
(`wal_keep_size = 0`). `ALTER SYSTEM` overrides any of them.

## Automatic configuration

Every parameter above can be passed by hand, which is what the examples do. The optional
ones additionally carry an `x-source` annotation, so an orchestrator that understands
those kinds can fill them in for you — the node's number, the writer's address, the CA,
and a certificate and key per node — and you supply only the password. That is a
convenience, not a requirement: nothing in the app depends on it.

## Build + Push

From the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`:

```bash
./orc build ./apps/postgres --push
```

Validate locally without pushing:

```bash
./orc build ./apps/postgres --output /tmp/postgres-oci
```

## Running the phases by hand

The lifecycle scripts are ordinary shell and take their input from the environment, which
is useful when debugging a node:

```bash
sudo sh install-postgres.sh
sudo env SLOT=1 POOL=db PASSWORD_FILE=/root/pg.password sh start-postgres.sh
```

`<PARAM>_FILE` variables (`PASSWORD_FILE`, `CA_FILE`, `SERVER_CERT_FILE`,
`SERVER_KEY_FILE`, `CLIENT_CERT_FILE`, `CLIENT_KEY_FILE`) are how file-backed parameters
arrive; plain ones arrive upper-cased (`SLOT`, `POOL`, `WRITER`, `APP_USER`, `APP_DB`,
`MAX_CONNECTIONS`).
