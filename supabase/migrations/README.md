# Database migrations

This directory intentionally contains no schema migration yet.

Create each future migration with:

```sh
npm run supabase:migration:new -- descriptive_name
```

Review every migration before applying it. Enable Row Level Security and add explicit policies for every table exposed through the Data API.
