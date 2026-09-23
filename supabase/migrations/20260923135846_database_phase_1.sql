-- Trackma database phase 1.
-- All application access is denied by default and granted through explicit RLS policies.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  first_name text,
  last_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_first_name_not_blank check (first_name is null or btrim(first_name) <> ''),
  constraint profiles_last_name_not_blank check (last_name is null or btrim(last_name) <> '')
);

create table public.organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete restrict,
  role text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organization_members_role_check
    check (role in ('owner', 'admin', 'team_lead', 'agent')),
  constraint organization_members_organization_user_key unique (organization_id, user_id)
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  created_by uuid not null,
  owner_id uuid not null,
  first_name text not null check (btrim(first_name) <> ''),
  last_name text not null check (btrim(last_name) <> ''),
  street text,
  house_number text,
  postal_code text,
  city text,
  birth_date date,
  phone text,
  email text,
  iban text,
  bic text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customers_organization_id_id_key unique (organization_id, id),
  constraint customers_created_by_membership_fk
    foreign key (organization_id, created_by)
    references public.organization_members (organization_id, user_id)
    on delete no action deferrable initially deferred,
  constraint customers_owner_membership_fk
    foreign key (organization_id, owner_id)
    references public.organization_members (organization_id, user_id)
    on delete no action deferrable initially deferred
);

create table public.contracts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null,
  created_by uuid not null,
  contract_type text not null check (contract_type in ('electricity', 'gas')),
  provider text,
  closing_platform text,
  customer_number text,
  meter_number text,
  market_location_id text,
  annual_consumption numeric check (annual_consumption is null or annual_consumption >= 0),
  contract_signed_at date,
  supply_start date,
  supply_end date,
  status text not null check (btrim(status) <> ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint contracts_organization_customer_id_key unique (organization_id, customer_id, id),
  constraint contracts_customer_fk
    foreign key (organization_id, customer_id)
    references public.customers (organization_id, id)
    on delete cascade,
  constraint contracts_created_by_membership_fk
    foreign key (organization_id, created_by)
    references public.organization_members (organization_id, user_id)
    on delete no action deferrable initially deferred,
  constraint contracts_supply_dates_check
    check (supply_end is null or supply_start is null or supply_end >= supply_start)
);

create table public.follow_ups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null,
  contract_id uuid,
  assigned_to uuid not null,
  created_by uuid not null,
  due_at timestamptz not null,
  type text not null check (btrim(type) <> ''),
  status text not null check (
    status in ('not_started', 'in_progress', 'waiting_for_customer', 'completed', 'declined')
  ),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint follow_ups_organization_customer_fk
    foreign key (organization_id, customer_id)
    references public.customers (organization_id, id)
    on delete cascade,
  constraint follow_ups_customer_contract_fk
    foreign key (organization_id, customer_id, contract_id)
    references public.contracts (organization_id, customer_id, id)
    on delete cascade,
  constraint follow_ups_assigned_to_membership_fk
    foreign key (organization_id, assigned_to)
    references public.organization_members (organization_id, user_id)
    on delete no action deferrable initially deferred,
  constraint follow_ups_created_by_membership_fk
    foreign key (organization_id, created_by)
    references public.organization_members (organization_id, user_id)
    on delete no action deferrable initially deferred,
  constraint follow_ups_completion_check check (
    (status = 'completed' and completed_at is not null)
    or (status <> 'completed' and completed_at is null)
  )
);

create table public.referrals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  referrer_customer_id uuid not null,
  referred_customer_id uuid not null,
  created_at timestamptz not null default now(),
  constraint referrals_referrer_customer_fk
    foreign key (organization_id, referrer_customer_id)
    references public.customers (organization_id, id)
    on delete cascade,
  constraint referrals_referred_customer_fk
    foreign key (organization_id, referred_customer_id)
    references public.customers (organization_id, id)
    on delete cascade,
  constraint referrals_distinct_customers_check
    check (referrer_customer_id <> referred_customer_id),
  constraint referrals_unique_relationship
    unique (organization_id, referrer_customer_id, referred_customer_id)
);

