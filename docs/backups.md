# Backups

Two nightly CronJobs, each writing to its own persistent volume.

| File | What | When | Keeps |
|---|---|---|---|
| `k8s/backup-cronjob.yaml` | every non-system database in the shared CouchDB, dumped as JSON with documents and attachments | 02:17 | 14 days |
| `k8s/forgejo-backup.yaml` | Forgejo's repositories, database and config, through `forgejo dump` | 02:43 | a rolling window of archives |

Both use `concurrencyPolicy: Forbid` and retry a failed run twice. The Forgejo
job uses `forgejo dump` rather than copying the data directory because the
SQLite file is written to live, and a raw copy can be torn.

## What they protect against

Stated plainly, as in the manifests: the backup volumes are on the **same
disk** as the data. They protect against application-level loss (a bad
migration, a dropped database, a mistaken delete) and against deleting a
volume, since the copy lives in a different claim. They do **not** protect
against disk failure or losing the VM. That needs an offsite copy.

## Checking and restoring

```sh
kubectl -n backup get cronjob,job               # last runs
kubectl -n backup logs job/<job-name>           # what a run copied
kubectl -n backup create job --from=cronjob/couchdb-backup manual-$(date +%s)   # run one now
```

A CouchDB dump is the output of `_all_docs?include_docs=true&attachments=true`
for one database. To restore, strip the `_rev` fields and post the documents
back with `_bulk_docs`, into an empty database, then check the result through
the application before pointing anything at it.
