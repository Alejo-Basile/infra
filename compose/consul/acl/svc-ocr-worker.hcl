# C30 extiende esta policy con key_prefix "config/ocr-worker/" y key_prefix "config/meta/" (read).
service "svc-ocr-worker" { policy = "write" }
node_prefix "" { policy = "read" }
agent_prefix "" { policy = "read" }
