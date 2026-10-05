// Inicializacion idempotente de MongoDB — SPEC §3.6 / S0-P1-03
// 1. Replica Set rs0 (Change Streams y transacciones lo requieren)
// 2. Usuarios de aplicacion con minimo privilegio:
//    - app:    readWrite sobre MONGO_DATABASE (doc-service)
//    - worker: SOLO update sobre la coleccion `documents` (ADR-0006)

const rootUser = process.env.MONGO_INITDB_ROOT_USERNAME;
const rootPass = process.env.MONGO_INITDB_ROOT_PASSWORD;
const dbName = process.env.MONGO_DATABASE || "documents";
const appUser = process.env.MONGO_APP_USER;
const appPass = process.env.MONGO_APP_PASSWORD;
const workerUser = process.env.MONGO_WORKER_USER;
const workerPass = process.env.MONGO_WORKER_PASSWORD;

// --- Replica Set -------------------------------------------------------------
const admin = db.getSiblingDB("admin");
admin.auth(rootUser, rootPass);

try {
  const status = rs.status();
  print("Replica Set ya iniciado:", status.set);
} catch (e) {
  print("Iniciando Replica Set rs0...");
  rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "mongo:27017" }] });
  // Esperar a que el nodo sea primario antes de crear usuarios
  let ok = false;
  for (let i = 0; i < 30 && !ok; i++) {
    sleep(1000);
    try { ok = rs.status().myState === 1; } catch (_) { /* aun arrancando */ }
  }
  if (!ok) { throw new Error("rs0 no llego a PRIMARY en 30s"); }
  print("rs0 activo (PRIMARY).");
}

// --- Usuarios ----------------------------------------------------------------
const appDb = db.getSiblingDB(dbName);

// Idempotente y correctivo: si el usuario existe pero con roles distintos,
// los corrige con updateUser (evita dejar privilegios de mas tras cambios).
function upsertUser(db, user, pwd, roles) {
  const existing = db.getUser(user);
  const expected = JSON.stringify(roles.map(r => r.role + "@" + r.db).sort());
  if (!existing) {
    db.createUser({ user, pwd, roles });
    print("Usuario creado:", user);
    return;
  }
  const actual = JSON.stringify(existing.roles.map(r => r.role + "@" + r.db).sort());
  if (actual !== expected) {
    db.updateUser(user, { roles });
    print("Usuario actualizado (roles corregidos):", user, actual, "->", expected);
  } else {
    print("Usuario ya existe con roles correctos:", user);
  }
}

// doc-service: dueno del agregado, readWrite completo sobre su base
upsertUser(appDb, appUser, appPass, [{ role: "readWrite", db: dbName }]);

// worker (ADR-0006): SOLO update sobre la coleccion documents.
// Rol a medida: sin insert, sin delete, sin drop, sin admin.
appDb.createRole ? null : null;
try {
  appDb.createRole({
    role: "documentsUpdater",
    privileges: [{
      resource: { db: dbName, collection: "documents" },
      actions: ["update", "find"],
    }],
    roles: [],
  });
  print("Rol documentsUpdater creado.");
} catch (e) {
  if (String(e).includes("already exists")) print("Rol documentsUpdater ya existe.");
  else throw e;
}
upsertUser(appDb, workerUser, workerPass, [{ role: "documentsUpdater", db: dbName }]);

print("Inicializacion de Mongo completada.");
