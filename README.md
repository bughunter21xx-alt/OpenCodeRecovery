# =============================================================================
# HOW SESSION RECOVERY WORKS
# =============================================================================
#
# 1. SESSION IDENTIFICATION:
#    The script retrieves all sessions via `opencode session list --format json`.
#    Each session has an ID (e.g., "abc123") and an "updated" timestamp (epoch ms).
#
# 2. DETECTING RUNNING SESSIONS:
#    To avoid recovering sessions that are currently active, we use multiple methods:
#    - Scan running processes: `ps aux | grep opencode | grep --session`
#    - Check environment: $OPENCODE, $OPENCODE_PID, $OPENCODE_SESSION_ID
#    - Exclude sessions updated in the last 3 minutes (180 seconds)
#
# 3. CLUSTER DETECTION LOGIC:
#    When OpenCode crashes, multiple sessions typically stop updating around the
#    same time. The script groups sessions into "clusters" based on time gaps:
#
#    a) Sort all sessions by their "updated" timestamp (newest first)
#    b) Calculate time difference between consecutive sessions
#    c) If gap > 300 seconds (5 min), start a new cluster
#    d) Each cluster represents one crash event
#
#    Example:
#    Session A: updated at 10:00:00 (most recent)
#    Session B: updated at 10:00:05  (gap: 5s - same cluster)
#    Session C: updated at 09:55:00  (gap: 5min5s - NEW CLUSTER)
#    Session D: updated at 09:50:00  (gap: 5min - same cluster)
#
# 4. RECOVERY:
#    The most recent cluster is assumed to be the latest crash. Users can
#    interactively select older clusters if needed. Each session in the cluster
#    is launched with: opencode --session <session_id>
#
# =============================================================================
