-- Database V1 completes the existing local chain. No legacy Energy API remains.
drop trigger contracts_sync_legacy_fields on public.contracts;
drop function private.sync_contract_legacy_fields();
alter table public.contracts
  drop constraint contracts_type_present_check,
  alter column contract_type_id set not null,
  drop column contract_type,
  drop column provider,
  drop column closing_platform,
  drop column customer_number,
  drop column meter_number,
  drop column market_location_id,
  drop column annual_consumption,
  drop column contract_signed_at,
  drop column supply_start,
  drop column supply_end;

alter table public.customers
  add column deleted_at timestamptz,
  add column deleted_by uuid,
  add constraint customers_deletion_pair check ((deleted_at is null) = (deleted_by is null)),
  add constraint customers_deleted_by_fk foreign key (organization_id, deleted_by)
    references public.organization_members (organization_id, user_id);
create index customers_deleted_idx on public.customers (organization_id, deleted_at) where deleted_at is not null;
create unique index organization_members_one_owner on public.organization_members (organization_id) where role = 'owner';
alter table public.organization_members add constraint owner_always_active check (role <> 'owner' or is_active);

create function private.org_role(target_org uuid) returns text
language sql stable security definer set search_path = '' as $$
  select role from public.organization_members
  where organization_id = target_org and user_id = (select auth.uid()) and is_active;
$$;
create function private.is_org_admin(target_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.org_role(target_org) in ('owner', 'admin'), false);
$$;
create or replace function private.can_access_customer(target_organization_id uuid, target_customer_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.customers c
    join public.organization_members m on m.organization_id = c.organization_id
      and m.user_id = (select auth.uid()) and m.is_active
    where c.organization_id = target_organization_id and c.id = target_customer_id
      and (m.role in ('owner', 'admin') or (c.owner_id = m.user_id and c.deleted_at is null))
  );
$$;

-- Only the Owner manages existing Auth users' memberships. Auth account invitation
-- belongs to a future trusted server flow, not to a client service-role key.
grant insert, update on public.organization_members to authenticated;
drop policy organization_members_select_own on public.organization_members;
create policy organization_members_read on public.organization_members for select to authenticated
using ((select private.is_active_member(organization_id)));
create policy organization_members_add on public.organization_members for insert to authenticated
with check ((select private.org_role(organization_id)) = 'owner' and role <> 'owner');
create policy organization_members_edit on public.organization_members for update to authenticated
using ((select private.org_role(organization_id)) = 'owner' and role <> 'owner')
with check ((select private.org_role(organization_id)) = 'owner' and role <> 'owner');
create function private.guard_membership() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id
    or new.user_id is distinct from old.user_id then
    raise exception 'Membership identity is immutable' using errcode = '23514';
  end if;
  if new.role is distinct from old.role and (new.role = 'owner' or old.role = 'owner')
    or (old.role = 'owner' and not new.is_active) then
    raise exception 'Ownership transfer is not supported' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger organization_members_guard before update on public.organization_members
for each row execute function private.guard_membership();

