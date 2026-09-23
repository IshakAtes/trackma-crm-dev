const requiredPublicEnvironment = {
  url: process.env.NEXT_PUBLIC_SUPABASE_URL,
  publishableKey: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
};

export function getSupabaseEnvironment() {
  if (!requiredPublicEnvironment.url) {
    throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL");
  }

  if (!requiredPublicEnvironment.publishableKey) {
    throw new Error("Missing NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY");
  }

  return {
    url: requiredPublicEnvironment.url,
    publishableKey: requiredPublicEnvironment.publishableKey,
  };
}