create table public.notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null,
  contract_id uuid,
  created_by uuid not null,
  content text not null check (btrim(content) <> ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint notes_organization_customer_fk
    foreign key (organization_id, customer_id)
    references public.customers (organization_id, id)
    on delete cascade,
  constraint notes_customer_contract_fk
    foreign key (organization_id, customer_id, contract_id)
    references public.contracts (organization_id, customer_id, id)
    on delete cascade,
  constraint notes_created_by_membership_fk
    foreign key (organization_id, created_by)
    references public.organization_members (organization_id, user_id)
    on delete no action deferrable initially deferred
);

create index organization_members_user_active_idx
  on public.organization_members (user_id, organization_id)
  where is_active;
create index customers_organization_owner_idx
  on public.customers (organization_id, owner_id);
create index contracts_customer_idx
  on public.contracts (organization_id, customer_id);
create index contracts_status_idx
  on public.contracts (organization_id, status);
create index follow_ups_customer_idx
  on public.follow_ups (organization_id, customer_id);
create index follow_ups_contract_idx
  on public.follow_ups (contract_id)
  where contract_id is not null;
create index follow_ups_assignee_due_idx
  on public.follow_ups (organization_id, assigned_to, due_at);
create index follow_ups_status_due_idx
  on public.follow_ups (organization_id, status, due_at);
create index referrals_referred_customer_idx
  on public.referrals (organization_id, referred_customer_id);
create index notes_customer_idx
  on public.notes (organization_id, customer_id);
create index notes_contract_idx
  on public.notes (contract_id)
  where contract_id is not null;

create function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create function private.prevent_tenant_attribution_change()
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
  if new.created_by is distinct from old.created_by then
    raise exception 'created_by is immutable' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger organizations_set_updated_at before update on public.organizations
for each row execute function private.set_updated_at();
create trigger profiles_set_updated_at before update on public.profiles
for each row execute function private.set_updated_at();
create trigger organization_members_set_updated_at before update on public.organization_members
for each row execute function private.set_updated_at();
create trigger customers_set_updated_at before update on public.customers
for each row execute function private.set_updated_at();
create trigger contracts_set_updated_at before update on public.contracts
for each row execute function private.set_updated_at();
create trigger follow_ups_set_updated_at before update on public.follow_ups
for each row execute function private.set_updated_at();
create trigger notes_set_updated_at before update on public.notes
for each row execute function private.set_updated_at();

create trigger customers_tenant_attribution_immutable before update on public.customers
for each row execute function private.prevent_tenant_attribution_change();
create trigger contracts_tenant_attribution_immutable before update on public.contracts
for each row execute function private.prevent_tenant_attribution_change();
create trigger follow_ups_tenant_attribution_immutable before update on public.follow_ups
for each row execute function private.prevent_tenant_attribution_change();
create trigger notes_tenant_attribution_immutable before update on public.notes
for each row execute function private.prevent_tenant_attribution_change();

create function private.is_active_member(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_members as membership
    where membership.organization_id = target_organization_id
      and membership.user_id = (select auth.uid())
      and membership.is_active
  );
$$;

create function private.can_access_customer(
  target_organization_id uuid,
  target_customer_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.customers as customer
    join public.organization_members as membership
      on membership.organization_id = customer.organization_id
     and membership.user_id = (select auth.uid())
     and membership.is_active
    where customer.organization_id = target_organization_id
      and customer.id = target_customer_id
      and customer.owner_id = (select auth.uid())
  );
$$;

revoke all on all functions in schema private from public;
grant execute on function private.is_active_member(uuid) to authenticated;
grant execute on function private.can_access_customer(uuid, uuid) to authenticated;

alter table public.organizations enable row level security;
alter table public.profiles enable row level security;
alter table public.organization_members enable row level security;
alter table public.customers enable row level security;
alter table public.contracts enable row level security;
alter table public.follow_ups enable row level security;
alter table public.referrals enable row level security;
alter table public.notes enable row level security;

revoke all on table public.organizations from anon, authenticated;
revoke all on table public.profiles from anon, authenticated;
revoke all on table public.organization_members from anon, authenticated;
revoke all on table public.customers from anon, authenticated;
revoke all on table public.contracts from anon, authenticated;
revoke all on table public.follow_ups from anon, authenticated;
revoke all on table public.referrals from anon, authenticated;
revoke all on table public.notes from anon, authenticated;

grant select on table public.organizations to authenticated;
grant select, insert, update on table public.profiles to authenticated;
grant select on table public.organization_members to authenticated;
grant select, insert, update, delete on table public.customers to authenticated;
grant select, insert, update, delete on table public.contracts to authenticated;
grant select, insert, update, delete on table public.follow_ups to authenticated;
grant select, insert, delete on table public.referrals to authenticated;
grant select, insert, update, delete on table public.notes to authenticated;

