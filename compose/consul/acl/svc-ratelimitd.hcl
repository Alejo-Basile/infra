# Dual grant: plan §3.2 KV uses config/rate-limiter/ while task-6 §4.2 names
# config/ratelimitd/. Both prefixes are granted read access.
key_prefix "config/rate-limiter/" { policy = "read" }
key_prefix "config/ratelimitd/" { policy = "read" }
key_prefix "config/meta/" { policy = "read" }
service "svc-ratelimitd" { policy = "write" }
node_prefix "" { policy = "read" }
agent_prefix "" { policy = "read" }
