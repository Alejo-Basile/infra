# Consul KV client contract (common)

Common KV client contract for doc-service (C11), ratelimitd (C12) and extraction-worker (C13, via shared crate `extraction-worker/crates/configkv/`). Fixtures in `infra/compose/consul/testdata/` are the parity oracle.

## 1. Startup and timeout
- Max 2 s waiting for KV at startup; if unresponsive, start with environment defaults.
- Precedence: default env -> last-known-good cache -> KV (KV only if it responds within timeout).

## 2. Last-known-good cache
- Path `/var/lib/<service>/config-cache.json`.
- Atomic write: `tmp` + `rename`, mode `0600`.
- Persisted after applying valid values; used when Consul unreachable.

## 3. Per-key rejection
- Type, range, coherence validated per key; invalid value rejected with key + reason in log, increments `*_config_kv_rejected_total{key}`, previous value stays.
- Rate-limiter exception: whole `Policy` swap is atomic (`atomic.Pointer[Policy]`); any parse failure discards entire new policy, keeps previous.

## 4. Blocking query + backoff
- `GET /v1/kv/config/<service>?recurse&index=<idx>&wait=5m`.
- Retries with exponential backoff 1 s -> 30 s with jitter.
- `index` monotonic; lower index responses ignored.

## 5. Serving traffic with KV down
- Service keeps serving; gauge `*_config_kv_stale` = 1 when last valid read older than 15 min; KV never critical path.

## 6. Logs
- Never include secret values; only key, rejection reason, metrics.

## 7. Fixtures
- Taxonomy/naming: `<service>.<case>.json`. `_expected` first key; namespace rule: keys starting with `_` are fixture metadata, ignored by clients; `_expected` never written to Consul KV.
- `schema.json` single source of validation truth; `coherence` expressions evaluated as a set, not per key.
- Reload modes: `hot` (apply at runtime), `hot-aumento` (increase only at runtime), `hot-jobs-nuevos` (new jobs only), `restart` (requires restart) per ADR-0022.
- manifest.json lists all 18 fixtures with verdict/key/reason.

## 8. Minimal API pseudocode
Go:
```
type Client struct { ... }
func NewClient(addr string, token string, cachePath string, timeout time.Duration) *Client
func (c *Client) LoadInitial(ctx context.Context) (map[string]string, error)
func (c *Client) Watch(ctx context.Context, onChange func(map[string]string)) error
func (c *Client) Validate(key string, value string, current map[string]string) error
func (c *Client) CacheSave(effective map[string]string) error
func (c *Client) CacheLoad() (map[string]string, error)
```
Rust:
```
pub struct KvClient { ... }
impl KvClient {
    pub fn new(addr: &str, token: &str, cache_path: &Path, timeout: Duration) -> Self;
    pub async fn load_initial(&self) -> Result<BTreeMap<String,String>, KvError>;
    pub async fn watch(&self, tx: mpsc::Sender<BTreeMap<String,String>>) -> Result<(), KvError>;
    pub fn validate(&self, key: &str, value: &str, current: &BTreeMap<String,String>) -> Result<(), KvError>;
    pub fn cache_save(&self, effective: &BTreeMap<String,String>) -> io::Result<()>;
    pub fn cache_load(&self) -> io::Result<BTreeMap<String,String>>;
}
```

## Cross-references
- ADR-0022: `infra/docs/adr/ADR-0022-consul-kv-contract.md`
- Plan §3: `docs/plan-S11-P1-consul.md`
- Schema: `infra/compose/consul/config/schema.json`
- Fixtures: `infra/compose/consul/testdata/`
- Clients implemented in C11-C13; fixtures are parity oracle.