create policy organizations_select_active_member
on public.organizations for select to authenticated
using ((select private.is_active_member(id)));

create policy profiles_select_own
on public.profiles for select to authenticated
using ((select auth.uid()) = id);
create policy profiles_insert_own
on public.profiles for insert to authenticated
with check ((select auth.uid()) = id);
create policy profiles_update_own
on public.profiles for update to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create policy organization_members_select_own
on public.organization_members for select to authenticated
using ((select auth.uid()) = user_id);

create policy customers_select_owned
on public.customers for select to authenticated
using (
  owner_id = (select auth.uid())
  and (select private.is_active_member(organization_id))
);
create policy customers_insert_self_owned
on public.customers for insert to authenticated
with check (
  created_by = (select auth.uid())
  and owner_id = (select auth.uid())
  and (select private.is_active_member(organization_id))
);
create policy customers_update_owned
on public.customers for update to authenticated
using (
  owner_id = (select auth.uid())
  and (select private.is_active_member(organization_id))
)
with check (
  owner_id = (select auth.uid())
  and (select private.is_active_member(organization_id))
);
create policy customers_delete_owned
on public.customers for delete to authenticated
using (
  owner_id = (select auth.uid())
  and (select private.is_active_member(organization_id))
);

create policy contracts_select_for_accessible_customer
on public.contracts for select to authenticated
using ((select private.can_access_customer(organization_id, customer_id)));
create policy contracts_insert_for_accessible_customer
on public.contracts for insert to authenticated
with check (
  created_by = (select auth.uid())
  and (select private.can_access_customer(organization_id, customer_id))
);
create policy contracts_update_for_accessible_customer
on public.contracts for update to authenticated
using ((select private.can_access_customer(organization_id, customer_id)))
with check ((select private.can_access_customer(organization_id, customer_id)));
create policy contracts_delete_for_accessible_customer
on public.contracts for delete to authenticated
using ((select private.can_access_customer(organization_id, customer_id)));

create policy follow_ups_select_for_accessible_customer
on public.follow_ups for select to authenticated
using ((select private.can_access_customer(organization_id, customer_id)));
create policy follow_ups_insert_for_accessible_customer
on public.follow_ups for insert to authenticated
with check (
  created_by = (select auth.uid())
  and assigned_to = (select auth.uid())
  and (select private.can_access_customer(organization_id, customer_id))
);
create policy follow_ups_update_for_accessible_customer
on public.follow_ups for update to authenticated
using ((select private.can_access_customer(organization_id, customer_id)))
with check (
  assigned_to = (select auth.uid())
  and (select private.can_access_customer(organization_id, customer_id))
);
create policy follow_ups_delete_for_accessible_customer
on public.follow_ups for delete to authenticated
using ((select private.can_access_customer(organization_id, customer_id)));

create policy referrals_select_for_accessible_customers
on public.referrals for select to authenticated
using (
  (select private.can_access_customer(organization_id, referrer_customer_id))
  and (select private.can_access_customer(organization_id, referred_customer_id))
);
create policy referrals_insert_for_accessible_customers
on public.referrals for insert to authenticated
with check (
  (select private.can_access_customer(organization_id, referrer_customer_id))
  and (select private.can_access_customer(organization_id, referred_customer_id))
);
create policy referrals_delete_for_accessible_customers
on public.referrals for delete to authenticated
using (
  (select private.can_access_customer(organization_id, referrer_customer_id))
  and (select private.can_access_customer(organization_id, referred_customer_id))
);

create policy notes_select_for_accessible_customer
on public.notes for select to authenticated
using ((select private.can_access_customer(organization_id, customer_id)));
create policy notes_insert_for_accessible_customer
on public.notes for insert to authenticated
with check (
  created_by = (select auth.uid())
  and (select private.can_access_customer(organization_id, customer_id))
);
create policy notes_update_for_accessible_customer
on public.notes for update to authenticated
using ((select private.can_access_customer(organization_id, customer_id)))
with check ((select private.can_access_customer(organization_id, customer_id)));
create policy notes_delete_for_accessible_customer
on public.notes for delete to authenticated
using ((select private.can_access_customer(organization_id, customer_id)));
