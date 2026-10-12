# Databricks notebook source
# DBTITLE 1,About this notebook
# MAGIC %md
# MAGIC # Workspace bootstrap validation
# MAGIC
# MAGIC Validates that this workspace and its bootstrap configuration were provisioned as expected by
# MAGIC `dbx-platform-infra-aws` (workspace stack + workspace-bootstrap stack). The same notebook is deployed to every
# MAGIC environment (dev, uat, prod); the expected values come from the JSON file the bootstrap stack writes next to it
# MAGIC (`/Shared/platform/workspace-bootstrap-validation.json`).
# MAGIC
# MAGIC | Section | Validates |
# MAGIC | --- | --- |
# MAGIC | Workspace and identity | Workspace ID, running user, compute |
# MAGIC | Unity Catalog metastore | Metastore assigned, expected metastore, region, visible from Spark |
# MAGIC | Workspace admins | Platform admin group is a workspace admin |
# MAGIC | Catalog | Exists, isolated, bound only to this workspace, storage root, grants |
# MAGIC | Storage credential | Exists, isolated, bound only to this workspace, backed by the expected IAM role |
# MAGIC | External location | Exists, URL, credential, isolated, bound only to this workspace, grants, server-side validation |
# MAGIC | External location file access | Write, read, list and delete a file in the S3 bucket (write tests) |
# MAGIC | Catalog managed storage | Create a schema and a managed table, write, read, drop (write tests) |
# MAGIC | Cluster policies | Expected policies exist |
# MAGIC | Secret scope | Expected scope exists |
# MAGIC | Network egress | S3 (Unity Catalog storage) and the public internet (NAT gateway) reachable from the driver |
# MAGIC | Summary | All results; the notebook fails if any check failed |
# MAGIC
# MAGIC **Run it** as a member of `DBX_Architect_Lab_Admin` on a Unity Catalog-enabled cluster (standard/shared or
# MAGIC dedicated/single-user access mode) or serverless compute. Set `run_write_tests` to `false` for a read-only run.
# MAGIC Write tests create and remove only temporary objects (`_bootstrap_validation/` files and a
# MAGIC `bootstrap_validation_<id>` schema). Unity Catalog keeps the dropped test table restorable (UNDROP) for up to
# MAGIC 7 days; the bootstrap stack deletes the catalog and external location with `force_destroy`, so this doesn't
# MAGIC block a destroy.

# COMMAND ----------

# DBTITLE 1,Parameters and expected configuration
import json
import socket
import uuid

from databricks.sdk import WorkspaceClient

dbutils.widgets.text("config_path", "/Workspace/Shared/platform/workspace-bootstrap-validation.json", "Config file")
dbutils.widgets.dropdown("run_write_tests", "true", ["true", "false"], "Run write tests")

CONFIG_PATH = dbutils.widgets.get("config_path")
RUN_WRITE_TESTS = dbutils.widgets.get("run_write_tests") == "true"

with open(CONFIG_PATH) as f:
    cfg = json.load(f)

w = WorkspaceClient()


def api_get(path, **query):
    return w.api_client.do("GET", path, query=query or None)


def api_post(path, body):
    return w.api_client.do("POST", path, body=body)


def norm(url):
    return (url or "").rstrip("/")


# --- Result tracking: every check records PASS / FAIL / WARN / SKIP / INFO. Re-running a cell replaces its results.
results = globals().get("results", [])


def start(section):
    results[:] = [r for r in results if r["section"] != section]


def record(section, name, status, detail=""):
    results.append({"section": section, "check": name, "status": status, "detail": str(detail)})
    print(f"[{status:<4}] {name}" + (f": {detail}" if detail != "" else ""))


def check(section, name, fn):
    """fn() returns (ok, detail). An exception counts as FAIL."""
    try:
        ok, detail = fn()
        record(section, name, "PASS" if ok else "FAIL", detail)
        return ok
    except Exception as e:  # noqa: BLE001 - report any API error as a failed check
        record(section, name, "FAIL", f"{type(e).__name__}: {e}")
        return False


