"""stall_evidence 的纯函数测试：判据错了就会误报正在干活的 agent。

跑法：`python3 -m unittest discover -s tests`
"""

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "stall_evidence.py"
SPEC = importlib.util.spec_from_file_location("stall_evidence", MODULE_PATH)
stall = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stall)

NOW = 1_000_000.0
CUTOFF = NOW - 900


class JudgeTest(unittest.TestCase):
    def test_worktree_write_after_cutoff_is_progress(self):
        verdict, evidence = stall.judge(NOW, CUTOFF, (NOW - 30, "/wt/a.rs"), None, None, True)
        self.assertEqual(verdict, "PROGRESSING")
        self.assertIn("/wt/a.rs", evidence)

    def test_head_commit_after_cutoff_is_progress(self):
        verdict, _ = stall.judge(NOW, CUTOFF, None, NOW - 60, None, True)
        self.assertEqual(verdict, "PROGRESSING")

    def test_transcript_growth_is_progress(self):
        verdict, evidence = stall.judge(NOW, CUTOFF, None, None, NOW - 5, True)
        self.assertEqual(verdict, "PROGRESSING")
        self.assertIn("transcript", evidence)

    def test_everything_quiet_is_quiet(self):
        verdict, _ = stall.judge(NOW, CUTOFF, (NOW - 5000, "/wt/a.rs"), NOW - 5000, NOW - 5000, True)
        self.assertEqual(verdict, "QUIET")

    def test_unreadable_transcript_is_unknown_not_quiet(self):
        """读不到一面观测时不能装成全静——那正是误报的入口。"""
        verdict, evidence = stall.judge(NOW, CUTOFF, None, None, None, False)
        self.assertEqual(verdict, "UNKNOWN")
        self.assertIn("transcript", evidence)


class NewestWriteTest(unittest.TestCase):
    def test_git_directory_is_pruned(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / "wt"
            (work / "src").mkdir(parents=True)
            (work / "src" / "a.rs").write_text("a")
            os.utime(work / "src" / "a.rs", (NOW - 5000, NOW - 5000))
            (work / ".git").mkdir()
            (work / ".git" / "index").write_text("x")
            os.utime(work / ".git" / "index", (NOW - 10, NOW - 10))
            newest = stall.newest_write(str(work), CUTOFF)
            self.assertIsNone(newest, "只有 .git 变了不算 agent 在干活")

    def test_recent_write_under_cutoff_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            (work / "a.rs").write_text("a")
            os.utime(work / "a.rs", (NOW - 5000, NOW - 5000))
            self.assertIsNone(stall.newest_write(str(work), CUTOFF))


class LookupTest(unittest.TestCase):
    PAYLOAD = (
        '{"result":{"agents":['
        '{"name":"","pane_id":"w1:p1","agent_status":"working"},'
        '{"name":"child","pane_id":"w2:p1","agent_status":"working",'
        '"agent_session":{"kind":"path","source":"herdr:pi","value":"/tmp/s.jsonl"}}]}}'
    )

    def test_agent_matches_by_pane_when_name_is_empty(self):
        agent = stall.agent_entry(self.PAYLOAD, "", "w1:p1")
        self.assertEqual(agent["pane_id"], "w1:p1")

    def test_transcript_path_needs_a_path_kind(self):
        agent = stall.agent_entry(self.PAYLOAD, "child", "w2:p1")
        self.assertEqual(stall.transcript_path(agent), "/tmp/s.jsonl")
        self.assertIsNone(stall.transcript_path({"agent_session": {"kind": "id", "value": "x"}}))

    def test_dispatch_entry_rejects_pane_mismatch(self):
        state = {"agents": {"child": {"pane": "w2:p1", "worktree": "/wt"}}}
        self.assertIsNotNone(stall.dispatch_entry(state, "child", "w2:p1"))
        self.assertIsNone(stall.dispatch_entry(state, "child", "w9:p9"))

    def test_broken_payload_is_not_an_exception(self):
        self.assertIsNone(stall.agent_entry("not json", "child", "w2:p1"))


class SummaryTest(unittest.TestCase):
    def test_missing_surfaces_render_as_dash(self):
        text = stall.summary(NOW, None, None, None)
        self.assertEqual(text.count("—"), 3)

    def test_ages_are_in_seconds(self):
        text = stall.summary(NOW, (NOW - 120, "/wt/a.rs"), NOW - 30, NOW - 600)
        self.assertIn("120s 前", text)
        self.assertIn("30s 前", text)
        self.assertIn("600s 前", text)


if __name__ == "__main__":
    unittest.main()
