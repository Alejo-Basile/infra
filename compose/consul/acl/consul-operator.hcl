acl = "write"
key_prefix "config/" { policy = "write" }
key_prefix "" { policy = "read" }
service_prefix "" { policy = "write" }
node_prefix "" { policy = "read" }
agent_prefix "" { policy = "write" }
operator = "read"
