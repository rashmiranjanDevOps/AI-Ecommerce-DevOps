import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import analyzer  # noqa: E402

SAMPLES = os.path.join(HERE, "..", "samples")


def load(name):
    with open(os.path.join(SAMPLES, name)) as fh:
        return fh.read().splitlines()


def names(report):
    return [f["name"] for f in report["findings"]]


class AnalyzerTests(unittest.TestCase):
    def test_database_timeout_example_from_the_specification(self):
        rep = analyzer.analyze(load("db-timeout.log"), "db-timeout")
        self.assertIn("Database connection timeout", names(rep))
        f = next(x for x in rep["findings"] if x["id"] == "db_timeout")
        self.assertEqual(f["cause"], "Database connectivity or configuration issue.")
        joined = " ".join(f["investigate"]).lower()
        for topic in ("availability", "network", "credentials", "connection limits"):
            self.assertIn(topic, joined)
        self.assertEqual(f["severity"], "high")

    def test_secrets_are_redacted_in_evidence(self):
        rep = analyzer.analyze(load("db-timeout.log"))
        blob = json.dumps(rep)
        self.assertNotIn("Sup3rS3cret", blob)
        self.assertIn("[REDACTED]", blob)

    def test_5xx_spike_detected_from_json_access_log(self):
        rep = analyzer.analyze(load("nginx-5xx.log"))
        self.assertIn("High rate of server errors (HTTP 5xx)", names(rep))
        self.assertIn("Bad gateway / no healthy upstream (502/503)", names(rep))
        self.assertIn(rep["overall_severity"], ("high", "critical"))
        self.assertGreater(rep["access_log_entries"], 50)

    def test_kubernetes_problems_are_classified_and_ordered_by_severity(self):
        rep = analyzer.analyze(load("k8s-crashloop.log"))
        got = names(rep)
        for expected in ("Out of memory (OOMKilled)", "Container crash loop", "Image pull failure", "Health probe failing"):
            self.assertIn(expected, got)
        self.assertEqual(rep["overall_severity"], "critical")
        order = [analyzer.SEVERITY_ORDER[f["severity"]] for f in rep["findings"]]
        self.assertEqual(order, sorted(order, reverse=True))

    def test_trivy_failure_in_pipeline_log(self):
        rep = analyzer.analyze(load("jenkins-trivy-fail.log"), "jenkins")
        self.assertIn("Vulnerabilities found by Trivy", names(rep))

    def test_healthy_log_has_no_findings(self):
        rep = analyzer.analyze(load("healthy.log"))
        self.assertEqual(rep["findings"], [])
        self.assertEqual(rep["overall_severity"], "info")
        self.assertIn("No known error patterns", rep["summary"])

    def test_renderers_produce_all_sections(self):
        rep = analyzer.analyze(load("db-timeout.log"), "x")
        md = analyzer.render_markdown(rep)
        for part in ("# Incident analysis report", "Possible root cause", "Suggested investigation", "Suggested remediation"):
            self.assertIn(part, md)
        self.assertIn("Possible cause", analyzer.render_text(rep))
        json.loads(json.dumps(rep))

    def test_cli_fail_on_returns_exit_code_2(self):
        path = os.path.join(SAMPLES, "k8s-crashloop.log")
        self.assertEqual(analyzer.main(["--file", path, "--fail-on", "high", "--output", os.devnull]), 2)
        self.assertEqual(analyzer.main(["--file", os.path.join(SAMPLES, "healthy.log"), "--fail-on", "low", "--output", os.devnull]), 0)

    def test_llm_step_is_skipped_without_api_key(self):
        os.environ.pop("ANTHROPIC_API_KEY", None)
        text, note = analyzer.llm_assessment(analyzer.analyze(load("db-timeout.log")))
        self.assertIsNone(text)
        self.assertIn("ANTHROPIC_API_KEY", note)

    def test_every_rule_is_complete_and_compiles(self):
        ids = set()
        for r in analyzer.RULES:
            for key in ("id", "name", "severity", "patterns", "cause", "investigate", "remediate"):
                self.assertIn(key, r)
            self.assertIn(r["severity"], analyzer.SEVERITY_ORDER)
            self.assertNotIn(r["id"], ids)
            ids.add(r["id"])
        analyzer.compile_rules(analyzer.RULES)


if __name__ == "__main__":
    unittest.main()
