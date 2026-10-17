from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from savepilot.core import (
    ExtractedContent,
    FolderProfile,
    classify_subject,
    confirm_move,
    document_relationship,
    recommend,
    suggest_filename,
)


class SavePilotCoreTests(unittest.TestCase):
    def test_physics_subject_and_filename(self):
        content = ExtractedContent(
            "AP Physics C: Mech-1 Homework #3 force motion energy momentum",
            "PDF", "AP Physics C homework", [],
        )
        match = classify_subject("hw3", content.text)
        self.assertEqual(match[0], "物理")
        self.assertEqual(suggest_filename(Path("hw3.pdf"), content, match[0]), "AP物理C_力学_作业3.pdf")

    def test_profile_cannot_invent_subject(self):
        self.assertIsNone(classify_subject("hw4", "Complete questions one through ten before class"))

    def test_generic_invoice_naming(self):
        content = ExtractedContent("Invoice A1 amount due tax 2026-10-16", "PDF", "invoice amount due tax", [])
        self.assertEqual(suggest_filename(Path("scan001.pdf"), content, None), "发票_2026-10-16.pdf")

    def test_sensitive_credentials_are_redacted_and_named(self):
        from savepilot.core import _sanitize_sensitive
        raw = '{"accessToken":"eyJheader.payload.signature","sessionToken":"private-session-value-123456"}'
        sanitized, detected = _sanitize_sensitive(raw)
        self.assertTrue(detected)
        self.assertNotIn("private-session-value-123456", sanitized)
        content = ExtractedContent(
            sanitized,
            "Office 文档",
            "检测到敏感账号凭证；具体值已隐藏。",
            ["敏感凭证值已隐藏"],
        )
        self.assertEqual(
            suggest_filename(Path("1009.docx"), content, None),
            "敏感账号凭证_请勿分享.docx",
        )

    def test_protected_project_folder_is_not_hijacked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "van Linden.docx"
            source.write_text("misinformation repetition truth memory", encoding="utf-8")
            project = root / "数学竞赛提交_0915"
            nested = project / "research_extension"
            nested.mkdir(parents=True)
            profiles = [
                FolderProfile(str(project), {"misinformation": .8, "truth": .6}, 11, .08, [".md"]),
                FolderProfile(str(nested), {"misinformation": .8, "truth": .6}, 8, .42, [".md"]),
            ]
            result = recommend(source, [root], profiles)
            self.assertEqual(Path(result.destination).resolve(), root.resolve())

    def test_confirm_move_is_collision_safe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); inbox = root / "inbox"; target = root / "target"
            inbox.mkdir(); target.mkdir()
            source = inbox / "hw3.pdf"; source.write_bytes(b"one")
            (target / "physics.pdf").write_bytes(b"existing")
            from savepilot.core import Suggestion
            suggestion = Suggestion(str(source), str(target), "physics.pdf", "test", .9, False)
            moved = confirm_move(suggestion)
            self.assertEqual(moved.name, "physics 2.pdf")
            self.assertEqual((target / "physics.pdf").read_bytes(), b"existing")

    def test_cross_folder_document_relationship(self):
        relation = document_relationship(
            "建模2.docx",
            "投资组合模型在风险约束下优化股票资产配置，使预期收益最大并讨论标准差。",
            "金融数据问题讨论.md",
            "Markowitz portfolio optimization 分配股票与银行资产，权衡 expected return 和 volatility risk。",
        )
        self.assertIsNotNone(relation)
        self.assertEqual(relation.topic_name, "数学建模进阶课")

    def test_author_overlap_is_a_hard_negative(self):
        relation = document_relationship(
            "van Linden.docx",
            "Van der Linden studies misinformation repetition and perceived truth.",
            "数学竞赛提交.pdf",
            "Van der Linden is cited once in a bibliography for an unrelated geometry project.",
        )
        self.assertIsNone(relation)


if __name__ == "__main__":
    unittest.main()
