// Inicializacion idempotente de MongoDB — SPEC §3.6 / S0-P1-03
// 1. Replica Set rs0 (Change Streams y transacciones lo requieren)
// 2. Usuarios de aplicacion con minimo privilegio:
//    - app:    readWrite sobre MONGO_DATABASE (doc-service)
//    - worker: SOLO update sobre la coleccion `documents` (ADR-0006)

// Resuelve `${VAR}` o `${VAR}_FILE` (patron Docker secrets, S2-P1-01): si el
// compose monta el valor como archivo, se lee de /run/secrets/ en vez de
// interpolar el secreto en texto plano en el yaml.
function envOrFile(name) {
  const filePath = process.env[name + "_FILE"];
  if (filePath) {
    return require("fs").readFileSync(filePath, "utf8").replace(/\r?\n$/, "");
  }
  return process.env[name];
}

const rootUser = process.env.MONGO_INITDB_ROOT_USERNAME;
const rootPass = envOrFile("MONGO_INITDB_ROOT_PASSWORD");
const dbName = process.env.MONGO_DATABASE || "documents";
const appUser = process.env.MONGO_APP_USER;
const appPass = envOrFile("MONGO_APP_PASSWORD");
const workerUser = process.env.MONGO_WORKER_USER;
const workerPass = envOrFile("MONGO_WORKER_PASSWORD");
const legacyUser = process.env.MONOLITO_MONGO_USER;
const legacyPass = process.env.MONOLITO_MONGO_PASSWORD;
const legacyDbName = process.env.MONOLITO_MONGO_DB || "pdf-extractext";

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

// worker (ADR-0006): SOLO `update` sobre la coleccion documents.
// Rol a medida: sin find (el worker solo hace updateOne y un ping a admin),
// sin insert, sin delete, sin drop, sin admin.
const updaterPrivileges = [{
  resource: { db: dbName, collection: "documents" },
  actions: ["update"],
}];
// Firma estable de los privilegios para detectar y corregir derivas (igual
// que upsertUser corrige roles): createRole no actualiza un rol existente.
function roleSignature(privileges) {
  return JSON.stringify((privileges || []).map(function (p) {
    var r = p.resource || {};
    return {
      db: r.db,
      collection: r.collection,
      cluster: r.cluster,
      anyResource: r.anyResource,
      actions: (p.actions || []).slice().sort(),
    };
  }).sort(function (a, b) {
    return JSON.stringify(a).localeCompare(JSON.stringify(b));
  }));
}
const documentsUpdater = appDb.getRole("documentsUpdater", { showPrivileges: true });
if (!documentsUpdater) {
  appDb.createRole({ role: "documentsUpdater", privileges: updaterPrivileges, roles: [] });
  print("Rol documentsUpdater creado (solo update).");
} else if (roleSignature(documentsUpdater.privileges) !== roleSignature(updaterPrivileges)) {
  appDb.updateRole("documentsUpdater", { privileges: updaterPrivileges });
  print("Rol documentsUpdater actualizado (privilegios corregidos a solo update).");
} else {
  print("Rol documentsUpdater ya correcto (solo update).");
}
upsertUser(appDb, workerUser, workerPass, [{ role: "documentsUpdater", db: dbName }]);

// Monolito legacy (Strangler): su cadena de conexion fija authSource=admin, asi
// que el usuario debe existir en `admin` y tener permisos sobre su propia base.
if (legacyUser && legacyPass) {
  upsertUser(admin, legacyUser, legacyPass, [{ role: "readWrite", db: legacyDbName }]);
}

print("Inicializacion de Mongo completada.");