def check_grants(section, securable_type, full_name, principals, privileges):
    """Each expected principal holds at least the expected privileges on the securable."""
    if not principals:
        record(section, "Grants", "SKIP", "grants disabled in the bootstrap config")
        return
    try:
        perms = api_get(f"/api/2.1/unity-catalog/permissions/{securable_type}/{full_name}")
    except Exception as e:  # noqa: BLE001
        record(section, "Grants readable", "FAIL", f"{type(e).__name__}: {e}")
        return
    actual = {a["principal"]: set(a.get("privileges", [])) for a in perms.get("privilege_assignments", [])}
    for principal in principals:
        missing = sorted(set(privileges) - actual.get(principal, set()))
        check(section, f"Grants for {principal}",
              lambda missing=missing, principal=principal: (
                  not missing,
                  f"missing {missing}" if missing else f"has {sorted(actual.get(principal, set()))}"))


def check_bound_to_this_workspace(section, securable_type, name):
    """Isolated securable bound to this workspace and no other (the metastore is shared by all environments)."""
    def fn():
        bindings = api_get(f"/api/2.1/unity-catalog/bindings/{securable_type}/{name}").get("bindings", [])
        ids = {str(b["workspace_id"]) for b in bindings}
        return ids == {str(cfg["workspace_id"])}, f"bound to {sorted(ids) or 'no workspace'}"
    check(section, "Bound only to this workspace", fn)


def check_isolation(section, securable_type, name, actual_mode, expected_mode):
    """Isolation mode matches the bootstrap config; bindings are checked only for isolated securables."""
    check(section, f"Isolation mode is {expected_mode}", lambda: (actual_mode == expected_mode, actual_mode))
    if expected_mode == "ISOLATION_MODE_ISOLATED":
        check_bound_to_this_workspace(section, securable_type, name)
    else:
        record(section, "Workspace bindings", "INFO", "open: usable from every workspace on the metastore")


print(f"Environment: {cfg.get('environment')}  |  workspace: {cfg.get('workspace_name')} ({cfg.get('workspace_id')})")
print(f"Config: {CONFIG_PATH}  |  write tests: {RUN_WRITE_TESTS}")
print(json.dumps(cfg, indent=2))

# COMMAND ----------

# DBTITLE 1,Validate workspace and identity
SECTION = "Workspace and identity"
start(SECTION)

me = api_get("/api/2.0/preview/scim/v2/Me")
record(SECTION, "Running as", "INFO", me.get("userName"))

assignment = api_get("/api/2.1/unity-catalog/current-metastore-assignment")
check(SECTION, "Workspace ID matches the bootstrap config",
      lambda: (str(assignment.get("workspace_id")) == str(cfg["workspace_id"]),
               f"actual {assignment.get('workspace_id')}, expected {cfg['workspace_id']}"))

try:
    record(SECTION, "Compute", "INFO",
           spark.conf.get("spark.databricks.clusterUsageTags.sparkVersion", "serverless or unknown runtime"))
except Exception:  # noqa: BLE001 - not available on every compute type
    record(SECTION, "Compute", "INFO", "serverless or unknown runtime")

# COMMAND ----------

# DBTITLE 1,Validate Unity Catalog metastore assignment
SECTION = "Unity Catalog metastore"
start(SECTION)

metastore_id = assignment.get("metastore_id")
check(SECTION, "A metastore is assigned to this workspace", lambda: (bool(metastore_id), metastore_id))

if cfg.get("metastore_id"):
    check(SECTION, "Assigned metastore is the expected one",
          lambda: (metastore_id == cfg["metastore_id"], f"actual {metastore_id}, expected {cfg['metastore_id']}"))
else:
    record(SECTION, "Assigned metastore is the expected one", "SKIP", "no metastore_id in the bootstrap config")

