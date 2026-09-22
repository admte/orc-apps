# postgres

PostgreSQL 17 as a managed service. One node holds the data and takes writes; add more
nodes and each one streams from it as a hot standby.

Nodes are told apart by a number: **node 1 is the writer**, and every other node is a
replica that rebuilds itself from the writer on each start. A single node is node 1, so
one node needs no configuration beyond a password.

## Quick start

One node, on a Debian or Ubuntu host:

```bash
printf 'choose-a-password' | sudo tee /root/pg.password >/dev/null
sudo chmod 600 /root/pg.password

sudo orc install postgres --password=@/root/pg.password
sudo orc start postgres
```

That installs PostgreSQL 17, creates a cluster, creates the `app` role and the `app`
database, generates a server certificate, and runs the server. Connections are encrypted
from the first one: the listener is TLS-only and plain TCP is refused.

```bash
# from another host
psql "host=<this-host> user=app dbname=app sslmode=require"

# on the node itself
sudo -u postgres psql                       # superuser, over the Unix socket
psql -h /var/run/postgresql -U app -d app   # the application role
```

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

Node 2 discards whatever it had, runs `pg_basebackup` against the writer with
`sslmode=verify-full`, and follows it as a hot standby. A replica started before its
writer retries for up to 30 minutes, so the order you start them in does not matter.

**Any client certificate the CA issued may replicate.** The writer maps every
certificate that CA signed onto the replication role; which certificates exist is the
CA's business. Use a CA scoped to this database, not a company-wide one.

Writes go to node 1. Replicas are read-only, and there is no automatic failover: if node
1 is lost, its replacement restores node 1's data and takes over. Replicas are not
promoted.

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
| Replica cluster (`PGDATA`, disposable) | `/var/lib/orc-postgres/replica/pgdata` |
| Certificates and keys | `/var/lib/orc-postgres/tls` |
| Managed settings | `$PGDATA/conf.d/orc.conf`, `$PGDATA/pg_hba.conf`, `$PGDATA/pg_ident.conf` |
| Socket | `/var/run/postgresql` |
| Binaries | `/usr/lib/postgresql/17/bin` |
| Runs as | the `postgres` system account |

The managed files are rewritten on every start; edits to them do not survive a restart.
Anything else in `postgresql.conf` or `postgresql.auto.conf` is left alone.

Only the durable root is worth backing up. A replica's cluster is a copy of the writer
and is thrown away and rebuilt on each start, so it is deliberately kept outside it.

## Lifecycle

**install** adds the PGDG apt repository, turns off `postgresql-common`'s automatic
`main` cluster, installs `postgresql-17` and `postgresql-client-17`, and disables the
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
- *Any other node* discards its previous cluster, seeds from the writer with
  `pg_basebackup -R`, and `exec`s the server as a hot standby.

**stop** is `SIGINT` — PostgreSQL's fast shutdown — with a 120s grace before the kill. A
kill past the grace costs crash recovery on the next start, never committed data.

**hook_pre** runs before a capture of the durable root, for deployments that snapshot app
data. On the writer it issues `CHECKPOINT` and `sync`, so a restored cluster has little
WAL to replay; elsewhere it only syncs. A failed checkpoint skips that capture rather than
taking an inconsistent one.

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
