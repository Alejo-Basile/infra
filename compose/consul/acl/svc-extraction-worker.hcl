key_prefix "config/extraction-worker/" { policy = "read" }
key_prefix "config/meta/" { policy = "read" }
service "svc-extraction-worker" { policy = "write" }
node_prefix "" { policy = "read" }
agent_prefix "" { policy = "read" }