if metastore_id:
    def metastore_region():
        ms = api_get(f"/api/2.1/unity-catalog/metastores/{metastore_id}")
        ok = not cfg.get("region") or ms.get("region") == cfg["region"]
        return ok, f"{ms.get('name')} in {ms.get('region')} (expected region {cfg.get('region')})"
    check(SECTION, "Metastore region matches the workspace region", metastore_region)

def metastore_visible_from_spark():
    current = spark.sql("SELECT current_metastore()").first()[0]  # e.g. aws:us-east-2:<metastore-id>
    return bool(metastore_id) and metastore_id in current, current


check(SECTION, "Metastore visible from Spark (current_metastore())", metastore_visible_from_spark)

# COMMAND ----------

# DBTITLE 1,Validate platform admin group is a workspace admin
SECTION = "Workspace admins"
start(SECTION)

admin_group = cfg.get("admin_group")
if admin_group:
    def admin_group_is_admin():
        groups = api_get("/api/2.0/preview/scim/v2/Groups", filter='displayName eq "admins"').get("Resources", [])
        members = [m.get("display") for m in (groups[0].get("members", []) if groups else [])]
        return admin_group in members, f"workspace admins: {members}"
    check(SECTION, f"{admin_group} is a member of the workspace admins group", admin_group_is_admin)
else:
    record(SECTION, "Platform admin group is a workspace admin", "SKIP", "no admin_group in the bootstrap config")

# COMMAND ----------

# DBTITLE 1,Validate catalog (isolation, binding, storage root, grants)
SECTION = "Catalog"
start(SECTION)

cat_cfg = cfg["catalog"]
catalog_name = cat_cfg["name"]

if check(SECTION, f"Catalog {catalog_name} exists",
         lambda: (bool(api_get(f"/api/2.1/unity-catalog/catalogs/{catalog_name}").get("name")), catalog_name)):
    catalog = api_get(f"/api/2.1/unity-catalog/catalogs/{catalog_name}")
    record(SECTION, "Owner", "INFO", catalog.get("owner"))
    check(SECTION, "Isolation mode is ISOLATED",
          lambda: (catalog.get("isolation_mode") == "ISOLATED", catalog.get("isolation_mode")))
    check_bound_to_this_workspace(SECTION, "catalog", catalog_name)
    check(SECTION, "Storage root matches the bootstrap config",
          lambda: (norm(catalog.get("storage_root")) == norm(cat_cfg["storage_root"]),
                   f"actual {catalog.get('storage_root')}, expected {cat_cfg['storage_root']}"))
    check_grants(SECTION, "catalog", catalog_name, cat_cfg.get("grant_principals", []), cat_cfg.get("grant_privileges", []))

# COMMAND ----------

# DBTITLE 1,Validate storage credential (isolation, binding, IAM role)
SECTION = "Storage credential"
start(SECTION)

cred_cfg = cfg["storage_credential"]
cred_name = cred_cfg["name"]

if check(SECTION, f"Storage credential {cred_name} exists",
         lambda: (bool(api_get(f"/api/2.1/unity-catalog/storage-credentials/{cred_name}").get("name")), cred_name)):
    cred = api_get(f"/api/2.1/unity-catalog/storage-credentials/{cred_name}")
    role_arn = (cred.get("aws_iam_role") or {}).get("role_arn")
    check_isolation(SECTION, "storage_credential", cred_name, cred.get("isolation_mode"),
                    cred_cfg.get("isolation_mode", "ISOLATION_MODE_ISOLATED"))
    check(SECTION, "Backed by the expected IAM role",
          lambda: (bool(role_arn) and (not cred_cfg.get("iam_role_arn") or role_arn == cred_cfg["iam_role_arn"]),
                   f"actual {role_arn}, expected {cred_cfg.get('iam_role_arn')}"))

# COMMAND ----------

# DBTITLE 1,Validate external location (URL, credential, isolation, binding, grants, access)
SECTION = "External location"
start(SECTION)

el_cfg = cfg["external_location"]
el_name = el_cfg["name"]

