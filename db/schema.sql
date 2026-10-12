CREATE TABLE IF NOT EXISTS tenants (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    cpu_quota DOUBLE PRECISION NOT NULL DEFAULT 0.6,
    memory_quota_mb INTEGER NOT NULL DEFAULT 512,
    db_connections INTEGER NOT NULL DEFAULT 3,
    is_throttled BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS workloads (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    cost DOUBLE PRECISION NOT NULL,
    duration_sec INTEGER NOT NULL,
    started_at TIMESTAMP NOT NULL DEFAULT NOW(),
    status TEXT NOT NULL DEFAULT 'queued',
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE TABLE IF NOT EXISTS incidents (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    severity TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    resolved BOOLEAN NOT NULL DEFAULT FALSE,
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

INSERT INTO tenants (id, name, cpu_quota, memory_quota_mb, db_connections, is_throttled)
VALUES
    ('tenant-a', 'Tenant A', 0.6, 512, 3, false),
    ('tenant-b', 'Tenant B', 0.6, 512, 3, false),
    ('tenant-c', 'Tenant C', 0.5, 512, 2, false)
ON CONFLICT (id) DO NOTHING;
