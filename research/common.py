"""Shared labels and text for build_page.py and build_report.py."""

FEATURES = [
    ("agent_status", "Status"), ("multi_session", "Several sessions"), ("permission_alert", "Needs-you alert"),
    ("approve_from_device", "Approve from it"), ("jump_to_session", "Jump to session"), ("token_usage_cost", "Tokens / cost"),
    ("plan_limits", "Plan limits"), ("personal_baseline_levels", "Levels vs you"), ("test_build_red_green", "Red to green"),
    ("loop_stuck_detection", "Loops / stuck"), ("drift_away_detection", "Drift / away"), ("ai_session_recap", "AI recap"),
    ("history_dashboard", "History"), ("streaks_goals_achievements", "Streaks / goals"), ("leaderboard", "Leaderboard"),
    ("character_personality", "Character"), ("sound_voice_out", "Sound"), ("voice_input", "Voice input"),
    ("physical_controls", "Buttons"), ("second_screen_mode", "Own screen"),
]

STAGE = {
    "concept": "Concept", "prototype": "Prototype", "crowdfunding-upcoming": "Crowdfunding soon",
    "crowdfunding-live": "Crowdfunding now", "crowdfunding-ended": "Campaign ended", "preorder": "Pre-order",
    "shipping": "Shipping", "released": "Released", "hobby-project": "Hobby project", "abandoned": "Abandoned",
    "announced": "Announced", "unknown": "Unknown",
}

CATEGORY = {
    "agent-hardware-display": "Agent desk displays and lights", "agent-hardware-controller": "Agent controllers and keypads",
    "desktop-companion": "Desktop companions", "usage-monitor": "Usage and cost monitors",
    "approval-remote": "Approval and remote", "orchestration": "Multi-session orchestrators",
    "gamification-analytics": "Gamification and analytics", "adjacent-desk-gadget": "General desk gadgets",
    "platform-feature": "Platform features", "other": "Other",
}


def method_text(counts, finders, spot_checked):
    return (
        f"{len(finders)} search runs across crowdfunding sites, maker sites, GitHub, Product Hunt, Hacker News, Reddit, "
        f"press, non-English sources and platform docs turned up {counts.get('candidates', 0):,} mentions. "
        f"Merging duplicates left {counts.get('catalogue', 0):,} products ({counts.get('dropped_by_dedup', 0)} dropped as out of scope). "
        f"The {counts.get('profiled', '?')} that matter most (every crowdfunded or sold device, the biggest pets and limit monitors, "
        f"and the ones the team named) were profiled from their own pages against the same 20-point checklist. A second "
        f"researcher then tried to disprove each record and made {counts.get('verify_changes', '?')} corrections. "
        f"{counts.get('adjacent', '?')} adjacent gadgets and platform features got a short profile. A completeness review searched "
        f"for gaps and re-checked weak claims. Finally, {spot_checked} headline claims were checked again by agents told to refute "
        f"them; all held, four with small corrections. The write-up was then rewritten from the corrected data and "
        f"fact-checked against it. Searching stopped after two rounds to save usage while some lanes were still finding new "
        f"things, so the long tail of hobby projects is not complete."
    )