if check(SECTION, f"External location {el_name} exists",
         lambda: (bool(api_get(f"/api/2.1/unity-catalog/external-locations/{el_name}").get("name")), el_name)):
    el = api_get(f"/api/2.1/unity-catalog/external-locations/{el_name}")
    record(SECTION, "Owner", "INFO", el.get("owner"))
    check(SECTION, "URL matches the bootstrap config",
          lambda: (norm(el.get("url")) == norm(el_cfg["url"]), f"actual {el.get('url')}, expected {el_cfg['url']}"))
    check(SECTION, "Uses the expected storage credential",
          lambda: (el.get("credential_name") == cred_name, el.get("credential_name")))
    check_isolation(SECTION, "external_location", el_name, el.get("isolation_mode"),
                    el_cfg.get("isolation_mode", "ISOLATION_MODE_ISOLATED"))
    check(SECTION, "Not read-only", lambda: (not el.get("read_only", False), f"read_only={el.get('read_only', False)}"))
    check_grants(SECTION, "external_location", el_name,
                 el_cfg.get("grant_principals", []), el_cfg.get("grant_privileges", []))

    # Server-side check that the credential's IAM role can use the bucket (trust policy and S3 policy). Only results
    # with an operation (READ, LIST, WRITE, DELETE, PATH_EXISTS, ...) are access checks; the response can also contain
    # results without one (notes about the request itself), which are reported separately as WARN with their message.
    try:
        validation = api_post("/api/2.1/unity-catalog/validate-storage-credentials",
                              {"storage_credential_name": cred_name, "external_location_name": el_name,
                               "read_only": False}).get("results", [])
    except Exception as e:  # noqa: BLE001
        validation = None
        record(SECTION, "Credential can access the location (server-side validation)", "FAIL",
               f"{type(e).__name__}: {e}")

    if validation is not None:
        operations = [r for r in validation if r.get("operation")]
        failed_ops = [r for r in operations if r.get("result") == "FAIL"]
        check(SECTION, "Credential can access the location (server-side validation)",
              lambda: (bool(operations) and not failed_ops,
                       {r["operation"]: r.get("result") + (f" ({r['message']})" if r.get("message") else "")
                        for r in operations}))
        for note in (r for r in validation if not r.get("operation")):
            record(SECTION, "Server-side validation note", "WARN" if note.get("result") == "FAIL" else "INFO",
                   f"{note.get('result')}: {note.get('message') or note}")

# COMMAND ----------

# DBTITLE 1,Validate external location file access (write, read, list, delete)
SECTION = "External location file access"
start(SECTION)

if not RUN_WRITE_TESTS:
    record(SECTION, "File round trip", "SKIP", "run_write_tests=false")
else:
    test_dir = f"{norm(el_cfg['url'])}/_bootstrap_validation"
    test_file = f"{test_dir}/{uuid.uuid4().hex}.txt"
    payload = f"bootstrap validation {uuid.uuid4().hex}"
    try:
        check(SECTION, "Write a file", lambda: (dbutils.fs.put(test_file, payload, overwrite=True) or True, test_file))
        check(SECTION, "Read it back", lambda: (dbutils.fs.head(test_file) == payload, "content matches"))
        check(SECTION, "List the directory",
              lambda: (any(f.path.rstrip("/").endswith(test_file.rsplit("/", 1)[1]) for f in dbutils.fs.ls(test_dir)),
                       test_dir))
    finally:
        check(SECTION, "Delete the test file", lambda: (dbutils.fs.rm(test_file) or True, "removed"))

# COMMAND ----------

# DBTITLE 1,Validate catalog managed storage (schema, managed table, write, read, drop)
SECTION = "Catalog managed storage"
start(SECTION)

if not RUN_WRITE_TESTS:
    record(SECTION, "Managed table round trip", "SKIP", "run_write_tests=false")
