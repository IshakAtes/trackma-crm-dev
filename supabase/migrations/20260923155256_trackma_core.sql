-- Trackma Core: forward-only generalization of Database Phase 1.
-- Legacy energy columns remain in place until a later validated cleanup migration.

alter table public.organizations
  add column slug text,
  add column industry text,
  add column status text not null default 'active',
  add column logo_path text,
  add column branding jsonb not null default '{}'::jsonb,
  add column settings jsonb not null default '{}'::jsonb;

update public.organizations
set slug = concat(
  coalesce(
    nullif(trim(both '-' from regexp_replace(lower(name), '[^a-z0-9]+', '-', 'g')), ''),
    'organization'
  ),
  '-',
  id::text
);

alter table public.organizations
  alter column slug set not null,
  add constraint organizations_slug_key unique (slug),
  add constraint organizations_slug_not_blank check (btrim(slug) <> ''),
  add constraint organizations_industry_not_blank check (industry is null or btrim(industry) <> ''),
  add constraint organizations_status_not_blank check (btrim(status) <> ''),
  add constraint organizations_logo_path_not_blank check (logo_path is null or btrim(logo_path) <> ''),
  add constraint organizations_branding_object_check check (jsonb_typeof(branding) = 'object'),
  add constraint organizations_settings_object_check check (jsonb_typeof(settings) = 'object');

create function private.set_organization_slug()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.slug is null or btrim(new.slug) = '' then
    new.slug := concat(
      coalesce(
        nullif(trim(both '-' from regexp_replace(lower(new.name), '[^a-z0-9]+', '-', 'g')), ''),
        'organization'
      ),
      '-',
      new.id::text
    );
  end if;
  return new;
end;
$$;

create trigger organizations_set_slug
before insert or update on public.organizations
for each row execute function private.set_organization_slug();

alter table public.customers
  add column customer_kind text not null default 'individual',
  add column display_name text,
  add column company_name text,
  alter column first_name drop not null,
  alter column last_name drop not null;

update public.customers
set display_name = btrim(concat_ws(' ', first_name, last_name));

create function private.set_customer_display_name()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.display_name is null or btrim(new.display_name) = '' then
    if new.customer_kind = 'company' then
      new.display_name := nullif(btrim(new.company_name), '');
    else
      new.display_name := nullif(btrim(concat_ws(' ', new.first_name, new.last_name)), '');
    end if;
  end if;
  return new;
end;
$$;

create trigger customers_set_display_name
before insert or update on public.customers
for each row execute function private.set_customer_display_name();

alter table public.customers
  add constraint customers_kind_check check (customer_kind in ('individual', 'company')),
  add constraint customers_display_name_check check (
    display_name is not null and btrim(display_name) <> ''
  ),
  add constraint customers_company_name_not_blank check (
    company_name is null or btrim(company_name) <> ''
  ),
  add constraint customers_kind_data_check check (
    (
      customer_kind = 'individual'
      and first_name is not null and btrim(first_name) <> ''
      and last_name is not null and btrim(last_name) <> ''
    )
    or (
      customer_kind = 'company'
      and (
        (company_name is not null and btrim(company_name) <> '')
        or (display_name is not null and btrim(display_name) <> '')
      )
    )
  );

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null,
  first_name text not null check (btrim(first_name) <> ''),
  last_name text not null check (btrim(last_name) <> ''),
  job_title text check (job_title is null or btrim(job_title) <> ''),
  email text check (email is null or btrim(email) <> ''),
  phone text check (phone is null or btrim(phone) <> ''),
  mobile text check (mobile is null or btrim(mobile) <> ''),
  is_primary boolean not null default false,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint contacts_organization_id_id_key unique (organization_id, id),
  constraint contacts_customer_fk
    foreign key (organization_id, customer_id)
    references public.customers (organization_id, id)
    on delete cascade,
  constraint contacts_created_by_membership_fk
    foreign key (organization_id, created_by)
    references public.organization_members (organization_id, user_id)
    on delete no action deferrable initially deferred
);

create unique index contacts_one_primary_per_customer_idx
  on public.contacts (organization_id, customer_id)
  where is_primary;
create index contacts_customer_idx
  on public.contacts (organization_id, customer_id);
create index contacts_created_by_idx
  on public.contacts (organization_id, created_by);

