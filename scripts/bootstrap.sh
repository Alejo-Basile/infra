#!/usr/bin/env bash
# Bootstrap del entorno de desarrollo — S0-P1-02
# VERIFICA herramientas; NO instala en silencio. Si falta algo, dice como instalarlo.
set -u

ok=0; fail=0

check() {
  local name="$1" cmd="$2" install_hint="$3"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  [OK]      %-12s %s\n" "$name" "$(command -v "$cmd")"
    ok=$((ok+1))
  else
    printf "  [FALTA]   %-12s -> %s\n" "$name" "$install_hint"
    fail=$((fail+1))
  fi
}

echo "== Verificando toolchains =="
check "Docker"        docker    "https://docs.docker.com/engine/install/"
check "Compose v2"    docker    "docker compose version (plugin incluido en Docker >= 20.10)"
check "Go"            go        "https://go.dev/doc/install (version exacta en doc-service/go.mod)"
check "Rust"          cargo     "https://rustup.rs (canal en extraction-worker/rust-toolchain.toml)"
check "mc (MinIO)"    mc        "https://min.io/docs/minio/linux/reference/minio-mc.html#quickstart"
check "mkcert"        mkcert    "https://github.com/FiloSottile/mkcert#installation"
check "trivy"         trivy     "https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
check "gitleaks"      gitleaks  "https://github.com/gitleaks/gitleaks#installing"

# Compose plugin real (no el binario python viejo)
if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
  echo "  [FALTA]   plugin 'docker compose' v2 -> https://docs.docker.com/compose/install/linux/"
  fail=$((fail+1))
fi

# Registra el hook de pre-commit de gitleaks EN ESTE clone (los hooks viven
# por-clone, no se versionan). En los demas repos: `./scripts/install-hooks.sh`
# una vez por clone, o crear .git/hooks/pre-commit con `gitleaks git --staged`.
if command -v gitleaks >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  hook="$(git rev-parse --git-dir)/hooks/pre-commit"
  if [ ! -x "$hook" ]; then
    cat > "$hook" <<'EOF'
#!/usr/bin/env bash
# Instalado por infra/scripts/bootstrap.sh (S0-P1-04)
exec gitleaks git --staged --verbose
EOF
    chmod +x "$hook"
    echo "  [OK]      hook pre-commit gitleaks registrado en $(git rev-parse --git-dir)/hooks/pre-commit"
  else
    echo "  [OK]      hook pre-commit ya existe (no se pisa)"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "Entorno completo (${ok} herramientas). Siguiente paso: ./scripts/gen-certs.sh"
  exit 0
else
  echo "Faltan ${fail} herramienta(s). Instalalas con los enlaces de arriba y re-ejecuta este script."
  exit 1
fi
