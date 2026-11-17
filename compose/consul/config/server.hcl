datacenter = "dc1"
data_dir = "/consul/data"
bind_addr = "0.0.0.0"
client_addr = "0.0.0.0"
server = true
bootstrap_expect = 1

ui_config {
  enabled = true
}

acl {
  enabled        = true
  default_policy = "deny"
}

telemetry {
  prometheus_retention_time = "30s"
}

ports {
  https = 8501
  http  = -1
}

ca_file                = "/run/secrets/consul_ca_cert"
cert_file              = "/run/secrets/consul_server_cert"
key_file               = "/run/secrets/consul_server_key"
verify_server_hostname = true
verify_outgoing        = true
verify_incoming        = false