create table public.contract_types (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  key text not null check (btrim(key) <> ''),
  name text not null check (btrim(name) <> ''),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint contract_types_organization_id_id_key unique (organization_id, id),
  constraint contract_types_organization_key_key unique (organization_id, key)
);

insert into public.contract_types (organization_id, key, name)
select distinct
  organization_id,
  contract_type,
  case contract_type
    when 'electricity' then 'Electricity'
    when 'gas' then 'Gas'
    else initcap(replace(contract_type, '_', ' '))
  end
from public.contracts
where contract_type is not null
  and btrim(contract_type) <> ''
on conflict (organization_id, key) do nothing;

alter table public.contracts
  drop constraint if exists contracts_contract_type_check,
  alter column contract_type drop not null,
  add column contract_type_id uuid,
  add column title text,
  add column reference_number text,
  add column counterparty_name text,
  add column signed_at date,
  add column starts_on date,
  add column ends_on date,
  add constraint contracts_organization_id_id_key unique (organization_id, id),
  add constraint contracts_contract_type_fk
    foreign key (organization_id, contract_type_id)
    references public.contract_types (organization_id, id)
    on delete restrict;

update public.contracts as contract
set contract_type_id = contract_type.id
from public.contract_types as contract_type
where contract_type.organization_id = contract.organization_id
  and contract_type.key = contract.contract_type;

update public.contracts
set reference_number = customer_number,
    counterparty_name = provider,
    signed_at = contract_signed_at,
    starts_on = supply_start,
    ends_on = supply_end;

-- Phase 1 defines tenant membership foreign keys as initially deferred. Flush
-- their pending trigger events after the backfill before altering this table.
set constraints all immediate;

alter table public.contracts
  add constraint contracts_type_present_check check (
    contract_type_id is not null
    or (contract_type is not null and btrim(contract_type) <> '')
  ),
  add constraint contracts_title_not_blank check (title is null or btrim(title) <> ''),
  add constraint contracts_reference_number_not_blank check (
    reference_number is null or btrim(reference_number) <> ''
  ),
  add constraint contracts_counterparty_name_not_blank check (
    counterparty_name is null or btrim(counterparty_name) <> ''
  ),
  add constraint contracts_generic_dates_check check (
    ends_on is null or starts_on is null or ends_on >= starts_on
  );

create index contracts_contract_type_idx
  on public.contracts (organization_id, contract_type_id)
  where contract_type_id is not null;

create function private.sync_contract_legacy_fields()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.contract_type_id is null and new.contract_type is not null then
    select type.id
    into new.contract_type_id
    from public.contract_types as type
    where type.organization_id = new.organization_id
      and type.key = new.contract_type;
  end if;

  new.reference_number := coalesce(new.reference_number, new.customer_number);
  new.counterparty_name := coalesce(new.counterparty_name, new.provider);
  new.signed_at := coalesce(new.signed_at, new.contract_signed_at);
  new.starts_on := coalesce(new.starts_on, new.supply_start);
  new.ends_on := coalesce(new.ends_on, new.supply_end);
  return new;
end;
$$;

create trigger contracts_sync_legacy_fields
before insert or update on public.contracts
for each row execute function private.sync_contract_legacy_fields();

create table public.custom_field_definitions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type text not null check (entity_type in ('customer', 'contract')),
  contract_type_id uuid,
  key text not null check (btrim(key) <> ''),
  label text not null check (btrim(label) <> ''),
  data_type text not null check (data_type in ('text', 'number', 'boolean', 'date', 'timestamptz')),
  is_required boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 0 check (sort_order >= 0),
  config jsonb not null default '{}'::jsonb check (jsonb_typeof(config) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint custom_field_definitions_contract_scope_check check (
    entity_type = 'contract' or contract_type_id is null
  ),
  constraint custom_field_definitions_contract_type_fk
    foreign key (organization_id, contract_type_id)
    references public.contract_types (organization_id, id)
    on delete cascade,
  constraint custom_field_definitions_organization_entity_id_type_key
    unique (organization_id, entity_type, id, data_type),
  constraint custom_field_definitions_scope_key
    unique nulls not distinct (organization_id, entity_type, contract_type_id, key)
);

create index custom_field_definitions_contract_type_idx
  on public.custom_field_definitions (organization_id, contract_type_id)
  where contract_type_id is not null;

