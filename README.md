# Trackma

A secure, multi-tenant foundation for customer and contract management. The local
database schema provides role-based tenant isolation, generic contract types, contacts,
follow-ups, referrals, notes, typed custom fields, and a versioned Energy template.

See [Database V1](supabase/DATABASE_V1.md) for permissions, lifecycle operations,
template installation, integrity rules, and local validation commands.

## Prerequisites

- Node.js 22 or newer
- npm
- Docker-compatible runtime (only for the local Supabase stack)

## Setup

```sh
npm install
copy .env.example .env.local
npm run dev
```

Set these values in `.env.local`:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`

The publishable key is designed for browser use and is constrained by database privileges and Row Level Security. Never add a Supabase secret key or legacy `service_role` key to a `NEXT_PUBLIC_` variable.

## Verification

```sh
npm run lint
npm run build
npm run verify:supabase
```

`verify:supabase` calls the configured project's Auth settings endpoint with the publishable key. It does not create or query application tables.

## Database workflow

The Supabase CLI is pinned as a project dependency and `supabase/config.toml` is committed. Database changes are captured as forward-only files in `supabase/migrations`.

```sh
npm run supabase:start
npm run supabase:migration:new -- descriptive_name
npm run supabase:reset
```

The local stack requires Docker. Before deploying migrations to a remote project, authenticate and link the CLI explicitly:

```sh
npx supabase login
npx supabase link --project-ref your-project-ref
```

Do not run destructive reset commands against a production project.
