import { useEffect, useState } from 'react';

const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8080';

type Tenant = {
  id: string;
  name: string;
  cpuQuota: number;
  memoryQuotaMb: number;
  dbConnections: number;
  isThrottled: boolean;
};

export default function HomePage() {
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      try {
        const res = await fetch(`${API_URL}/api/v1/tenants`);
        const data = await res.json();
        setTenants(data.tenants || []);
      } catch (err) {
        console.error(err);
      } finally {
        setLoading(false);
      }
    }

    load();
  }, []);

  return (
    <main style={{ padding: '2rem', fontFamily: 'Arial, sans-serif', background: '#0b1020', color: '#e5eefb', minHeight: '100vh' }}>
      <h1>TenantGuard</h1>
      <p>Multi-tenant isolation and noisy-neighbor defense</p>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: '1rem', marginTop: '2rem' }}>
        {loading ? (
          <p>Loading tenants...</p>
        ) : (
          tenants.map((tenant) => (
            <div key={tenant.id} style={{ background: '#121b2d', border: '1px solid #29456d', borderRadius: '12px', padding: '1rem' }}>
              <h3>{tenant.name}</h3>
              <p>CPU quota: {tenant.cpuQuota}</p>
              <p>Memory quota: {tenant.memoryQuotaMb} MB</p>
              <p>DB connections: {tenant.dbConnections}</p>
              <p>Status: {tenant.isThrottled ? 'Throttled' : 'Healthy'}</p>
            </div>
          ))
        )}
      </div>
    </main>
  );
}