create table public.customer_custom_field_values (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null,
  custom_field_definition_id uuid not null,
  entity_type text generated always as ('customer') stored,
  data_type text not null,
  value_text text,
  value_number numeric,
  value_boolean boolean,
  value_date date,
  value_timestamptz timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_custom_field_values_customer_fk
    foreign key (organization_id, customer_id)
    references public.customers (organization_id, id)
    on delete cascade,
  constraint customer_custom_field_values_definition_fk
    foreign key (organization_id, entity_type, custom_field_definition_id, data_type)
    references public.custom_field_definitions (organization_id, entity_type, id, data_type)
    on delete cascade,
  constraint customer_custom_field_values_created_by_membership_fk
    foreign key (organization_id, created_by)
    references public.organization_members (organization_id, user_id)
    on delete no action deferrable initially deferred,
  constraint customer_custom_field_values_entity_definition_key
    unique (organization_id, customer_id, custom_field_definition_id),
  constraint customer_custom_field_values_typed_value_check check (
    (data_type = 'text' and value_text is not null and num_nonnulls(value_number, value_boolean, value_date, value_timestamptz) = 0)
    or (data_type = 'number' and value_number is not null and num_nonnulls(value_text, value_boolean, value_date, value_timestamptz) = 0)
    or (data_type = 'boolean' and value_boolean is not null and num_nonnulls(value_text, value_number, value_date, value_timestamptz) = 0)
    or (data_type = 'date' and value_date is not null and num_nonnulls(value_text, value_number, value_boolean, value_timestamptz) = 0)
    or (data_type = 'timestamptz' and value_timestamptz is not null and num_nonnulls(value_text, value_number, value_boolean, value_date) = 0)
  )
);

create table public.contract_custom_field_values (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  contract_id uuid not null,
  custom_field_definition_id uuid not null,
  entity_type text generated always as ('contract') stored,
  data_type text not null,
  value_text text,
  value_number numeric,
  value_boolean boolean,
  value_date date,
  value_timestamptz timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint contract_custom_field_values_contract_fk
    foreign key (organization_id, contract_id)
    references public.contracts (organization_id, id)
    on delete cascade,
  constraint contract_custom_field_values_definition_fk
    foreign key (organization_id, entity_type, custom_field_definition_id, data_type)
    references public.custom_field_definitions (organization_id, entity_type, id, data_type)
    on delete cascade,
  constraint contract_custom_field_values_created_by_membership_fk
    foreign key (organization_id, created_by)
    references public.organization_members (organization_id, user_id)
    on delete no action deferrable initially deferred,
  constraint contract_custom_field_values_entity_definition_key
    unique (organization_id, contract_id, custom_field_definition_id),
  constraint contract_custom_field_values_typed_value_check check (
    (data_type = 'text' and value_text is not null and num_nonnulls(value_number, value_boolean, value_date, value_timestamptz) = 0)
    or (data_type = 'number' and value_number is not null and num_nonnulls(value_text, value_boolean, value_date, value_timestamptz) = 0)
    or (data_type = 'boolean' and value_boolean is not null and num_nonnulls(value_text, value_number, value_date, value_timestamptz) = 0)
    or (data_type = 'date' and value_date is not null and num_nonnulls(value_text, value_number, value_boolean, value_timestamptz) = 0)
    or (data_type = 'timestamptz' and value_timestamptz is not null and num_nonnulls(value_text, value_number, value_boolean, value_date) = 0)
  )
);

create index customer_custom_field_values_customer_idx
  on public.customer_custom_field_values (organization_id, customer_id);
create index customer_custom_field_values_definition_idx
  on public.customer_custom_field_values (organization_id, custom_field_definition_id);
create index customer_custom_field_values_created_by_idx
  on public.customer_custom_field_values (organization_id, created_by);
create index contract_custom_field_values_contract_idx
  on public.contract_custom_field_values (organization_id, contract_id);
create index contract_custom_field_values_definition_idx
  on public.contract_custom_field_values (organization_id, custom_field_definition_id);
create index contract_custom_field_values_created_by_idx
  on public.contract_custom_field_values (organization_id, created_by);

