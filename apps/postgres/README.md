# postgres

PostgreSQL 17 as a runtime-managed service, one cluster per node. The pool's runtime slot
decides a node's role: **slot 1 is the writer** and keeps its data in the persisted root;
every other slot is a **streaming replica** that rebuilds itself from the writer on each
start. Clients that resolve the pool's bare name reach the writer; slot names reach
individual replicas for reads.

```text
postgres/
  artifact.yaml
  postgres-common.sh       shared paths and helpers; sourced by the scripts below
  install-postgres.sh      packages from the PGDG apt repository
  start-postgres.sh        TLS staging, initdb or seed, role reconciliation, exec postgres
  hook-pre-postgres.sh     CHECKPOINT before each capture of the persisted root
```

`install` and `start` resolve from the package by name; `hook_pre` names its script
explicitly, because capture hooks have no naming convention. `linux/amd64` and
`linux/arm64`, Debian and Ubuntu.

## Parameters

- `password` - **required**, sensitive. The application role's password. Clients present
  it with SCRAM over TLS.
- `app_user` - the application role, default `app`.
- `app_db` - the application database, owned by `app_user`, default `app`.
- `max_connections` - PostgreSQL `max_connections`, default `100`.

Everything else is filled in by the platform and hidden from operators: the node's slot
(`pool.slot`), the pool name (`pool.name`, used as `cluster_name` and in the replica's
`application_name`), the writer's internal name (`peers.first`), the project CA bundle
(`ca.bundle`), a server certificate and key (`tls.cert` with purpose `server_tls`), and a
client certificate and key (`tls.cert` with purpose `client_mtls`) that identify a replica
towards the writer.

There is deliberately **no superuser password**. The `postgres` role has none and is
reachable only over the Unix socket with peer authentication, so DBA work is a shell on the
node: `sudo -u postgres psql`. Both the superuser and the replication role are rejected
over the network before any other rule in `pg_hba.conf`.

## Where things live

| | Path |
|---|---|
| Persisted root (slot 1 only) | `/var/lib/orc-postgres/primary` |
| Writer cluster (`PGDATA`) | `/var/lib/orc-postgres/primary/pgdata` |
| Replica cluster (`PGDATA`, never captured) | `/var/lib/orc-postgres/replica/pgdata` |
| Staged TLS material | `/var/lib/orc-postgres/tls/{ca.pem,server.crt,server.key,client.crt,client.key}` |
| Managed settings | `$PGDATA/conf.d/orc.conf`, `$PGDATA/pg_hba.conf`, `$PGDATA/pg_ident.conf` |
| Socket | `/var/run/postgresql` |
| Binaries | `/usr/lib/postgresql/17/bin` |
| Runs as | the `postgres` system account |

The managed files are rewritten on every start; local edits to them do not survive a
restart. Anything else in `postgresql.conf` or `postgresql.auto.conf` is left alone.

## Lifecycle

**install** adds the PGDG apt repository, turns off `postgresql-common`'s automatic
`main` cluster, installs `postgresql-17` and `postgresql-client-17`, and disables the
packaged `postgresql` umbrella unit. It writes no data, no secret and no node identity,
so a pool bake can run it alone and snapshot the disk.

**start** stages the platform's TLS material into the postgres account's own directory
(the runtime's copies are unreadable to the database user, and certificates are short-lived,
so this happens on every start). Then, by slot:

- *Slot 1* takes ownership of the persisted root. An empty root gets `initdb` with data
  checksums and no superuser password; an existing cluster is checked to be version 17 and a
  stale `postmaster.pid` is cleared. The script writes the managed settings, starts a
  socket-only postmaster, creates the replication role and the application role if they are
  missing, sets the application password, creates the application database if it is missing,
  stops that postmaster, and `exec`s the real one. Because the reconciliation runs every
  start, an edited `password` or `max_connections` takes effect on the restart the edit
  triggers.
- *Any other slot* discards its previous cluster and runs `pg_basebackup -R` against the
  writer's slot name with `sslmode=verify-full`, retrying for up to 30 minutes while the
  writer is not yet reachable. The writer's name answers empty until a slot-1 member is
  online, so a replica started first simply waits. It then writes the managed settings and
  `exec`s the postmaster as a hot standby.

**stop** is `SIGINT`, PostgreSQL's fast shutdown, with a 120s grace before the kill. A
kill past the grace costs crash recovery on the next start, never committed data.

**hook_pre** runs before each capture of the persisted root. On slot 1 with a running
postmaster it issues `CHECKPOINT` and `sync`, so the snapshot's recovery replay is short; on
a replica or a stopped writer it only syncs. A failed checkpoint skips that capture.

## Replication and trust

Replication is authenticated by certificate alone. The platform issues every node's
client certificate with the subject `ORC mTLS client` from the project's CA, and
`pg_ident.conf` maps that subject onto the `replicator` role for `hostssl replication`
connections. Any node holding a certificate from the project CA can therefore stream from
the writer, and nothing else can: the role has no password. The replica verifies the writer
against the project CA bundle, and the writer's certificate carries its slot name, which is
exactly the name `peers.first` resolved to.

WAL is retained by size (`wal_keep_size = 1GB`) rather than by replication slot. A replica
rebuilds itself from scratch on every start anyway, and a slot left behind by a dead
replica would fill the writer's disk.

## Failure and scale

- A shrink ends the highest slot first, so slot 1 survives until the pool is empty.
- If the slot-1 node is lost, the platform replaces it and the replacement restores the
  persisted root into slot 1. There is no promotion of a replica; replicas stay read-only and
  re-seed from the restored writer.
- Restore points are crash-consistent snapshots. A restored writer replays WAL from its last
  checkpoint on start.
- The writer does not upgrade a cluster in place: a persisted root from another major
  version is refused with a message.

## Build + Push

From the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`:

```bash
./orc build ./apps/postgres --push
```

Validate locally without pushing:

```bash
./orc build ./apps/postgres --output /tmp/postgres-oci
```

## Manual test

Requires root on a Debian or Ubuntu host and PEM files standing in for what the platform
delivers:

```bash
sudo sh install-postgres.sh

# the writer
printf 'secret' > /tmp/pw
sudo env SLOT=1 POOL=db APP_USER=app APP_DB=app MAX_CONNECTIONS=100 \
  PASSWORD_FILE=/tmp/pw CA_FILE=/path/ca.pem \
  SERVER_CERT_FILE=/path/server.crt SERVER_KEY_FILE=/path/server.key \
  sh start-postgres.sh

# a replica, on another host, with WRITER pointing at the writer's name
sudo env SLOT=2 POOL=db WRITER=db-1.proj.internal \
  PASSWORD_FILE=/tmp/pw CA_FILE=/path/ca.pem \
  SERVER_CERT_FILE=/path/server.crt SERVER_KEY_FILE=/path/server.key \
  CLIENT_CERT_FILE=/path/client.crt CLIENT_KEY_FILE=/path/client.key \
  sh start-postgres.sh
```

Connect as the application role with `psql "host=db.proj.internal user=app dbname=app
sslmode=verify-full sslrootcert=/path/ca.pem"`.
