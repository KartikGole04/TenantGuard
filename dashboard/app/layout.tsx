import './globals.css';

export const metadata = {
  title: 'TenantGuard Dashboard',
  description: 'Multi-tenant isolation and noisy-neighbor defense',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
