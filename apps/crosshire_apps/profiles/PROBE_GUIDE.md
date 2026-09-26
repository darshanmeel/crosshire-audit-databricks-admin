# Step 1: can a query profile be fetched with a token?

No public API returns a query profile. The UI loads it through an internal endpoint. This
probe finds out whether that endpoint answers a plain personal access token. Nothing is
built on top until the result is known.

## 1. Capture the request the UI makes

1. In Chrome, open **Query History**, pick a finished SQL warehouse query and open
   **See query profile**.
2. Press **F12**, open the **Network** tab and select **Fetch/XHR**.
3. Reload the page (Ctrl+R / Cmd+R) and wait for the profile to draw.
4. Find the request whose **Response** holds the operator tree. Click each request and look at
   the **Response** or **Preview** tab: look for node lists with names like `Scan`, `Join`,
   `Exchange`, and metrics such as rows or time. It is often a `graphql` request (for example
   `.../graphql/HistoryStatementPlanMetadata`) or something under `/sql/`.
5. Right-click that request › **Copy** › **Copy as cURL (bash)**.

## 2. Clean it before it leaves your machine

Paste it into a file, `request.txt`, and remove:

- every `-H 'cookie: ...'` line and any `-b '...'` argument;
- `authorization`, `x-csrf-token` and any other header holding a token or session id;
- anything else you would not paste in a ticket.

Then replace the statement id inside the URL or the `--data-raw` body with `{statement_id}`.
The probe drops cookie, authorization and CSRF headers again anyway.

Send me the cleaned request (or just its URL path, method and the body's key names) so the
fetcher can be built on the same shape.

## 3. Run the probe

```bash
export DATABRICKS_HOST=https://<workspace-host>
export DATABRICKS_TOKEN=<personal access token>   # environment only; never a file in the repo
cd apps
python -m crosshire_apps.profiles.probe_profile --curl request.txt --statement-id <statement_id>
```

It prints the HTTP status, the content type, the size and the JSON key tree (key names,
types, list lengths). It never prints values.

Run it three times:

| Statement | Where to find an id |
|---|---|
| SQL warehouse query | Query History, or `system.query.history` with `compute.type = 'WAREHOUSE'` |
| Serverless notebook statement | `system.query.history` with `compute.type = 'SERVERLESS_COMPUTE'` and `query_source.notebook_id` set |
| Serverless job statement | `system.query.history` with `compute.type = 'SERVERLESS_COMPUTE'` and `query_source.job_info` set |

## 4. Report

Paste the three outputs back. For each: the status (200, 401, 403 "Graph request not
authentic", 404), and for a 200 the key tree. If the token is refused, the fallback is a
Unity Catalog volume where people drop downloaded profile JSON files; the parser will read
those the same way.
