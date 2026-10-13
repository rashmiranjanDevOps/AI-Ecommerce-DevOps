# Application analysis (Nexvion)

The platform is built **around** an existing application, so the first step was to find out what the
application needs. Source: `application/` (provided by the company, never modified by this project).

## Summary

| Question | Answer |
|---|---|
| Type | Static website: 3 HTML pages, 3 CSS files, 2 JavaScript files, 1 logo (about 380 KB in total) |
| Frontend requirements | Any web server that serves static files. No build step, no framework, no package manager |
| Backend requirements | **None.** All logic runs in the browser |
| Database requirements | **None.** State lives in each browser's `localStorage` |
| API endpoints | **None** from the application. The platform adds `/health` and `/version.txt`; `/nginx_status` is internal |
| Environment variables | **None** needed by the application. The platform uses `IMAGE_TAG`, `REGISTRY`, `PROXY_PORT`, `WEB_PORT`, `GRAFANA_*` (`docker/.env`) |
| Ports | Container listens on **8080** (unprivileged). Proxy 8080 -> host 80. Web also published on 8080 for direct tests |
| Dependencies | No npm/pip packages. Four third-party hosts are loaded by the *browser* (see below) |
| Build process | None. "Build" in the pipeline means lint + package + Docker image |
| Runtime requirements | Nginx 1.27, about 64 MB memory and a fraction of a CPU per pod. Stateless, so it scales horizontally |
| Health endpoints | None in the app. Added in `docker/nginx/default.conf`: `GET /health` -> `{"status":"ok"}` |
| Application logs | None from the app (it runs in the browser). Nginx writes JSON access logs to stdout and errors to stderr |

## Pages and features

`index.html` (home), `products.html` (catalogue with filters and search), `payment.html` (checkout).
12 products in 4 categories (Electronics, Fashion, Home, Accessories). Cart, registration, login and logout,
UPI / card / cash-on-delivery with field validation (10-digit phone, 6-digit PIN, 16-digit card, 3-digit CVV, MM/YY).

## State stored in the browser (`localStorage` keys)

`nexvionUsers`, `nexvionCurrentUser`, `nexvionCart`, `nexvionCheckout`, `nexvionLastOrder`.

## Third-party resources loaded by the browser

| Host | References | Used for |
|---|---|---|
| images.unsplash.com | 17 | product and hero images |
| fonts.googleapis.com / fonts.gstatic.com | 6 / 3 | web fonts |
| placehold.co | 2 | fallback image when an Unsplash image fails |

`scripts/check_assets.py` prints this list on every pipeline run, so a new third-party dependency is noticed.

## What this means for the DevOps design

| Finding | Consequence in this project |
|---|---|
| No backend, no database | No database backup or migration is needed. `backup.sh` backs up the site and configuration. Pods are stateless, so rolling, blue-green and canary releases are simple and any number of replicas is safe |
| No health endpoint | Added in Nginx, used by Docker `HEALTHCHECK`, Kubernetes probes, Prometheus (blackbox) and `health-check.sh` |
| No application metrics | Nginx metrics (requests, connections) through `nginx-prometheus-exporter`; availability and latency through blackbox probes; container/node metrics through cAdvisor and node-exporter |
| No application logs | Nginx access log in JSON (one line per request) feeds ELK and the AI analyzer |
| Images and fonts come from the internet | The site's look depends on those hosts. The Content-Security-Policy allow-lists exactly these four hosts |
| Static files | Long cache time for CSS/JS/images (7 days), no cache for HTML, gzip enabled |

## Findings to report to the application team (not changed here)

1. **Passwords are stored and compared in plain text** in `localStorage` (`script.js`, login and registration). This is acceptable for a demo only; a real shop needs a backend that stores password hashes.
2. **Inline `onerror` handlers** are generated as strings in `script.js` and `payment.js`. They force the CSP to allow `'unsafe-inline'` scripts. Replace with `addEventListener('error', ...)`, then remove `'unsafe-inline'` from `script-src`.
3. `logo.png` is about 294 KB. Converting it to WebP/SVG would cut the page weight noticeably.
4. There is no `alt`-less image, no duplicate id and no inline `<script>` block in the HTML, so the lint rules in `jenkins/lint/` pass without exceptions.