else:
    schema = f"`{catalog_name}`.`bootstrap_validation_{uuid.uuid4().hex[:8]}`"
    try:
        if check(SECTION, "Create a temporary schema", lambda: (spark.sql(f"CREATE SCHEMA {schema}") is not None, schema)):
            check(SECTION, "Create a managed table and insert rows",
                  lambda: (spark.sql(f"CREATE TABLE {schema}.t AS SELECT id FROM range(10)") is not None, f"{schema}.t"))
            def rows_read_back():
                rows = spark.table(f"{schema}.t").count()
                return rows == 10, f"{rows} rows"
            check(SECTION, "Read the rows back", rows_read_back)

            def location_under_storage_root():
                location = spark.sql(f"DESCRIBE DETAIL {schema}.t").first()["location"]
                return norm(location).startswith(norm(cat_cfg["storage_root"])), location
            check(SECTION, "Table data is under the catalog storage root", location_under_storage_root)
    finally:
        check(SECTION, "Drop the temporary schema",
              lambda: (spark.sql(f"DROP SCHEMA IF EXISTS {schema} CASCADE") is not None, schema))

# COMMAND ----------

# DBTITLE 1,Validate cluster policies
SECTION = "Cluster policies"
start(SECTION)

expected_policies = cfg.get("cluster_policies", [])
if not expected_policies:
    record(SECTION, "Cluster policies", "SKIP", "no cluster policies in the bootstrap config")
else:
    policy_names = {p["name"] for p in api_get("/api/2.0/policies/clusters/list").get("policies", [])}
    for policy in expected_policies:
        check(SECTION, f"Policy {policy} exists", lambda policy=policy: (policy in policy_names, policy))

# COMMAND ----------

# DBTITLE 1,Validate secret scope
SECTION = "Secret scope"
start(SECTION)

scope = cfg.get("secret_scope")
check(SECTION, f"Secret scope {scope} exists",
      lambda: (scope in {s["name"] for s in api_get("/api/2.0/secrets/scopes/list").get("scopes", [])}, scope))

# COMMAND ----------

# DBTITLE 1,Validate network egress from the driver
SECTION = "Network egress"
start(SECTION)


def reachable(host, port=443, timeout=5):
    try:
        socket.create_connection((host, port), timeout=timeout).close()
        return True
    except OSError:
        return False


# S3: classic compute reads and writes Unity Catalog data in the bucket directly (S3 gateway endpoint in the VPC).
storage_endpoint = cfg.get("storage_endpoint")
if storage_endpoint:
    check(SECTION, f"S3 reachable ({storage_endpoint}:443)",
          lambda: (reachable(storage_endpoint), "S3 gateway endpoint / NAT gateway"))
else:
    record(SECTION, "S3 reachable", "SKIP", "no storage_endpoint in the bootstrap config")

# Public internet: NAT gateway. A WARN is expected when the NAT gateway is disabled on purpose
# (network.nat_gateway_enabled: false); on serverless compute this tests Databricks' serverless egress, not the VPC.
if reachable("pypi.org"):
    record(SECTION, "Public internet reachable (pypi.org:443)", "PASS", "NAT gateway egress works")
else:
    record(SECTION, "Public internet reachable (pypi.org:443)", "WARN",
           "no outbound internet: expected only if the NAT gateway is disabled; library installs from PyPI/Maven will fail")

# COMMAND ----------

# DBTITLE 1,Validation summary
from collections import Counter

counts = Counter(r["status"] for r in results)
print("  ".join(f"{status}: {counts.get(status, 0)}" for status in ["PASS", "FAIL", "WARN", "SKIP", "INFO"]))

display(spark.createDataFrame(results, "section string, check string, status string, detail string"))

failures = [r for r in results if r["status"] == "FAIL"]
if failures:
    raise AssertionError(
        f"{len(failures)} validation check(s) failed in {cfg.get('environment')}:\n"
        + "\n".join(f"- {r['section']} / {r['check']}: {r['detail']}" for r in failures))

print(f"Workspace {cfg.get('workspace_name')} ({cfg.get('environment')}) passed bootstrap validation.")
