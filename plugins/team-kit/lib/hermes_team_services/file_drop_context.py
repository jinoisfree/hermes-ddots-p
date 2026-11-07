"""Read-only drop context. Current rules and policy-safe events, at most ten."""
from __future__ import annotations

import json
from pathlib import Path
import re
import time

from hermes_team_services import learning, memory_recall, conversation_recall


def context(home, signals, profiles):
    query = " ".join([str(signals.get("feature", "")), " ".join(signals.get("kinds", [])),
                      str(signals.get("source", "")), str(signals.get("folder", "")),
                      " ".join(signals.get("hosts", [])), " ".join(signals.get("works", [])), str(signals.get("content", ""))[:2000]])
    memories = []
    for profile in profiles:
        local = Path(home) / "profiles" / profile
        try:
            index = memory_recall.snapshot(local, learning, persist_cache=False)
            memories += [m["excerpt"] for m in memory_recall.search(index, query, limit=10, kind="rule")]
            cfg = memory_recall.config(local)["learning"]
            options = conversation_recall.options(cfg)
            if options and (local / "state.db").exists():
                memories += [m["summary"] for m in conversation_recall.search_digests(local, query, options, now=time.time(), limit=10)]
        except (OSError, ValueError, KeyError):
            continue
    # Session-provenanced team_learn rules can report the action actually used.
    # Matching is exact on the thread; neither chat text nor an LLM guess is feedback.
    outcomes = {}
    user = str(signals.get("account", ""))
    if re.fullmatch(r"[A-Za-z0-9]{1,40}", user):
        from hermes_team_services.file_drop_review import LABELS
        try:
            doc = json.loads((Path(home) / "state/ddots-file-drop" / (user + ".json")).read_text())
            assignments = [json.loads(e["v"]) for k, e in doc["entries"].items() if k.startswith("a:") and e.get("v")]
            for assignment in assignments:
                if assignment["profile"] not in profiles or time.time() - assignment["at"] > 48 * 3600:
                    continue
                data = learning.load(Path(home) / "profiles" / assignment["profile"])
                for row in data["rules"].values():
                    src = row.get("source", {})
                    if (row.get("active") and row.get("via") == "conversation"
                            and src.get("chat_id") == assignment["room"] and src.get("thread_id") == assignment.get("ts") and assignment.get("ts")):
                        for action, label in LABELS.items():
                            if "ddots 처리 동작: " + label in row["rule"] and assignment.get("event"):
                                outcomes[assignment["event"]] = action
        except (OSError, ValueError, KeyError):
            pass
    from hermes_team_services.file_drop_suggest import secret
    return {"memories": [s[:650] for s in memories if not secret(s)][:10], "outcomes": outcomes}
