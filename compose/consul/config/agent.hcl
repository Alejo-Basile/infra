datacenter = "dc1"
data_dir = "/consul/data"
bind_addr = "0.0.0.0"
retry_join = ["consul"]

acl {
  enabled        = true
  default_policy = "deny"
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
