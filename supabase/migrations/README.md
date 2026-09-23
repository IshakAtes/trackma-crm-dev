# Trackma database migrations

The complete first-deployment chain preserves the existing local work:

1. `20260923135846_database_phase_1.sql`: tenant foundation and initial CRM tables.
2. `20260923155256_trackma_core.sql`: general customers, contacts and typed fields.
3. `20260923190947_database_v1.sql`: final generic contracts, role permissions,
   membership management, soft deletion, reassignment, field integrity and templates.

Apply all three. The intermediate Energy compatibility model is not the final schema.
Tests in `../tests/database` exercise the complete chain. See `../DATABASE_V1.md`.

Create each future migration with:

```sh
npm run supabase:migration:new -- descriptive_name
```

Review every migration before applying it. Enable Row Level Security and add explicit policies for every table exposed through the Data API.
