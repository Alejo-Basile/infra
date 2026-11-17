key_prefix "config/doc-service/" { policy = "read" }
key_prefix "config/meta/" { policy = "read" }
service "svc-doc-service" { policy = "write" }
node_prefix "" { policy = "read" }
agent_prefix "" { policy = "read" }