-- Create generic definitions for legacy energy attributes and copy populated values.
insert into public.custom_field_definitions (
  organization_id, entity_type, key, label, data_type, sort_order
)
select organization_id, 'contract', field.key, field.label, field.data_type, field.sort_order
from (select distinct organization_id from public.contracts) as organization
cross join (values
  ('closing_platform', 'Closing platform', 'text', 10),
  ('meter_number', 'Meter number', 'text', 20),
  ('market_location_id', 'Market location ID', 'text', 30),
  ('annual_consumption', 'Annual consumption', 'number', 40)
) as field(key, label, data_type, sort_order)
on conflict (organization_id, entity_type, contract_type_id, key) do nothing;

insert into public.contract_custom_field_values (
  organization_id, contract_id, custom_field_definition_id, data_type, value_text, created_by
)
select contract.organization_id, contract.id, definition.id, definition.data_type,
       contract.closing_platform, contract.created_by
from public.contracts as contract
join public.custom_field_definitions as definition
  on definition.organization_id = contract.organization_id
 and definition.entity_type = 'contract'
 and definition.contract_type_id is null
 and definition.key = 'closing_platform'
where contract.closing_platform is not null;

insert into public.contract_custom_field_values (
  organization_id, contract_id, custom_field_definition_id, data_type, value_text, created_by
)
select contract.organization_id, contract.id, definition.id, definition.data_type,
       contract.meter_number, contract.created_by
from public.contracts as contract
join public.custom_field_definitions as definition
  on definition.organization_id = contract.organization_id
 and definition.entity_type = 'contract'
 and definition.contract_type_id is null
 and definition.key = 'meter_number'
where contract.meter_number is not null;

insert into public.contract_custom_field_values (
  organization_id, contract_id, custom_field_definition_id, data_type, value_text, created_by
)
select contract.organization_id, contract.id, definition.id, definition.data_type,
       contract.market_location_id, contract.created_by
from public.contracts as contract
join public.custom_field_definitions as definition
  on definition.organization_id = contract.organization_id
 and definition.entity_type = 'contract'
 and definition.contract_type_id is null
 and definition.key = 'market_location_id'
where contract.market_location_id is not null;

insert into public.contract_custom_field_values (
  organization_id, contract_id, custom_field_definition_id, data_type, value_number, created_by
)
select contract.organization_id, contract.id, definition.id, definition.data_type,
       contract.annual_consumption, contract.created_by
from public.contracts as contract
join public.custom_field_definitions as definition
  on definition.organization_id = contract.organization_id
 and definition.entity_type = 'contract'
 and definition.contract_type_id is null
 and definition.key = 'annual_consumption'
where contract.annual_consumption is not null;

create function private.prevent_id_organization_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id then
    raise exception 'id is immutable' using errcode = '23514';
  end if;
  if new.organization_id is distinct from old.organization_id then
    raise exception 'organization_id is immutable' using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke execute on function private.set_organization_slug() from public, anon, authenticated;
revoke execute on function private.set_customer_display_name() from public, anon, authenticated;
revoke execute on function private.sync_contract_legacy_fields() from public, anon, authenticated;
revoke execute on function private.prevent_id_organization_change() from public, anon, authenticated;

create trigger contacts_set_updated_at before update on public.contacts
for each row execute function private.set_updated_at();
create trigger contract_types_set_updated_at before update on public.contract_types
for each row execute function private.set_updated_at();
create trigger custom_field_definitions_set_updated_at before update on public.custom_field_definitions
for each row execute function private.set_updated_at();
create trigger customer_custom_field_values_set_updated_at before update on public.customer_custom_field_values
for each row execute function private.set_updated_at();
create trigger contract_custom_field_values_set_updated_at before update on public.contract_custom_field_values
for each row execute function private.set_updated_at();

create trigger contacts_tenant_attribution_immutable before update on public.contacts
for each row execute function private.prevent_tenant_attribution_change();
create trigger contract_types_tenant_immutable before update on public.contract_types
for each row execute function private.prevent_id_organization_change();
create trigger custom_field_definitions_tenant_immutable before update on public.custom_field_definitions
for each row execute function private.prevent_id_organization_change();
create trigger customer_custom_field_values_tenant_attribution_immutable before update on public.customer_custom_field_values
for each row execute function private.prevent_tenant_attribution_change();
create trigger contract_custom_field_values_tenant_attribution_immutable before update on public.contract_custom_field_values
for each row execute function private.prevent_tenant_attribution_change();

