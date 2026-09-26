from crosshire_apps.common.key_tree import key_tree, render
from crosshire_apps.profiles.probe_profile import parse_curl

CURL = r"""curl 'https://x.cloud.databricks.com/graphql/HistoryStatementPlanMetadata' \
  -H 'accept: */*' \
  -H 'content-type: application/json' \
  -H 'cookie: session=SECRET' \
  -H 'x-csrf-token: SECRET2' \
  -b 'more=SECRET3' \
  --data-raw '{"variables":{"id":"{statement_id}"}}'"""


def test_parse_curl_drops_credentials():
    method, url, headers, body = parse_curl(CURL)
    assert method == "POST" and url.endswith("/graphql/HistoryStatementPlanMetadata")
    assert headers == {"accept": "*/*", "content-type": "application/json"}
    assert "{statement_id}" in body
    assert "SECRET" not in repr((method, url, headers, body))


def test_key_tree_never_shows_values():
    doc = {"graph": {"nodes": [{"name": "SECRET_SQL", "rows": 5}, {"name": "x", "time": 1.5}]}, "ok": True}
    out = "\n".join(render(key_tree(doc)))
    assert "SECRET_SQL" not in out and "5" not in out.replace("length", "")
    assert "nodes: list (count 1, length 2..2)" in out
    assert "time: float" in out and "rows: int" in out


def test_inventory_collapses_config_maps():
    from crosshire_apps.classic.inventory import collapse
    ev = {"Event": "SparkListenerEnvironmentUpdate",
          "Spark Properties": {"spark.hadoop.fs.azure.account.key.PRIVATEACCOUNT": "SECRET"},
          "Classpath Entries": {"/PRIVATE/path.jar": "System Classpath"}}
    out = "\n".join(render(key_tree(collapse(ev))))
    assert "PRIVATE" not in out and "SECRET" not in out
