# Database V1

## Final tables

Tenant/identity: `organizations`, `profiles`, `organization_members`.

CRM: `customers`, `contacts`, `contracts`, `contract_types`, `follow_ups`, `notes`,
`referrals`, `custom_field_definitions`, `customer_custom_field_values`,
`contract_custom_field_values`.

Templates: `industries`, `industry_templates`, `template_contract_types`,
`template_custom_fields`, `organization_templates`.

All 18 public tables enable RLS. Anonymous users have no application table or RPC
access. Tenant relationships use composite foreign keys. Authorization reads current
active memberships, never user-editable JWT metadata. Deactivation takes effect on
the next request even with an unexpired JWT. Profiles are visible to their user and
active members sharing an organization; only the user edits their own profile.

## Roles

| Operation | Owner | Admin | Team Lead / Agent |
| --- | --- | --- | --- |
| Read/edit CRM data | Entire organization | Entire organization | Own active customers and related data |
| Add/change/deactivate/reactivate memberships | Yes | No | No |
| Reassign customers | Active same-org target | Active same-org target | No |
| Soft-delete accessible customer | Yes | Yes | Yes |
| Read/restore deleted customers | Yes | Yes | No |
| Permanently delete customers | Yes | Yes | No |
| Types / field definitions / apply template | Yes | Yes | No |
| Organization settings | Yes | No | No |

Team Lead retains the existing own-customer scope; V1 does not introduce teams or a
team hierarchy. Active members can discover same-organization members/profiles.
Membership identity is immutable. There is at most one Owner per organization,
always active. Normal client operations cannot add, remove, demote or transfer that
Owner. Initial organization/Owner provisioning and creation of Auth accounts need a
trusted server/admin flow. Member addition references an existing Auth user; an
invitation UI is outside this database implementation. Deactivate memberships rather
than deleting them to preserve historical attribution.

## Customer lifecycle API

Use the authenticated user's JWT and ordinary publishable key:

```ts
await supabase.rpc('delete_customer', { target_customer: customerId });
await supabase.rpc('restore_customer', { target_customer: customerId });
await supabase.rpc('restore_customer', {
  target_customer: customerId,
  new_owner: activeOrganizationUserId,
});
// Owner/Admin: reassign without changing deletion state.
await supabase.from('customers').update({ owner_id: activeOrganizationUserId })
  .eq('id', customerId);
// Owner/Admin: permanent deletion with dependent-row cascades.
await supabase.from('customers').delete().eq('id', customerId);
```

`delete_customer` records `deleted_at` and `deleted_by`, leaving ownership and all
dependent rows intact. Direct writes to deletion metadata are revoked. RLS hides the
customer, contacts, contracts, follow-ups, notes, referrals and custom-field values
from Agents/Team Leads, including direct API queries. Referrals require access to
both endpoints. Owner/Admin retain organization-wide access. An authorized repeated
soft-delete preserves the original deletion metadata.

Restore without `new_owner` retains the previous owner, including an inactive former
member; that member still has no access. Any ownership change requires an active
same-organization member. Owner/Admin may choose themselves. Restore/reassign locks
the customer and runs atomically; failure cannot partially restore it. Owner/Admin
can also reassign a deleted customer without restoring it. Every actual ownership
change uses the same follow-up behavior.

Only follow-ups assigned to the previous customer owner with status `not_started`,
`in_progress` or `waiting_for_customer` move to the new owner. `completed` and the
existing terminal `declined` status remain historical. Open follow-ups deliberately
assigned to others remain unchanged. Soft deletion does not change ownership and
therefore does not trigger reassignment. Multi-row updates support bulk reassignment,
including from deactivated members. Employee deactivation never deletes customers.

## Generic contracts and templates

`contracts` requires a same-organization `contract_type_id`. Generic fields include
title, reference number, counterparty name, signed/start/end dates and status. No
Energy columns or legacy synchronization trigger remain in the final contract core.

Versioned template catalogs are deployment data, read-only to clients. Applying a
template copies types/definitions into tenant-owned configuration and records the
actor/time. Catalog changes never silently rewrite installed tenant configuration.
`organizations.industry_key` references the industry catalog.

```ts
await supabase.rpc('apply_template', {
  target_org: organizationId,
  target_template: 'e0000000-0000-0000-0000-000000000001',
});
```

Energy V1 installs electricity and gas types. Each has typed fields for closing
platform, meter number, market location ID and annual consumption (kWh, minimum zero).
These fields are optional until an organization makes them required. Catalog data
ships in migrations, not local seed data; no demo users or customer PII are seeded.
Reapplying an installed template is a no-op. Conflicting tenant keys fail atomically
instead of overwriting configuration. Automatic upgrades between template versions
with overlapping keys are outside V1 and require deliberate migration logic.

## Custom-field integrity

- Exactly one typed column: text, number, boolean, date or timestamptz.
- Composite FKs enforce tenant, entity kind and definition data type.
- One value per entity/definition. Scoped contract fields must match contract type;
  changing that type cannot strand populated fields.
- Definition scope, data type and validation config are immutable. Create a new
  definition to change them. Used definitions cannot be deleted; deactivate instead.
  Existing values remain readable. Writes to inactive definitions/types are rejected.
- Numbers must be finite and respect optional `min`/`max`. Malformed/inverted bounds
  fail validation. Required text cannot be blank.
- Active required definitions must have values for every applicable entity. Deferred
  constraints check final transaction state after entity changes, value deletion or
  movement, and definition requirement/activation changes. Future entity-save APIs
  must save the entity and required values in one transaction (e.g. a dedicated RPC);
  independent REST requests are not atomic.

Privileged operations live in unexposed `private`, use fixed empty search paths and
explicit caller checks. Public RPCs are SECURITY INVOKER wrappers. Trigger functions
cannot be executed directly by API roles. Ordinary related-data CRUD uses RLS.

## Verification

With Docker running, from the repository root:

```sh
npx supabase db reset --local --yes
npx supabase test db --local
npx supabase db lint --local --schema public,private --fail-on warning
npx supabase db advisors --local --type all --level warn --fail-on warn
npm run lint
npm run build
```

Four pgTAP suites cover tenant isolation, roles, lifecycle, bulk reassignment,
dependent-data retention, templates, generic contracts and field integrity. Fixtures
roll back. Informational unused-index findings are expected on an empty database;
FK covering indexes are included. No remote changes, commits or pushes are needed.
Full customer audit/version history and backup configuration remain outside V1.

Validated locally on 2026-09-23 using Supabase CLI 2.117.0 and PostgreSQL 17:
clean reset and all three migrations passed; 203 pgTAP tests across four suites
passed (40 custom-field, 26 original isolation, 97 lifecycle/roles, 40 generic-core).
Database lint found no errors; advisors found no warnings/errors or unindexed FKs,
only 16 informational unused-index notices on the empty local database. npm lint
and production build passed. Git diff checks passed and a repository secret-pattern
scan found no matches. Remote Supabase was untouched; nothing was committed/pushed.