alter table public.contacts enable row level security;
alter table public.contract_types enable row level security;
alter table public.custom_field_definitions enable row level security;
alter table public.customer_custom_field_values enable row level security;
alter table public.contract_custom_field_values enable row level security;

revoke all on table public.contacts from anon, authenticated;
revoke all on table public.contract_types from anon, authenticated;
revoke all on table public.custom_field_definitions from anon, authenticated;
revoke all on table public.customer_custom_field_values from anon, authenticated;
revoke all on table public.contract_custom_field_values from anon, authenticated;

grant select, insert, update, delete on table public.contacts to authenticated;
grant select on table public.contract_types to authenticated;
grant select on table public.custom_field_definitions to authenticated;
grant select, insert, update, delete on table public.customer_custom_field_values to authenticated;
grant select, insert, update, delete on table public.contract_custom_field_values to authenticated;

create policy contacts_select_for_accessible_customer
on public.contacts for select to authenticated
using ((select private.can_access_customer(organization_id, customer_id)));
create policy contacts_insert_for_accessible_customer
on public.contacts for insert to authenticated
with check (
  created_by = (select auth.uid())
  and (select private.can_access_customer(organization_id, customer_id))
);
create policy contacts_update_for_accessible_customer
on public.contacts for update to authenticated
using ((select private.can_access_customer(organization_id, customer_id)))
with check ((select private.can_access_customer(organization_id, customer_id)));
create policy contacts_delete_for_accessible_customer
on public.contacts for delete to authenticated
using ((select private.can_access_customer(organization_id, customer_id)));

create policy contract_types_select_active_member
on public.contract_types for select to authenticated
using ((select private.is_active_member(organization_id)));

create policy custom_field_definitions_select_active_member
on public.custom_field_definitions for select to authenticated
using ((select private.is_active_member(organization_id)));

create policy customer_custom_field_values_select_for_accessible_customer
on public.customer_custom_field_values for select to authenticated
using ((select private.can_access_customer(organization_id, customer_id)));
create policy customer_custom_field_values_insert_for_accessible_customer
on public.customer_custom_field_values for insert to authenticated
with check (
  created_by = (select auth.uid())
  and (select private.can_access_customer(organization_id, customer_id))
);
create policy customer_custom_field_values_update_for_accessible_customer
on public.customer_custom_field_values for update to authenticated
using ((select private.can_access_customer(organization_id, customer_id)))
with check ((select private.can_access_customer(organization_id, customer_id)));
create policy customer_custom_field_values_delete_for_accessible_customer
on public.customer_custom_field_values for delete to authenticated
using ((select private.can_access_customer(organization_id, customer_id)));

create policy contract_custom_field_values_select_for_accessible_contract
on public.contract_custom_field_values for select to authenticated
using (
  exists (
    select 1
    from public.contracts as contract
    where contract.organization_id = contract_custom_field_values.organization_id
      and contract.id = contract_custom_field_values.contract_id
      and (select private.can_access_customer(contract.organization_id, contract.customer_id))
  )
);
create policy contract_custom_field_values_insert_for_accessible_contract
on public.contract_custom_field_values for insert to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1
    from public.contracts as contract
    where contract.organization_id = contract_custom_field_values.organization_id
      and contract.id = contract_custom_field_values.contract_id
      and (select private.can_access_customer(contract.organization_id, contract.customer_id))
  )
);
create policy contract_custom_field_values_update_for_accessible_contract
on public.contract_custom_field_values for update to authenticated
using (
  exists (
    select 1
    from public.contracts as contract
    where contract.organization_id = contract_custom_field_values.organization_id
      and contract.id = contract_custom_field_values.contract_id
      and (select private.can_access_customer(contract.organization_id, contract.customer_id))
  )
)
with check (
  exists (
    select 1
    from public.contracts as contract
    where contract.organization_id = contract_custom_field_values.organization_id
      and contract.id = contract_custom_field_values.contract_id
      and (select private.can_access_customer(contract.organization_id, contract.customer_id))
  )
);
create policy contract_custom_field_values_delete_for_accessible_contract
on public.contract_custom_field_values for delete to authenticated
using (
  exists (
    select 1
    from public.contracts as contract
    where contract.organization_id = contract_custom_field_values.organization_id
      and contract.id = contract_custom_field_values.contract_id
      and (select private.can_access_customer(contract.organization_id, contract.customer_id))
  )
);
