#!/usr/bin/env python3
"""Generate the Grafana dashboards (valid JSON) for Nexvion.

Outputs:
  monitoring/grafana/dashboards/nexvion-docker.json         (Docker Compose stack)
  monitoring/kubernetes/nexvion-k8s-dashboard.json          (Kubernetes)
  monitoring/kubernetes/grafana-dashboard-configmap.yaml    (loaded by the Grafana sidecar)

Run:  python3 monitoring/grafana/build_dashboards.py
"""
import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DS = {"type": "prometheus", "uid": "prometheus"}


class Board:
    def __init__(self, title, uid, tags):
        self.title, self.uid, self.tags = title, uid, tags
        self.panels, self._id, self._x, self._y, self._rowh = [], 0, 0, 0, 0

    def _place(self, w, h):
        if self._x + w > 24:
            self._x, self._y, self._rowh = 0, self._y + self._rowh, 0
        pos = {"x": self._x, "y": self._y, "w": w, "h": h}
        self._x += w
        self._rowh = max(self._rowh, h)
        return pos

    def _panel(self, kind, title, queries, w, h, unit=None, extra=None, options=None):
        self._id += 1
        p = {
            "id": self._id, "type": kind, "title": title, "datasource": DS,
            "gridPos": self._place(w, h),
            "targets": [{"refId": chr(65 + i), "datasource": DS, "expr": q[0], "legendFormat": q[1]}
                        for i, q in enumerate(queries)],
            "fieldConfig": {"defaults": {"unit": unit or "short"}, "overrides": []},
            "options": options or {},
        }
        if extra:
            p["fieldConfig"]["defaults"].update(extra)
        self.panels.append(p)

    def row(self, title):
        self._x, self._y, self._rowh = 0, self._y + self._rowh, 0
        self._id += 1
        self.panels.append({"id": self._id, "type": "row", "title": title, "collapsed": False,
                            "gridPos": {"x": 0, "y": self._y, "w": 24, "h": 1}, "panels": []})
        self._y += 1

    def stat(self, title, expr, w=4, h=4, unit=None, thresholds=None, legend=""):
        extra = {}
        if thresholds:
            extra["thresholds"] = {"mode": "absolute", "steps": thresholds}
        self._panel("stat", title, [(expr, legend)], w, h, unit, extra,
                    {"colorMode": "background", "graphMode": "none",
                     "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}})

    def gauge(self, title, expr, w=6, h=6, unit="percent"):
        steps = [{"color": "green", "value": None}, {"color": "orange", "value": 70}, {"color": "red", "value": 90}]
        self._panel("gauge", title, [(expr, "")], w, h, unit,
                    {"min": 0, "max": 100, "thresholds": {"mode": "absolute", "steps": steps}},
                    {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}})

    def graph(self, title, queries, w=12, h=8, unit=None):
        self._panel("timeseries", title, queries, w, h, unit, None,
                    {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}})

    def bars(self, title, queries, w=12, h=6, unit="percent"):
        steps = [{"color": "green", "value": None}, {"color": "orange", "value": 70}, {"color": "red", "value": 90}]
        self._panel("bargauge", title, queries, w, h, unit,
                    {"min": 0, "max": 100, "thresholds": {"mode": "absolute", "steps": steps}},
                    {"orientation": "horizontal", "displayMode": "gradient",
                     "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}})

    def json(self):
        return {"uid": self.uid, "title": self.title, "tags": self.tags, "schemaVersion": 39, "version": 1,
                "editable": True, "refresh": "30s", "time": {"from": "now-1h", "to": "now"},
                "timezone": "browser", "panels": self.panels, "templating": {"list": []},
                "annotations": {"list": []}}


GREEN_RED = [{"color": "red", "value": None}, {"color": "orange", "value": 90}, {"color": "green", "value": 99}]
OK = [{"color": "green", "value": None}]
BAD = [{"color": "green", "value": None}, {"color": "red", "value": 1}]
WARN = [{"color": "green", "value": None}, {"color": "orange", "value": 1}]
CPU = '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
MEM = '(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100'


def docker_board():
    b = Board("Nexvion - Platform Overview (Docker)", "nexvion-docker", ["nexvion", "docker"])
    b.row("Application availability")
    b.stat("Availability (all probes)", 'avg(probe_success{job="blackbox-http"}) * 100', w=6, unit="percent", thresholds=GREEN_RED)
    b.stat("Containers running", 'count(container_memory_working_set_bytes{name=~"nexvion-.*"})', w=6, thresholds=OK)
    b.stat("Failed probes", 'count(probe_success{job="blackbox-http"} == 0) or vector(0)', w=6, thresholds=BAD)
    b.stat("Active Nginx connections", 'sum(nginx_connections_active)', w=6, thresholds=OK)
    b.graph("Probe result per endpoint (1 = up)", [('probe_success{job="blackbox-http"}', "{{instance}}")], unit="short")
    b.graph("Response time per endpoint", [('probe_duration_seconds{job="blackbox-http"}', "{{instance}}")], unit="s")
    b.row("CPU, memory and resource utilization")
    b.gauge("CPU usage", CPU)
    b.gauge("Memory usage", MEM)
    b.gauge("Disk usage (root)", '(1 - node_filesystem_avail_bytes{mountpoint="/host",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{mountpoint="/host",fstype!~"tmpfs|overlay"}) * 100')
    b.stat("Load average (1m)", "node_load1", w=6, h=6, thresholds=WARN)
    b.graph("Container CPU (%)", [('sum by (name) (rate(container_cpu_usage_seconds_total{name=~"nexvion-.*"}[5m])) * 100', "{{name}}")], unit="percent")
    b.graph("Container memory", [('container_memory_working_set_bytes{name=~"nexvion-.*"}', "{{name}}")], unit="bytes")
    b.row("Nginx")
    b.graph("Requests per second", [("rate(nginx_http_requests_total[1m])", "requests/s")])
    b.graph("Connections", [("nginx_connections_active", "active"), ("nginx_connections_reading", "reading"),
                            ("nginx_connections_writing", "writing"), ("nginx_connections_waiting", "waiting")])
    return b.json()


def k8s_board():
    ns = 'namespace="nexvion"'
    b = Board("Nexvion - Kubernetes Overview", "nexvion-k8s", ["nexvion", "kubernetes"])
    b.row("Application availability")
    b.stat("Available replicas (%)", f"sum(kube_deployment_status_replicas_available{{{ns}}}) / sum(kube_deployment_spec_replicas{{{ns}}}) * 100",
           w=8, unit="percent", thresholds=GREEN_RED)
    b.stat("Pod restarts (total)", f"sum(kube_pod_container_status_restarts_total{{{ns}}})", w=8, thresholds=WARN)
    b.stat("Requests per second", 'sum(rate(nginx_http_requests_total{namespace="nexvion"}[1m]))', w=8, thresholds=OK, unit="reqps")
    b.row("Pod status")
    for ph, th in (("Running", OK), ("Pending", WARN), ("Failed", BAD)):
        b.stat(f"Pods {ph}", f'sum(kube_pod_status_phase{{{ns},phase="{ph}"}}) or vector(0)', w=8, thresholds=th)
    b.row("Node status")
    for label, st, th in (("Ready", "true", OK), ("Not Ready", "false", BAD), ("Unreachable (unknown)", "unknown", BAD)):
        b.stat(f"Nodes {label}", f'sum(kube_node_status_condition{{condition="Ready",status="{st}"}}) or vector(0)', w=8, thresholds=th)
    b.row("CPU, memory and resource utilization")
    b.gauge("Node CPU usage", CPU, w=8)
    b.gauge("Node memory usage", MEM, w=8)
    b.gauge("Deployment replicas ready (%)", f"sum(kube_deployment_status_replicas_ready{{{ns}}}) / sum(kube_deployment_spec_replicas{{{ns}}}) * 100", w=8)
    b.graph("CPU by pod (cores)", [(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{ns},container!=""}}[5m]))', "{{pod}}")])
    b.graph("Memory by pod", [(f'sum by (pod) (container_memory_working_set_bytes{{{ns},container!=""}})', "{{pod}}")], unit="bytes")
    b.graph("Replicas (HPA current vs desired)", [(f"kube_horizontalpodautoscaler_status_current_replicas{{{ns}}}", "current"),
                                                  (f"kube_horizontalpodautoscaler_status_desired_replicas{{{ns}}}", "desired")])
    b.graph("Pod restarts", [(f"sum by (pod) (kube_pod_container_status_restarts_total{{{ns}}})", "{{pod}}")])
    return b.json()


def write(path, data):
    path = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(data)
    print("wrote", os.path.relpath(path, ROOT))


if __name__ == "__main__":
    docker = json.dumps(docker_board(), indent=2)
    k8s = json.dumps(k8s_board(), indent=2)
    write("monitoring/grafana/dashboards/nexvion-docker.json", docker + "\n")
    write("monitoring/kubernetes/nexvion-k8s-dashboard.json", k8s + "\n")
    indented = "\n".join("    " + line for line in k8s.splitlines())
    cm = ("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: nexvion-k8s-dashboard\n  namespace: monitoring\n"
          "  labels:\n    grafana_dashboard: \"1\"\n  annotations:\n    grafana_folder: Nexvion\n"
          "data:\n  nexvion-k8s.json: |\n" + indented + "\n")
    write("monitoring/kubernetes/grafana-dashboard-configmap.yaml", cm)
