const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

if (!url || !publishableKey) {
  console.error("Missing Supabase environment variables. Copy .env.example to .env.local and fill in the values.");
  process.exit(1);
}

const response = await fetch(`${url}/auth/v1/settings`, {
  headers: {
    apikey: publishableKey,
    Authorization: `Bearer ${publishableKey}`,
  },
});

if (!response.ok) {
  const detail = await response.text();
  console.error(`Supabase connection failed with HTTP ${response.status}: ${detail}`);
  process.exit(1);
}

console.log("Supabase connection verified: the project API accepted the configured publishable key.");
