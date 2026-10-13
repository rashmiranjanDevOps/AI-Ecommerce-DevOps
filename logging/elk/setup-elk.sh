#!/bin/sh
# One-shot setup run by the elk-setup container (or by hand with ES_URL/KIBANA_URL set):
#  - 14-day retention policy
#  - index template (1 shard, 0 replicas: single-node lab cluster)
#  - Kibana data views for application and system logs
set -eu
ES_URL="${ES_URL:-http://localhost:9200}"
KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"

echo "Waiting for Elasticsearch at $ES_URL ..."
i=0; until curl -fs "$ES_URL/_cluster/health" >/dev/null; do i=$((i+1)); [ "$i" -gt 60 ] && { echo "Elasticsearch not ready"; exit 1; }; sleep 5; done

echo "Creating ILM policy nexvion-logs (delete after 14 days)"
curl -fs -X PUT "$ES_URL/_ilm/policy/nexvion-logs" -H 'Content-Type: application/json' -d '{
  "policy": { "phases": {
    "hot":    { "actions": {} },
    "delete": { "min_age": "14d", "actions": { "delete": {} } }
  } }
}' && echo

echo "Creating index template nexvion-logs"
curl -fs -X PUT "$ES_URL/_index_template/nexvion-logs" -H 'Content-Type: application/json' -d '{
  "index_patterns": ["nexvion-logs-*", "nexvion-system-*"],
  "template": {
    "settings": { "number_of_shards": 1, "number_of_replicas": 0, "index.lifecycle.name": "nexvion-logs" },
    "mappings": { "properties": {
      "nginx": { "properties": {
        "status": { "type": "integer" },
        "request_time": { "type": "float" },
        "body_bytes_sent": { "type": "long" }
      } }
    } }
  }
}' && echo

echo "Waiting for Kibana at $KIBANA_URL ..."
i=0; until curl -fs "$KIBANA_URL/api/status" >/dev/null; do i=$((i+1)); [ "$i" -gt 60 ] && { echo "Kibana not ready"; exit 1; }; sleep 5; done

create_view() {
  # $1 = id, $2 = pattern, $3 = display name. A 400 means the view already exists.
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$KIBANA_URL/api/data_views/data_view" \
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"data_view\":{\"id\":\"$1\",\"title\":\"$2\",\"name\":\"$3\",\"timeFieldName\":\"@timestamp\"}}")
  echo "data view $1 -> HTTP $code"
}
create_view nexvion-logs   'nexvion-logs-*'   'Nexvion application logs'
create_view nexvion-system 'nexvion-system-*' 'Nexvion system logs'
echo "ELK setup finished."