create function private.can_read_profile(target_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select target_user = (select auth.uid()) or exists (
    select 1 from public.organization_members mine join public.organization_members theirs
      on theirs.organization_id = mine.organization_id
    where mine.user_id = (select auth.uid()) and mine.is_active and theirs.user_id = target_user
  );
$$;
alter policy profiles_select_own on public.profiles using ((select private.can_read_profile(id)));
grant update on public.organizations to authenticated;
create policy organizations_edit on public.organizations for update to authenticated
using ((select private.org_role(id)) = 'owner') with check ((select private.org_role(id)) = 'owner');

drop policy customers_select_owned on public.customers;
drop policy customers_insert_self_owned on public.customers;
drop policy customers_update_owned on public.customers;
drop policy customers_delete_owned on public.customers;
create policy customers_read on public.customers for select to authenticated
using ((select private.is_active_member(organization_id)) and
  ((select private.is_org_admin(organization_id)) or (owner_id = (select auth.uid()) and deleted_at is null)));
create policy customers_add on public.customers for insert to authenticated
with check (created_by = (select auth.uid()) and deleted_at is null
  and (select private.is_active_member(organization_id))
  and (owner_id = (select auth.uid()) or (select private.is_org_admin(organization_id))));
create policy customers_edit on public.customers for update to authenticated
using ((select private.can_access_customer(organization_id, id)))
with check ((select private.is_active_member(organization_id)) and
  ((select private.is_org_admin(organization_id)) or (owner_id = (select auth.uid()) and deleted_at is null)));
create policy customers_hard_delete on public.customers for delete to authenticated
using ((select private.is_org_admin(organization_id)));

create function private.guard_customer_assignment() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.owner_id is distinct from old.owner_id then
    -- Share lock serializes assignment against membership deactivation.
    perform 1 from public.organization_members where organization_id = new.organization_id
      and user_id = new.owner_id and is_active for share;
    if not found then
      raise exception 'Customer owner must be an active member of this organization' using errcode = '23514';
    end if;
    if tg_op = 'UPDATE' and auth.uid() is not null and not private.is_org_admin(new.organization_id) then
      raise exception 'Only Owner/Admin may reassign customers' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger customers_guard_assignment before insert or update on public.customers
for each row execute function private.guard_customer_assignment();

-- Deletion metadata is never client-writable. The invoker RPC delegates only
-- this narrow operation to a private function with explicit authorization.
revoke insert, update on public.customers from authenticated;
do $$ declare cols text; begin
  select string_agg(quote_ident(column_name), ', ') into cols from information_schema.columns
    where table_schema = 'public' and table_name = 'customers' and column_name not in ('deleted_at', 'deleted_by');
  execute format('grant insert (%s), update (%s) on public.customers to authenticated', cols, cols);
end $$;
create function private.delete_customer(target_customer uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.customers;
begin
  select * into c from public.customers where id = target_customer for update;
  if not found or auth.uid() is null or not private.can_access_customer(c.organization_id, c.id) then
    raise exception 'Customer unavailable' using errcode = '42501';
  end if;
  if c.deleted_at is null then
    update public.customers set deleted_at = clock_timestamp(), deleted_by = auth.uid() where id = c.id;
  end if;
end;
$$;
create function public.delete_customer(target_customer uuid) returns void
language sql security invoker set search_path = '' as $$ select private.delete_customer(target_customer); $$;
create function private.restore_customer(target_customer uuid, new_owner uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.customers;
begin
  select * into c from public.customers where id = target_customer for update;
  if not found or auth.uid() is null or not private.is_org_admin(c.organization_id) then
    raise exception 'Customer unavailable' using errcode = '42501';
  end if;
  update public.customers set deleted_at = null, deleted_by = null,
    owner_id = coalesce(new_owner, c.owner_id) where id = c.id;
end;
$$;
create function public.restore_customer(target_customer uuid, new_owner uuid default null) returns void
language sql security invoker set search_path = '' as $$ select private.restore_customer(target_customer, new_owner); $$;

create function private.reassign_open_follow_ups() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.owner_id is distinct from old.owner_id then
    update public.follow_ups set assigned_to = new.owner_id
    where organization_id = new.organization_id and customer_id = new.id and assigned_to = old.owner_id
      and status in ('not_started', 'in_progress', 'waiting_for_customer');
  end if;
  return new;
end;
$$;
create trigger customers_reassign_follow_ups after update of owner_id on public.customers
for each row execute function private.reassign_open_follow_ups();
alter policy follow_ups_insert_for_accessible_customer on public.follow_ups
with check (created_by = (select auth.uid()) and (select private.can_access_customer(organization_id, customer_id))
  and (assigned_to = (select auth.uid()) or (select private.is_org_admin(organization_id))));
alter policy follow_ups_update_for_accessible_customer on public.follow_ups
with check ((select private.can_access_customer(organization_id, customer_id)));
create function private.guard_follow_up_assignment() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.assigned_to is distinct from old.assigned_to then
    perform 1 from public.organization_members where organization_id = new.organization_id
      and user_id = new.assigned_to and is_active for share;
    if not found then
      raise exception 'Follow-up assignee must be an active organization member' using errcode = '23514';
    end if;
    if auth.uid() is not null and new.assigned_to <> auth.uid() and not private.is_org_admin(new.organization_id) then
      raise exception 'Only Owner/Admin may assign follow-ups to others' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger follow_ups_guard_assignment before insert or update on public.follow_ups
for each row execute function private.guard_follow_up_assignment();

-- Operational configuration is organization-wide for Owner/Admin.
grant insert, update, delete on public.contract_types, public.custom_field_definitions to authenticated;
create policy contract_types_add on public.contract_types for insert to authenticated
with check ((select private.is_org_admin(organization_id)));
create policy contract_types_edit on public.contract_types for update to authenticated
using ((select private.is_org_admin(organization_id))) with check ((select private.is_org_admin(organization_id)));
create policy contract_types_remove on public.contract_types for delete to authenticated
using ((select private.is_org_admin(organization_id)));
create policy custom_field_definitions_add on public.custom_field_definitions for insert to authenticated
with check ((select private.is_org_admin(organization_id)));
create policy custom_field_definitions_edit on public.custom_field_definitions for update to authenticated
using ((select private.is_org_admin(organization_id))) with check ((select private.is_org_admin(organization_id)));
create policy custom_field_definitions_remove on public.custom_field_definitions for delete to authenticated
using ((select private.is_org_admin(organization_id)));

-- Preserve field values when retiring a definition/type. Delete unused definitions
-- only; deactivate used ones. Scope/type are immutable, so old values cannot drift.
alter table public.custom_field_definitions drop constraint custom_field_definitions_contract_type_fk,
  add constraint custom_field_definitions_contract_type_fk foreign key (organization_id, contract_type_id)
    references public.contract_types (organization_id, id) on delete restrict;
alter table public.customer_custom_field_values drop constraint customer_custom_field_values_definition_fk,
  add constraint customer_custom_field_values_definition_fk foreign key (organization_id, entity_type, custom_field_definition_id, data_type)
    references public.custom_field_definitions (organization_id, entity_type, id, data_type) on delete restrict;
alter table public.contract_custom_field_values drop constraint contract_custom_field_values_definition_fk,
  add constraint contract_custom_field_values_definition_fk foreign key (organization_id, entity_type, custom_field_definition_id, data_type)
    references public.custom_field_definitions (organization_id, entity_type, id, data_type) on delete restrict;
create function private.guard_field_definition() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (new.entity_type, new.contract_type_id, new.data_type, new.config) is distinct from
     (old.entity_type, old.contract_type_id, old.data_type, old.config) then
    raise exception 'Field scope, type and validation config are immutable; create a new definition' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger field_definition_guard before update on public.custom_field_definitions
for each row execute function private.guard_field_definition();

create function private.validate_field_value() returns trigger
language plpgsql security definer set search_path = '' as $$
declare d public.custom_field_definitions; ct uuid;
begin
  select * into d from public.custom_field_definitions
    where organization_id = new.organization_id and id = new.custom_field_definition_id for share;
  if not found then return new; end if; -- Composite FK provides the precise error.
  if not d.is_active then raise exception 'Field definition is inactive' using errcode = '23514'; end if;
  if tg_table_name = 'contract_custom_field_values' then
    select contract_type_id into ct from public.contracts
      where organization_id = new.organization_id and id = new.contract_id for share;
    if d.contract_type_id is not null and d.contract_type_id is distinct from ct then
      raise exception 'Field does not apply to this contract type' using errcode = '23514';
    end if;
  end if;
  if new.value_number in ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
     or (d.config ? 'min' and new.value_number < (d.config->>'min')::numeric)
     or (d.config ? 'max' and new.value_number > (d.config->>'max')::numeric) then
    raise exception 'Number outside field range' using errcode = '23514';
  end if;
  if d.is_required and new.data_type = 'text' and btrim(new.value_text) = '' then
    raise exception 'Required text cannot be blank' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger customer_field_value_validate before insert or update on public.customer_custom_field_values
for each row execute function private.validate_field_value();
create trigger contract_field_value_validate before insert or update on public.contract_custom_field_values
for each row execute function private.validate_field_value();
create function private.guard_contract_type() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.contract_type_id is distinct from old.contract_type_id then
    perform 1 from public.contract_types where organization_id = new.organization_id and id = new.contract_type_id and is_active for share;
    if not found then raise exception 'Active same-organization contract type required' using errcode = '23503'; end if;
    if tg_op = 'UPDATE' and exists (
      select 1 from public.contract_custom_field_values v join public.custom_field_definitions d
        on d.id = v.custom_field_definition_id and d.organization_id = v.organization_id
      where v.contract_id = new.id and d.contract_type_id is not null and d.contract_type_id <> new.contract_type_id
    ) then raise exception 'Existing custom fields conflict with contract type' using errcode = '23514'; end if;
  end if;
  return new;
end;
$$;
create trigger contracts_guard_type before insert or update on public.contracts
for each row execute function private.guard_contract_type();

-- Required values are checked at transaction end so an entity and its values
-- can be saved atomically. Soft deletion does not erase or relax these values.
create function private.check_required_fields(org uuid, entity text, entity_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare ct uuid;
begin
  if entity = 'customer' then
    if not exists (select 1 from public.customers where organization_id = org and id = entity_id) then return; end if;
    if exists (
      select 1 from public.custom_field_definitions d where d.organization_id = org
        and d.entity_type = 'customer' and d.is_active and d.is_required
        and not exists (select 1 from public.customer_custom_field_values v
          where v.organization_id = org and v.customer_id = entity_id and v.custom_field_definition_id = d.id
            and (v.data_type <> 'text' or btrim(v.value_text) <> ''))
    ) then raise exception 'Required customer field missing' using errcode = '23514'; end if;
  else
    select contract_type_id into ct from public.contracts where organization_id = org and id = entity_id;
    if not found then return; end if;
    if exists (
      select 1 from public.custom_field_definitions d where d.organization_id = org
        and d.entity_type = 'contract' and d.is_active and d.is_required
        and (d.contract_type_id is null or d.contract_type_id = ct)
        and not exists (select 1 from public.contract_custom_field_values v
          where v.organization_id = org and v.contract_id = entity_id and v.custom_field_definition_id = d.id
            and (v.data_type <> 'text' or btrim(v.value_text) <> ''))
    ) then raise exception 'Required contract field missing' using errcode = '23514'; end if;
  end if;
end;
$$;
create function private.required_fields_trigger() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r jsonb; org uuid; entity text; entity_id uuid; item record;
begin
  r := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  org := (r->>'organization_id')::uuid;
  if tg_table_name = 'custom_field_definitions' then
    for item in select id from public.customers where organization_id = org loop
      perform private.check_required_fields(org, 'customer', item.id);
    end loop;
    for item in select id from public.contracts where organization_id = org loop
      perform private.check_required_fields(org, 'contract', item.id);
    end loop;
  else
    entity := case when tg_table_name in ('customers', 'customer_custom_field_values') then 'customer' else 'contract' end;
    entity_id := coalesce((r->>(entity || '_id'))::uuid, (r->>'id')::uuid);
    perform private.check_required_fields(org, entity, entity_id);
    if tg_op = 'UPDATE' and tg_table_name in ('customer_custom_field_values', 'contract_custom_field_values') then
      perform private.check_required_fields(org, entity, (to_jsonb(old)->>(entity || '_id'))::uuid);
    end if;
  end if;
  return null;
end;
$$;
do $$ declare t text; begin
  foreach t in array array['customers','contracts','customer_custom_field_values','contract_custom_field_values','custom_field_definitions'] loop
    execute format('create constraint trigger required_fields after insert or update or delete on public.%I deferrable initially deferred for each row execute function private.required_fields_trigger()', t);
  end loop;
end $$;

alter table public.custom_field_definitions add constraint custom_field_config_bounds check (
  (not (config ? 'min') or (data_type = 'number' and jsonb_typeof(config->'min') = 'number'))
  and (not (config ? 'max') or (data_type = 'number' and jsonb_typeof(config->'max') = 'number'))
  and (not (config ? 'min' and config ? 'max') or (config->>'min')::numeric <= (config->>'max')::numeric)
);

-- Template catalogs are versioned deployment data. Applying one copies editable
-- tenant configuration; subsequent catalog changes never rewrite tenant data.
create table public.industries (
  key text primary key check (btrim(key) <> ''), name text not null check (btrim(name) <> '')
);
create table public.industry_templates (
  id uuid primary key default gen_random_uuid(), industry_key text not null references public.industries(key),
  key text not null, name text not null, version integer not null check (version > 0),
  unique (key, version)
);
create table public.template_contract_types (
  template_id uuid not null references public.industry_templates(id) on delete cascade,
  key text not null, name text not null, primary key (template_id, key)
);
create table public.template_custom_fields (
  id uuid primary key default gen_random_uuid(), template_id uuid not null references public.industry_templates(id) on delete cascade,
  entity_type text not null check (entity_type in ('customer','contract')), contract_type_key text,
  key text not null, label text not null,
  data_type text not null check (data_type in ('text','number','boolean','date','timestamptz')),
  is_required boolean not null default false, sort_order integer not null default 0,
  config jsonb not null default '{}' check (jsonb_typeof(config) = 'object'),
  foreign key (template_id, contract_type_key) references public.template_contract_types(template_id, key),
  check (entity_type = 'contract' or contract_type_key is null),
  unique nulls not distinct (template_id, entity_type, contract_type_key, key)
);
create table public.organization_templates (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  template_id uuid not null references public.industry_templates(id),
  applied_by uuid not null, applied_at timestamptz not null default now(),
  primary key (organization_id, template_id),
  foreign key (organization_id, applied_by) references public.organization_members(organization_id, user_id)
);
alter table public.organizations drop column industry,
  add column industry_key text references public.industries(key);
do $$ declare t text; begin
  foreach t in array array['industries','industry_templates','template_contract_types','template_custom_fields'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy catalog_read on public.%I for select to authenticated using ((select auth.uid()) is not null)', t);
  end loop;
end $$;
alter table public.organization_templates enable row level security;
revoke all on public.organization_templates from anon, authenticated;
grant select on public.organization_templates to authenticated;
create policy organization_templates_read on public.organization_templates for select to authenticated
using ((select private.is_active_member(organization_id)));

insert into public.industries values ('energy', 'Energy');
insert into public.industry_templates(id, industry_key, key, name, version)
values ('e0000000-0000-0000-0000-000000000001', 'energy', 'energy', 'Energy', 1);
insert into public.template_contract_types values
('e0000000-0000-0000-0000-000000000001', 'electricity', 'Electricity'),
('e0000000-0000-0000-0000-000000000001', 'gas', 'Gas');
insert into public.template_custom_fields(template_id, entity_type, contract_type_key, key, label, data_type, sort_order, config)
select 'e0000000-0000-0000-0000-000000000001', 'contract', t.key, f.key, f.label, f.data_type, f.sort_order, f.config::jsonb
from public.template_contract_types t cross join (values
  ('closing_platform', 'Closing platform', 'text', 10, '{}'),
  ('meter_number', 'Meter number', 'text', 20, '{}'),
  ('market_location_id', 'Market location ID', 'text', 30, '{}'),
  ('annual_consumption', 'Annual consumption (kWh)', 'number', 40, '{"min":0}')
) f(key, label, data_type, sort_order, config)
where t.template_id = 'e0000000-0000-0000-0000-000000000001';

create function private.apply_template(target_org uuid, target_template uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_org_admin(target_org) then
    raise exception 'Owner/Admin required' using errcode = '42501';
  end if;
  perform 1 from public.organizations where id = target_org for update;
  if exists (select 1 from public.organization_templates where organization_id = target_org and template_id = target_template) then return; end if;
  if not exists (select 1 from public.industry_templates where id = target_template) then
    raise exception 'Unknown template' using errcode = '23503';
  end if;
  -- Refuse collisions instead of silently redefining existing tenant fields.
  insert into public.contract_types(organization_id, key, name)
    select target_org, key, name from public.template_contract_types where template_id = target_template;
  insert into public.custom_field_definitions(organization_id, entity_type, contract_type_id, key, label, data_type, is_required, sort_order, config)
    select target_org, f.entity_type, t.id, f.key, f.label, f.data_type, f.is_required, f.sort_order, f.config
    from public.template_custom_fields f left join public.contract_types t
      on t.organization_id = target_org and t.key = f.contract_type_key
    where f.template_id = target_template;
  insert into public.organization_templates(organization_id, template_id, applied_by) values (target_org, target_template, auth.uid());
end;
$$;
create function public.apply_template(target_org uuid, target_template uuid) returns void
language sql security invoker set search_path = '' as $$ select private.apply_template(target_org, target_template); $$;

revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_active_member(uuid), private.can_access_customer(uuid, uuid),
  private.org_role(uuid), private.is_org_admin(uuid), private.can_read_profile(uuid),
  private.delete_customer(uuid), private.restore_customer(uuid, uuid), private.apply_template(uuid, uuid) to authenticated;
revoke all on function public.delete_customer(uuid), public.restore_customer(uuid, uuid), public.apply_template(uuid, uuid) from public, anon, authenticated;
grant execute on function public.delete_customer(uuid), public.restore_customer(uuid, uuid), public.apply_template(uuid, uuid) to authenticated;

-- Cover composite tenant FKs for deletes, membership operations and validation.
drop index public.customer_custom_field_values_definition_idx;
drop index public.contract_custom_field_values_definition_idx;
create index customer_values_definition_fk_idx on public.customer_custom_field_values
  (organization_id, entity_type, custom_field_definition_id, data_type);
create index contract_values_definition_fk_idx on public.contract_custom_field_values
  (organization_id, entity_type, custom_field_definition_id, data_type);
create index contracts_creator_idx on public.contracts (organization_id, created_by);
create index customers_creator_idx on public.customers (organization_id, created_by);
create index customers_deleter_idx on public.customers (organization_id, deleted_by);
create index follow_ups_creator_idx on public.follow_ups (organization_id, created_by);
create index follow_ups_customer_contract_idx on public.follow_ups (organization_id, customer_id, contract_id);
create index notes_creator_idx on public.notes (organization_id, created_by);
create index notes_customer_contract_idx on public.notes (organization_id, customer_id, contract_id);
create index industry_templates_industry_idx on public.industry_templates (industry_key);
create index organization_templates_applier_idx on public.organization_templates (organization_id, applied_by);
create index organization_templates_template_idx on public.organization_templates (template_id);
create index organizations_industry_idx on public.organizations (industry_key);
create index template_custom_fields_type_idx on public.template_custom_fields (template_id, contract_type_key);
